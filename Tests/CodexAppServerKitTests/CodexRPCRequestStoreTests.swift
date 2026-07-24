import XCTest
@testable import CodexAppServerKit
import CodexRuntimeKit

final class CodexRPCRequestStoreTests: XCTestCase {
	func testRequestIDsAreMonotonicStrings() {
		let store = CodexRPCRequestStore()
		XCTAssertEqual(store.makeRequestID(), "1")
		XCTAssertEqual(store.makeRequestID(), "2")
		XCTAssertEqual(store.peekNextRequestID, 3)
	}

	func testResolveSuccessIsExactlyOnce() async {
		let store = CodexRPCRequestStore()
		let result: [String: Any] = await withCheckedContinuation { outer in
			Task {
				let value: [String: Any] = try! await withCheckedThrowingContinuation { continuation in
					store.register(
						id: "1",
						metadata: .init(method: "model/list", transportGeneration: 1),
						continuation: continuation
					)
					XCTAssertTrue(store.resolveSuccess(id: "1", result: ["winner": "first"]))
					XCTAssertFalse(store.resolveSuccess(id: "1", result: ["winner": "second"]), "Second resolution is dropped")
					XCTAssertFalse(store.resolveFailure(id: "1", error: CodexClientError.invalidResponse))
				}
				outer.resume(returning: value)
			}
		}
		XCTAssertEqual(result["winner"] as? String, "first")
		XCTAssertEqual(store.pendingCount, 0)
	}

	func testFireTimeoutPoisonsBeforeResumingAndClearsState() async {
		let store = CodexRPCRequestStore()
		let poisonRecord = PoisonRecord()
		do {
			_ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
				store.register(
					id: "9",
					metadata: .init(method: "thread/start", transportGeneration: 4),
					continuation: continuation
				)
				store.fireTimeout(
					id: "9",
					after: 1.5,
					poison: { metadata in
						poisonRecord.metadata = metadata
						poisonRecord.pendingAtPoisonTime = store.pendingCount
					},
					makeError: { CodexClientError.requestFailed("Request timed out after \($0)s") }
				)
			}
			XCTFail("Expected timeout error")
		} catch {
			XCTAssertEqual(error.localizedDescription, "Request timed out after 1.5s")
		}
		XCTAssertEqual(poisonRecord.metadata, .init(method: "thread/start", transportGeneration: 4))
		XCTAssertEqual(poisonRecord.pendingAtPoisonTime, 0, "Poison closure runs after the timed-out request is removed")
		XCTAssertEqual(store.pendingCount, 0)
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}

	private final class PoisonRecord: @unchecked Sendable {
		var metadata: CodexRPCRequestStore.Metadata?
		var pendingAtPoisonTime = -1
	}

	func testFireTimeoutIsNoOpWhenAlreadyResolved() {
		let store = CodexRPCRequestStore()
		var poisoned = false
		store.fireTimeout(
			id: "404",
			after: 1,
			poison: { _ in poisoned = true },
			makeError: { CodexClientError.requestFailed("Request timed out after \($0)s") }
		)
		XCTAssertFalse(poisoned)
	}

	func testFailAllResumesEveryPendingRequestAndCancelsTimeouts() async {
		let store = CodexRPCRequestStore()
		let errors: [Error] = await withCheckedContinuation { outer in
			Task {
				async let first: [String: Any] = withCheckedThrowingContinuation { continuation in
					store.register(id: "1", metadata: .init(method: "a", transportGeneration: 1), continuation: continuation)
				}
				async let second: [String: Any] = withCheckedThrowingContinuation { continuation in
					store.register(id: "2", metadata: .init(method: "b", transportGeneration: 1), continuation: continuation)
					store.scheduleTimeout(for: "2", after: 60, onTimeout: { _, _ in })
					store.failAll(error: CodexClientError.processNotRunning)
				}
				var collected: [Error] = []
				do { _ = try await first } catch { collected.append(error) }
				do { _ = try await second } catch { collected.append(error) }
				outer.resume(returning: collected)
			}
		}
		XCTAssertEqual(errors.count, 2)
		XCTAssertEqual(store.pendingCount, 0)
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}

	func testCancelIfPresentThrowsCancellationError() async {
		let store = CodexRPCRequestStore()
		do {
			_ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
				store.register(id: "1", metadata: .init(method: "a", transportGeneration: 1), continuation: continuation)
				store.cancelIfPresent(id: "1")
			}
			XCTFail("Expected cancellation")
		} catch {
			XCTAssertTrue(error is CancellationError)
		}
		XCTAssertEqual(store.pendingCount, 0)
	}

	func testScheduleTimeoutIgnoresNonPositiveTimeouts() {
		let store = CodexRPCRequestStore()
		store.scheduleTimeout(for: "1", after: 0, onTimeout: { _, _ in })
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}
}
