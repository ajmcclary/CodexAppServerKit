import XCTest
import Foundation
import Darwin
import ProcessKit
@testable import CodexAppServerKit

/// Package-local characterization for `CodexAppServerProcessTransport`.
///
/// The transport had no package-level coverage before the extraction — it
/// was only reachable through RepoPrompt's app-level
/// `CodexAppServerTransportCharacterizationTests` (which stays app-side and
/// still exercises the app's PID-registration and recovery policy around
/// it). These pin the transport-owned mechanics the package is now
/// responsible for: generation scoping, idempotent invalidation, the
/// single-reap snapshot path, write-failure behavior, injected-port
/// delegation, and end-to-end ordered byte delivery through a real child.
final class CodexAppServerProcessTransportTests: XCTestCase {

	// MARK: - Helpers

	private func makeTransport(
		write: @escaping @Sendable (Int32, Data) throws -> Void = { fd, data in
			try FDWriteSupport.writeAll(data, to: fd)
		},
		liveness: @escaping @Sendable (SpawnedProcess) -> Bool = { _ in true },
		preflight: @escaping @Sendable (Int32, String) throws -> Void = { _, _ in }
	) -> CodexAppServerProcessTransport {
		CodexAppServerProcessTransport(
			writeFrameHandler: write,
			livenessProbe: liveness,
			readPreflight: preflight
		)
	}

	/// A pipe-backed `SpawnedProcess` with no real child behind it. Used for
	/// the state-machine assertions that must not depend on process
	/// scheduling. `pid` is deliberately bogus and never reaped.
	private func makeFakeProcess() -> (process: SpawnedProcess, pipes: [Pipe]) {
		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let process = SpawnedProcess(
			pid: -1,
			stdin: stdinPipe.fileHandleForWriting,
			stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
			stdout: stdoutPipe.fileHandleForReading,
			stderr: stderrPipe.fileHandleForReading
		)
		return (process, [stdinPipe, stdoutPipe, stderrPipe])
	}

	// MARK: - Empty transport

	func testFreshTransportHasNoProcessAndIsNotAlive() {
		let transport = makeTransport()
		XCTAssertFalse(transport.hasProcess)
		XCTAssertNil(transport.pid)
		XCTAssertFalse(transport.processAppearsAlive, "No process means the liveness probe is never consulted")
		XCTAssertEqual(transport.generation, 0)
		XCTAssertFalse(transport.isTerminated)
	}

	func testWriteFrameWithoutProcessThrowsTransportUnavailable() {
		let transport = makeTransport(write: { _, _ in
			XCTFail("The write handler must not be reached without a process")
		})
		XCTAssertThrowsError(try transport.writeFrame(Data("{}\n".utf8))) { error in
			guard case CodexAppServerProcessTransport.WriteFailure.transportUnavailable = error else {
				return XCTFail("Expected .transportUnavailable, got \(error)")
			}
		}
	}

	func testStartReadersWithoutProcessThrowsTransportUnavailable() {
		let transport = makeTransport()
		XCTAssertThrowsError(
			try transport.startReaders(onStdoutChunk: { _ in }, onStdoutEOF: { _ in }, stderrLogger: nil)
		) { error in
			guard case CodexAppServerProcessTransport.WriteFailure.transportUnavailable = error else {
				return XCTFail("Expected .transportUnavailable, got \(error)")
			}
		}
	}

	// MARK: - Generation + invalidation state machine

	func testDebugInstallAdvancesGenerationAndClearsTerminatedFlag() {
		let transport = makeTransport()
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)
		XCTAssertEqual(transport.generation, 1)
		XCTAssertTrue(transport.hasProcess)
		XCTAssertEqual(transport.pid, -1)
		XCTAssertFalse(transport.isTerminated)

		XCTAssertNotNil(transport.invalidate())
		XCTAssertTrue(transport.isTerminated)

		transport.debugInstallProcess(makeFakeProcess().process)
		XCTAssertEqual(transport.generation, 2, "Each install advances the generation")
		XCTAssertFalse(transport.isTerminated, "Install clears the terminated flag")
		_ = transport.invalidate()
		withExtendedLifetime(fake.pipes) {}
	}

	func testInvalidateIsIdempotentAndProducesExactlyOneSnapshot() {
		let transport = makeTransport()
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)

		let first = transport.invalidate()
		XCTAssertNotNil(first)
		XCTAssertEqual(first?.process?.pid, -1, "The snapshot carries the process to reap")
		XCTAssertFalse(transport.hasProcess, "invalidate() releases the process")

		XCTAssertNil(transport.invalidate(), "A second invalidate produces no second reap")
		withExtendedLifetime(fake.pipes) {}
	}

	func testInvalidateIsGenerationScoped() {
		let transport = makeTransport()
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)
		XCTAssertEqual(transport.generation, 1)

		XCTAssertNil(
			transport.invalidate(expectedGeneration: 0),
			"A stale caller from generation 0 must not tear down generation 1"
		)
		XCTAssertTrue(transport.hasProcess)
		XCTAssertFalse(transport.isTerminated)

		XCTAssertNotNil(transport.invalidate(expectedGeneration: 1))
		withExtendedLifetime(fake.pipes) {}
	}

	func testFinishTerminationOnAnEmptySnapshotIsANoOp() async throws {
		let transport = makeTransport()
		let snapshot = try XCTUnwrap(
			transport.invalidate(),
			"Invalidating a never-spawned transport still yields exactly one snapshot"
		)
		XCTAssertNil(snapshot.process, "No process was ever installed")
		await CodexAppServerProcessTransport.finishTermination(
			snapshot,
			terminationPolicy: .default
		)
		XCTAssertNil(transport.invalidate(), "Still exactly-once")
	}

	// MARK: - Injected ports

	func testProcessAppearsAliveDelegatesToTheInjectedProbe() {
		final class Box: @unchecked Sendable { var calls = 0; var answer = true }
		let box = Box()
		let transport = makeTransport(liveness: { _ in
			box.calls += 1
			return box.answer
		})
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)

		XCTAssertTrue(transport.processAppearsAlive)
		box.answer = false
		XCTAssertFalse(transport.processAppearsAlive)
		XCTAssertEqual(box.calls, 2, "Policy is the owner's; the transport only asks")
		_ = transport.invalidate()
		withExtendedLifetime(fake.pipes) {}
	}

	func testWriteFrameHandlerErrorsPropagateUnchanged() {
		struct Boom: Error, Equatable {}
		let transport = makeTransport(write: { _, _ in throw Boom() })
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)
		XCTAssertThrowsError(try transport.writeFrame(Data("{}\n".utf8))) { error in
			XCTAssertEqual(error as? Boom, Boom(), "The transport does not map handler errors")
		}
		_ = transport.invalidate()
		withExtendedLifetime(fake.pipes) {}
	}

	func testStartReadersPropagatesPreflightFailure() {
		struct PreflightRejected: Error {}
		let transport = makeTransport(preflight: { _, _ in throw PreflightRejected() })
		let fake = makeFakeProcess()
		transport.debugInstallProcess(fake.process)
		XCTAssertThrowsError(
			try transport.startReaders(onStdoutChunk: { _ in }, onStdoutEOF: { _ in }, stderrLogger: nil)
		) { error in
			XCTAssertTrue(error is PreflightRejected)
		}
		// The owner is expected to invalidate after a partial reader setup;
		// invalidation must still be available and produce the snapshot.
		XCTAssertNotNil(transport.invalidate())
		withExtendedLifetime(fake.pipes) {}
	}

	func testDefaultLivenessProbeRejectsAProcessWithoutAStdinDescriptor() {
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let process = SpawnedProcess(
			pid: Darwin.getpid(),
			stdin: nil,
			stdinDescriptor: nil,
			stdout: stdoutPipe.fileHandleForReading,
			stderr: stderrPipe.fileHandleForReading
		)
		XCTAssertFalse(
			CodexAppServerProcessTransport.defaultProcessAppearsAlive(process),
			"No stdin descriptor means the transport can no longer write to the child"
		)
	}

	// MARK: - End-to-end over a real child

	/// Spawns `/bin/cat`, writes framed JSON to its stdin, and reads the
	/// echo back through the transport's stdout reader into
	/// `CodexJSONStreamDecoder` — the full ordered byte path the package now
	/// owns — then tears down through invalidate + finishTermination.
	func testSpawnWriteReadAndTeardownDeliversOrderedFrames() async throws {
		let transport = makeTransport()
		let collector = ChunkCollector()

		let pid = try transport.spawn(
			CodexAppServerProcessTransport.LaunchSpec(
				command: "/bin/cat",
				arguments: [],
				environment: ProcessInfo.processInfo.environment,
				workingDirectory: nil
			)
		)
		XCTAssertGreaterThan(pid, 0)
		XCTAssertEqual(transport.generation, 1)
		XCTAssertEqual(transport.pid, pid)
		XCTAssertTrue(transport.processAppearsAlive)

		try transport.startReaders(
			onStdoutChunk: { chunk in await collector.append(chunk) },
			onStdoutEOF: { generation in await collector.recordEOF(generation) },
			stderrLogger: nil
		)

		for index in 1...3 {
			try transport.writeFrame(
				try CodexJSONRPCCodec.frame(["jsonrpc": "2.0", "id": index, "method": "ping"])
			)
		}

		var decoder = CodexJSONStreamDecoder()
		var ids: [String] = []
		let deadline = Date().addingTimeInterval(10)
		while ids.count < 3, Date() < deadline {
			for chunk in await collector.drain() {
				for event in decoder.ingest(chunk) {
					if case .object(let json) = event,
						case .response(let id, _)? = CodexJSONRPCCodec.classify(json) {
						ids.append(id)
					} else if case .object(let json) = event,
						let id = json["id"] {
						ids.append(String(describing: id))
					}
				}
			}
			try await Task.sleep(nanoseconds: 20_000_000)
		}

		XCTAssertEqual(ids, ["1", "2", "3"], "Chunks arrive FIFO and decode in order")

		let snapshot = try XCTUnwrap(transport.invalidate(expectedGeneration: 1))
		await CodexAppServerProcessTransport.finishTermination(snapshot, terminationPolicy: .default)
		XCTAssertTrue(transport.isTerminated)
		XCTAssertFalse(transport.hasProcess)
	}

	private actor ChunkCollector {
		private var chunks: [Data] = []
		private(set) var eofGeneration: UInt64?
		func append(_ chunk: Data) { chunks.append(chunk) }
		func recordEOF(_ generation: UInt64) { eofGeneration = generation }
		func drain() -> [Data] {
			let out = chunks
			chunks.removeAll()
			return out
		}
	}
}
