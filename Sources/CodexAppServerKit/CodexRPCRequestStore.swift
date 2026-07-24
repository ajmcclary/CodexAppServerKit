import Foundation

/// Sole owner of JSON-RPC request-side state for the Codex app-server client:
/// request-ID allocation, pending continuations, per-request metadata, and
/// timeout tasks, with exactly-once resolution enforced by removal-before-
/// resume. Synchronous by design — the instance is owned by and executes
/// under the client actor; it introduces no concurrency domain of its own
/// (the detached timeout tasks only call the injected async callback).
public final class CodexRPCRequestStore {
	public init() {}

	public typealias PendingContinuation = CheckedContinuation<[String: Any], Error>

	public struct Metadata: Equatable {
		public let method: String
		public let transportGeneration: UInt64

		public init(method: String, transportGeneration: UInt64) {
			self.method = method
			self.transportGeneration = transportGeneration
		}
	}

	private var pendingContinuationsByID: [String: PendingContinuation] = [:]
	private var metadataByID: [String: Metadata] = [:]
	private var timeoutTasksByID: [String: Task<Void, Never>] = [:]
	private var nextRequestID = 1

	public func makeRequestID() -> String {
		let value = nextRequestID
		nextRequestID += 1
		return String(value)
	}

	public func register(id: String, metadata: Metadata, continuation: PendingContinuation) {
		pendingContinuationsByID[id] = continuation
		metadataByID[id] = metadata
	}

	public func scheduleTimeout(
		for id: String,
		after timeout: TimeInterval,
		onTimeout: @escaping @Sendable (String, TimeInterval) async -> Void
	) {
		guard timeout > 0 else { return }
		timeoutTasksByID[id]?.cancel()
		timeoutTasksByID[id] = Task.detached {
			try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
			await onTimeout(id, timeout)
		}
	}

	/// Resolves a pending request with a success result. Returns false when
	/// nothing is pending under the id (late/duplicate responses drop here).
	@discardableResult
	public func resolveSuccess(id: String, result: [String: Any]) -> Bool {
		guard let continuation = take(id: id) else { return false }
		continuation.resume(returning: result)
		return true
	}

	@discardableResult
	public func resolveFailure(id: String, error: Error) -> Bool {
		guard let continuation = take(id: id) else { return false }
		continuation.resume(throwing: error)
		return true
	}

	/// Timeout firing: removes all state for the id, invokes `poison` with
	/// the request's metadata while nothing has resumed yet (so the owner can
	/// tear the transport down first, exactly as the legacy inline path did),
	/// then resumes throwing `makeError(timeout)`. No-op when the request
	/// already resolved.
	public func fireTimeout(
		id: String,
		after timeout: TimeInterval,
		poison: (Metadata) -> Void,
		makeError: (TimeInterval) -> Error
	) {
		timeoutTasksByID.removeValue(forKey: id)
		guard let continuation = pendingContinuationsByID.removeValue(forKey: id) else {
			metadataByID.removeValue(forKey: id)
			return
		}
		let metadata = metadataByID.removeValue(forKey: id)
		if let metadata {
			poison(metadata)
		}
		continuation.resume(throwing: makeError(timeout))
	}

	/// Cancels a pending request (task-cancellation path).
	public func cancelIfPresent(id: String) {
		guard let continuation = take(id: id) else { return }
		continuation.resume(throwing: CancellationError())
	}

	/// Fails every pending request with `error` and cancels all timeout tasks
	/// (transport-invalidation path).
	public func failAll(error: Error) {
		for task in timeoutTasksByID.values { task.cancel() }
		timeoutTasksByID.removeAll()
		let continuations = pendingContinuationsByID
		pendingContinuationsByID.removeAll()
		metadataByID.removeAll()
		for continuation in continuations.values {
			continuation.resume(throwing: error)
		}
	}

	private func take(id: String) -> PendingContinuation? {
		timeoutTasksByID.removeValue(forKey: id)?.cancel()
		metadataByID.removeValue(forKey: id)
		return pendingContinuationsByID.removeValue(forKey: id)
	}

	public var pendingCount: Int { pendingContinuationsByID.count }
	public var timeoutTaskCount: Int { timeoutTasksByID.count }
	public var peekNextRequestID: Int { nextRequestID }
}
