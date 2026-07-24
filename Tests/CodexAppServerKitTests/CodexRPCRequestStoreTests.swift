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

	/// The `poison` closure the production owner passes re-enters the store —
	/// transport invalidation calls `failAll` — so `fireTimeout` must not hold
	/// its lock while calling out. This pins that re-entrancy directly: a
	/// non-recursive lock held across `poison` would deadlock here, and a
	/// removal ordered after `poison` would double-resume and trap.
	func testFireTimeoutToleratesPoisonReenteringTheStore() async {
		let store = CodexRPCRequestStore()
		let observed = ReentrantPoisonRecord()

		// A sibling request the re-entrant sweep is expected to resume.
		let (registrations, registered) = AsyncStream<Void>.makeStream()
		let sibling = Task {
			try await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
				store.register(id: "sibling", metadata: .init(method: "thread/other", transportGeneration: 7), continuation: continuation)
				registered.yield()
			}
		}
		for await _ in registrations { break }
		XCTAssertEqual(store.pendingCount, 1)

		do {
			_ = try await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
				store.register(id: "timing-out", metadata: .init(method: "thread/start", transportGeneration: 7), continuation: continuation)
				store.fireTimeout(
					id: "timing-out",
					after: 2,
					poison: { metadata in
						observed.metadata = metadata
						// Read BEFORE the sweep: this is the load-bearing
						// assertion. Only the sibling may still be pending —
						// if `fireTimeout` had not removed the timing-out
						// request before calling out, this would be 2 and the
						// sweep below would resume it a second time.
						observed.pendingBeforeFailAll = store.pendingCount
						// Exactly what CodexAppServerClient.invalidateTransport does.
						store.failAll(error: CodexClientError.processNotRunning)
						observed.pendingAfterFailAll = store.pendingCount
					},
					makeError: { CodexClientError.requestFailed("Request timed out after \($0)s") }
				)
			}
			XCTFail("Expected timeout error")
		} catch {
			XCTAssertEqual(error.localizedDescription, "Request timed out after 2.0s")
		}

		var siblingError: Error?
		do { _ = try await sibling.value } catch { siblingError = error }
		XCTAssertTrue(siblingError is CodexClientError, "The sibling is swept by the re-entrant failAll")
		XCTAssertEqual(observed.metadata, .init(method: "thread/start", transportGeneration: 7))
		XCTAssertEqual(
			observed.pendingBeforeFailAll, 1,
			"Only the sibling is still pending — the timed-out request was removed before poison ran")
		XCTAssertEqual(observed.pendingAfterFailAll, 0, "The re-entrant sweep drains what is left")
		XCTAssertEqual(store.pendingCount, 0)
	}

	private final class ReentrantPoisonRecord: @unchecked Sendable {
		var metadata: CodexRPCRequestStore.Metadata?
		var pendingBeforeFailAll = -1
		var pendingAfterFailAll = -1
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
		// Ordering is part of what is under test: `failAll` must run AFTER both
		// requests are registered, otherwise the late registration is never
		// resumed and the awaiting task hangs forever. The original `async let`
		// form left that ordering to the scheduler — under load the sweep won
		// and the test hung, and the two concurrent `register` calls raced on
		// the store's dictionaries besides. The stream handshake sequences the
		// setup explicitly, with no sleeping and no weakened assertions.
		let (registrations, registered) = AsyncStream<Void>.makeStream()
		let first = Task {
			try await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
				store.register(id: "1", metadata: .init(method: "a", transportGeneration: 1), continuation: continuation)
				registered.yield()
			}
		}
		let second = Task {
			try await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
				store.register(id: "2", metadata: .init(method: "b", transportGeneration: 1), continuation: continuation)
				store.scheduleTimeout(for: "2", after: 60, onTimeout: { _, _ in })
				registered.yield()
			}
		}
		var registrationsSeen = 0
		for await _ in registrations {
			registrationsSeen += 1
			if registrationsSeen == 2 { break }
		}
		XCTAssertEqual(store.pendingCount, 2)
		XCTAssertEqual(store.timeoutTaskCount, 1)

		store.failAll(error: CodexClientError.processNotRunning)

		var collected: [Error] = []
		do { _ = try await first.value } catch { collected.append(error) }
		do { _ = try await second.value } catch { collected.append(error) }
		XCTAssertEqual(collected.count, 2)
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

	func testReschedulingATimeoutReplacesRatherThanAccumulates() {
		let store = CodexRPCRequestStore()
		store.scheduleTimeout(for: "1", after: 60, onTimeout: { _, _ in })
		store.scheduleTimeout(for: "1", after: 60, onTimeout: { _, _ in })
		XCTAssertEqual(store.timeoutTaskCount, 1)
		store.failAll(error: CodexClientError.processNotRunning)
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}

	// MARK: - Concurrency regressions

	/// Regression pin for the unsynchronized-store defect. Before the store
	/// serialized its state, `nextRequestID += 1` and the three dictionaries
	/// were mutated concurrently by every caller: ThreadSanitizer reported a
	/// Swift access race in `register`, and untraced runs corrupted Dictionary
	/// storage (SIGSEGV, or an `unrecognized selector` abort on a torn value).
	///
	/// The assertions here are exact rather than statistical, so a lost
	/// counter update fails this test even in the runs that survive without
	/// crashing.
	func testConcurrentAllocationAndResolutionKeepTheCountersExact() async {
		let store = CodexRPCRequestStore()
		let workers = 8
		let requestsPerWorker = 200
		let allocated: [String] = await withTaskGroup(of: [String].self) { group in
			for worker in 0..<workers {
				group.addTask {
					var mine: [String] = []
					mine.reserveCapacity(requestsPerWorker)
					for _ in 0..<requestsPerWorker {
						let id = store.makeRequestID()
						mine.append(id)
						_ = try? await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
							store.register(
								id: id,
								metadata: .init(method: "method/\(worker)", transportGeneration: UInt64(worker)),
								continuation: continuation
							)
							store.scheduleTimeout(for: id, after: 60, onTimeout: { _, _ in })
							store.resolveFailure(id: id, error: CodexClientError.processNotRunning)
						}
					}
					return mine
				}
			}
			var all: [String] = []
			for await mine in group { all.append(contentsOf: mine) }
			return all
		}

		let expected = workers * requestsPerWorker
		XCTAssertEqual(allocated.count, expected)
		XCTAssertEqual(
			Set(allocated).count,
			expected,
			"makeRequestID must never hand the same id to two concurrent callers"
		)
		XCTAssertEqual(
			store.peekNextRequestID,
			expected + 1,
			"Every allocation must be observed exactly once — a lost increment means a torn counter"
		)
		XCTAssertEqual(store.pendingCount, 0, "Every registered request was resolved and removed")
		XCTAssertEqual(store.timeoutTaskCount, 0, "Resolution removes the timeout task with the request")
	}

	/// The same defect from the other direction: resolution, timeout firing
	/// from detached timer tasks, and transport-wide `failAll` sweeps all
	/// contending for the same three dictionaries. Every continuation is also
	/// resolved from inside its own registration body, so whichever path wins
	/// the race the awaiting task always resumes — the test can therefore
	/// assert an exact outcome count instead of tolerating losses.
	func testConcurrentResolutionTimeoutAndFailAllStayExactlyOnce() async {
		let store = CodexRPCRequestStore()
		let outcomes = OutcomeTally()
		let completedIDs = IdentifierTally()
		let workers = 6
		let requestsPerWorker = 150

		await withTaskGroup(of: Void.self) { group in
			for worker in 0..<workers {
				group.addTask {
					for _ in 0..<requestsPerWorker {
						let id = store.makeRequestID()
						do {
							_ = try await withCheckedThrowingContinuation { (continuation: CodexRPCRequestStore.PendingContinuation) in
								store.register(
									id: id,
									metadata: .init(method: "method/\(worker)", transportGeneration: 1),
									continuation: continuation
								)
								// A near-instant timer, so real detached tasks
								// re-enter the store while it is under load.
								store.scheduleTimeout(for: id, after: 0.000_001) { timedOutID, elapsed in
									store.fireTimeout(
										id: timedOutID,
										after: elapsed,
										poison: { _ in },
										makeError: { CodexClientError.requestFailed("Request timed out after \($0)s") }
									)
								}
								store.resolveSuccess(id: id, result: ["id": id])
							}
							outcomes.recordResolved()
						} catch {
							outcomes.recordFailed()
						}
						completedIDs.record(id)
					}
				}
			}
			// A concurrent transport-invalidation storm.
			group.addTask {
				for _ in 0..<(workers * requestsPerWorker) {
					store.failAll(error: CodexClientError.processNotRunning)
					await Task.yield()
				}
			}
		}

		// `outcomes.total` is structurally guaranteed once the group returns —
		// it is the HANG/TRAP detector (a lost resume never returns; a double
		// resume traps inside CheckedContinuation). The distinct-id assertion
		// is the one that can fail with a plain diff: a torn `makeRequestID`
		// hands the same string to two workers even when the process survives.
		XCTAssertEqual(outcomes.total, workers * requestsPerWorker)
		XCTAssertEqual(
			completedIDs.distinctCount,
			workers * requestsPerWorker,
			"Every request carried a distinct id through registration, resolution, and the sweep"
		)
		XCTAssertEqual(
			store.peekNextRequestID,
			workers * requestsPerWorker + 1,
			"The allocator observed every request exactly once under the failAll storm"
		)
		store.failAll(error: CodexClientError.processNotRunning)
		XCTAssertEqual(store.pendingCount, 0)
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}

	private final class IdentifierTally: @unchecked Sendable {
		private let lock = NSLock()
		private var identifiers: Set<String> = []

		func record(_ identifier: String) {
			lock.lock(); defer { lock.unlock() }
			identifiers.insert(identifier)
		}

		var distinctCount: Int {
			lock.lock(); defer { lock.unlock() }
			return identifiers.count
		}
	}

	private final class OutcomeTally: @unchecked Sendable {
		private let lock = NSLock()
		private var resolved = 0
		private var failed = 0

		func recordResolved() {
			lock.lock(); defer { lock.unlock() }
			resolved += 1
		}

		func recordFailed() {
			lock.lock(); defer { lock.unlock() }
			failed += 1
		}

		var total: Int {
			lock.lock(); defer { lock.unlock() }
			return resolved + failed
		}
	}
}
