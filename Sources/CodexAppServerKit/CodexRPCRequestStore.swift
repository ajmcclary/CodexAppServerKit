import Foundation

// SEARCH-HELPER: request store, pending continuations, exactly-once, removal-before-resume, lock
/// Sole owner of JSON-RPC request-side state for the Codex app-server client:
/// request-ID allocation, pending continuations, per-request metadata, and
/// timeout tasks, with exactly-once resolution enforced by removal-before-
/// resume.
///
/// **Concurrency.** Every method is synchronous and callable from any
/// isolation domain: all mutable state is serialized by `lock`, so the type is
/// `Sendable`. RepoPrompt's `CodexAppServerClient` still owns an instance and
/// drives it from a single actor, which keeps the lock uncontended, but that
/// confinement is now an ownership choice rather than a memory-safety
/// precondition. It used to be the latter, documented only in this comment:
/// the store handed out `Task.detached` timers while its three dictionaries
/// and the ID counter were plain unsynchronized properties, so any caller that
/// touched it from two domains corrupted Dictionary storage instead of
/// producing a diagnostic (this package's own `failAll` test did exactly that
/// — ThreadSanitizer reported a Swift access race in `register` and the suite
/// crashed intermittently with SIGSEGV / `unrecognized selector` aborts, or
/// hung).
///
/// **The lock is never held across a call-out.** Resuming a continuation,
/// cancelling a timeout task, and invoking `fireTimeout`'s `poison` closure
/// all run arbitrary caller code — and the production owner's `poison` closure
/// re-enters this store through `failAll`. Each method therefore takes the
/// state it needs under the lock, releases, and only then calls out. That
/// ordering also preserves the removal-before-resume rule that makes
/// resolution exactly-once.
public final class CodexRPCRequestStore: @unchecked Sendable {
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

	/// Guards every stored property below. Non-recursive on purpose: a method
	/// that re-enters the store while holding it is a defect, and the
	/// call-out-after-unlock discipline is what prevents it.
	private let lock = NSLock()
	private var pendingContinuationsByID: [String: PendingContinuation] = [:]
	private var metadataByID: [String: Metadata] = [:]
	private var timeoutTasksByID: [String: Task<Void, Never>] = [:]
	private var nextRequestID = 1

	public func makeRequestID() -> String {
		withLock {
			let value = nextRequestID
			nextRequestID += 1
			return String(value)
		}
	}

	public func register(id: String, metadata: Metadata, continuation: PendingContinuation) {
		withLock {
			pendingContinuationsByID[id] = continuation
			metadataByID[id] = metadata
		}
	}

	public func scheduleTimeout(
		for id: String,
		after timeout: TimeInterval,
		onTimeout: @escaping @Sendable (String, TimeInterval) async -> Void
	) {
		guard timeout > 0 else { return }
		let task = Task.detached {
			try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
			await onTimeout(id, timeout)
		}
		let previous = withLock { () -> Task<Void, Never>? in
			let previous = timeoutTasksByID[id]
			timeoutTasksByID[id] = task
			return previous
		}
		previous?.cancel()
	}

	/// Resolves a pending request with a success result. Returns false when
	/// nothing is pending under the id (late/duplicate responses drop here).
	@discardableResult
	public func resolveSuccess(id: String, result: [String: Any]) -> Bool {
		guard let continuation = take(id: id) else { return false }
		// UNSAFE ESCAPE — the response payload crosses an isolation boundary
		// here, and Swift 6 cannot prove it is safe.
		//
		// `CheckedContinuation.resume(returning:)` takes its value as `sending`
		// (SE-0430) and `[String: Any]` is not Sendable, so the compiler
		// requires proof that this call site holds the payload in a disconnected
		// region. `result` is an ordinary parameter, so it is merged into the
		// caller's region and no such proof exists. The proof-carrying spelling
		// is `sending result: [String: Any]`, which would push the obligation
		// onto callers where it belongs — but that changes a public signature,
		// which this migration is not permitted to do. The obligation is
		// therefore stated here instead of being checked.
		//
		// CALLER INVARIANT (this type cannot enforce it): nothing reachable from
		// `result` may be mutated once it is handed over, because the resumed
		// task reads it from another isolation domain. Note this is weaker than
		// "the caller must not retain it": `[String: Any]` is a value type, so
		// the dictionary structure is copied on handoff and only reference-typed
		// leaves stay shared. RepoPrompt's `CodexAppServerClient.route(_:)` does
		// still hold `result` (through the `json` object it was destructured
		// from) for the remainder of that function — that is fine, and it is why
		// the invariant is phrased as no-mutation rather than no-retention. Its
		// leaves are immutable `NSString`/`NSNumber`/`NSNull`/`NSArray`/
		// `NSDictionary` instances produced by `JSONSerialization`.
		//
		// What this store itself guarantees: it never reads, writes, stores, or
		// copies the payload. It arrives, it is forwarded to the continuation in
		// the next statement, and no reference to it survives this call.
		//
		// This is the same obligation that held before the migration — Swift 6
		// makes it visible rather than creating it. Exercised by
		// `testResolveSuccessPayloadSurvivesACrossDomainHandoff`.
		nonisolated(unsafe) let payload = result
		continuation.resume(returning: payload)
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
	///
	/// `poison` runs after the lock is released precisely because the owner's
	/// implementation re-enters this store (transport invalidation calls
	/// `failAll`); the removal above the release is what stops that re-entrant
	/// sweep from seeing — and double-resuming — this request.
	public func fireTimeout(
		id: String,
		after timeout: TimeInterval,
		poison: (Metadata) -> Void,
		makeError: (TimeInterval) -> Error
	) {
		let taken = withLock { () -> (continuation: PendingContinuation, metadata: Metadata?)? in
			// The task firing this call is the one being removed, so it is
			// dropped rather than cancelled.
			timeoutTasksByID.removeValue(forKey: id)
			guard let continuation = pendingContinuationsByID.removeValue(forKey: id) else {
				metadataByID.removeValue(forKey: id)
				return nil
			}
			return (continuation, metadataByID.removeValue(forKey: id))
		}
		guard let taken else { return }
		if let metadata = taken.metadata {
			poison(metadata)
		}
		taken.continuation.resume(throwing: makeError(timeout))
	}

	/// Cancels a pending request (task-cancellation path).
	public func cancelIfPresent(id: String) {
		guard let continuation = take(id: id) else { return }
		continuation.resume(throwing: CancellationError())
	}

	/// Fails every pending request with `error` and cancels all timeout tasks
	/// (transport-invalidation path).
	public func failAll(error: Error) {
		let taken = withLock { () -> (tasks: [Task<Void, Never>], continuations: [PendingContinuation]) in
			let tasks = Array(timeoutTasksByID.values)
			let continuations = Array(pendingContinuationsByID.values)
			timeoutTasksByID.removeAll()
			pendingContinuationsByID.removeAll()
			metadataByID.removeAll()
			return (tasks, continuations)
		}
		for task in taken.tasks { task.cancel() }
		for continuation in taken.continuations {
			continuation.resume(throwing: error)
		}
	}

	private func take(id: String) -> PendingContinuation? {
		let taken = withLock { () -> (continuation: PendingContinuation?, timeoutTask: Task<Void, Never>?) in
			let timeoutTask = timeoutTasksByID.removeValue(forKey: id)
			metadataByID.removeValue(forKey: id)
			return (pendingContinuationsByID.removeValue(forKey: id), timeoutTask)
		}
		taken.timeoutTask?.cancel()
		return taken.continuation
	}

	public var pendingCount: Int { withLock { pendingContinuationsByID.count } }
	public var timeoutTaskCount: Int { withLock { timeoutTasksByID.count } }
	public var peekNextRequestID: Int { withLock { nextRequestID } }

	private func withLock<Result>(_ body: () -> Result) -> Result {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}
}
