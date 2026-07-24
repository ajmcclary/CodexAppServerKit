import Foundation
import Darwin
import ProcessKit

// SEARCH-HELPER: process transport, spawn, FIFO stdout, pipe reader, generation, reap
/// Sole owner of the Codex app-server child-process transport: the spawned
/// process, the stdout/stderr pipe readers, stdin frame writes, the liveness
/// probe, the transport generation counter, and the termination snapshot
/// handed to the single reap site.
///
/// Deliberately a *synchronous* component, not a second actor: an instance is
/// owned by `CodexAppServerClient` and every method executes under that
/// client's actor. The reader tasks it spawns capture only the injected
/// callbacks and the chunk channel — never the transport itself — so no
/// transport state crosses an isolation boundary.
///
/// Policy stays with the owner: executable resolution, environment
/// composition, CLI overrides (`LaunchSpec` arrives fully resolved),
/// termination policy (passed per reap), stderr logging (injected), and the
/// FD preflight (injected). JSON framing/decoding and request bookkeeping
/// also stay out — see `CodexJSONRPCCodec` / `CodexJSONStreamDecoder` /
/// `CodexRPCRequestStore`.
public final class CodexAppServerProcessTransport {
	/// Fully-resolved launch parameters. The owner composes command,
	/// arguments, and environment before handing them over; the transport
	/// only spawns.
	public struct LaunchSpec {
		public let command: String
		public let arguments: [String]
		public let environment: [String: String]
		public let workingDirectory: String?

		public init(
			command: String,
			arguments: [String],
			environment: [String: String],
			workingDirectory: String?
		) {
			self.command = command
			self.arguments = arguments
			self.environment = environment
			self.workingDirectory = workingDirectory
		}
	}

	/// The invalidated transport's process, to be handed to
	/// `finishTermination` exactly once. Constructed only by `invalidate()`.
	public struct TerminationSnapshot {
		public let process: SpawnedProcess?

		fileprivate init(process: SpawnedProcess?) {
			self.process = process
		}
	}

	public enum WriteFailure: Error {
		/// No process or no stdin descriptor — the owner maps this to its
		/// not-running error without tearing anything down.
		case transportUnavailable
	}

	/// Monotonic counter incremented on each spawn. Captured by consumer
	/// tasks and write-failure teardown to scope teardown to the correct
	/// transport instance — a stale task can never kill a newer process.
	public private(set) var generation: UInt64 = 0
	/// Idempotence flag for `invalidate()`; reset on each spawn.
	public private(set) var isTerminated = false

	private var process: SpawnedProcess?
	private var stdoutReader: ProcessPipeReader?
	private var stderrReader: ProcessPipeReader?

	private let writeFrameHandler: (Int32, Data) throws -> Void
	private let livenessProbe: (SpawnedProcess) -> Bool
	private let readPreflight: (Int32, String) throws -> Void

	public init(
		writeFrameHandler: @escaping (Int32, Data) throws -> Void,
		livenessProbe: @escaping (SpawnedProcess) -> Bool,
		readPreflight: @escaping (Int32, String) throws -> Void
	) {
		self.writeFrameHandler = writeFrameHandler
		self.livenessProbe = livenessProbe
		self.readPreflight = readPreflight
	}

	public var hasProcess: Bool { process != nil }
	public var pid: pid_t? { process?.pid }
	public var processAppearsAlive: Bool {
		guard let process else { return false }
		return livenessProbe(process)
	}

	// MARK: - Spawn + readers

	/// The single spawn site. Advances the generation, clears the terminated
	/// flag, and takes ownership of the child. Reader setup is a separate
	/// step so a reader failure can be torn down through the normal
	/// `invalidate`/`finishTermination` path.
	public func spawn(_ spec: LaunchSpec) throws -> pid_t {
		let spawned = try ProcessLauncher.spawn(
			command: spec.command,
			arguments: spec.arguments,
			environment: spec.environment,
			workingDirectory: spec.workingDirectory
		)
		isTerminated = false
		generation &+= 1
		process = spawned
		return spawned.pid
	}

	/// Starts the stdout/stderr FIFO readers for the current process.
	/// Throws (after possibly starting only the stdout reader) when a pipe
	/// FD fails preflight; the owner is expected to invalidate.
	public func startReaders(
		onStdoutChunk: @escaping @Sendable (Data) async -> Void,
		onStdoutEOF: @escaping @Sendable (_ generation: UInt64) async -> Void,
		stderrLogger: (@Sendable (String) -> Void)?
	) throws {
		guard let process else {
			throw WriteFailure.transportUnavailable
		}
		try startStdoutReader(process.stdout, onChunk: onStdoutChunk, onEOF: onStdoutEOF)
		try startStderrReader(process.stderr, logger: stderrLogger)
	}

	// SEARCH-HELPER: FIFO stdout, ProcessPipeReader, chunk ordering, EOF generation scope
	/// Starts a fresh pipe reader for stdout. The reader guarantees FIFO
	/// chunk delivery and EOF-unless-cancelled; the generation captured here
	/// scopes the owner's teardown so a stale EOF can't kill a new process.
	private func startStdoutReader(
		_ handle: FileHandle,
		onChunk: @escaping @Sendable (Data) async -> Void,
		onEOF: @escaping @Sendable (UInt64) async -> Void
	) throws {
		stdoutReader?.cancel()
		stdoutReader = nil
		let reader = ProcessPipeReader()
		let generation = generation
		try reader.start(
			handle: handle,
			label: "Codex app-server stdout",
			preflight: readPreflight,
			onChunk: onChunk,
			onEOF: { await onEOF(generation) }
		)
		stdoutReader = reader
	}

	/// Starts a fresh pipe reader for stderr; chunks route to the injected logger.
	private func startStderrReader(
		_ handle: FileHandle,
		logger: (@Sendable (String) -> Void)?
	) throws {
		stderrReader?.cancel()
		stderrReader = nil
		let reader = ProcessPipeReader()
		try reader.start(
			handle: handle,
			label: "Codex app-server stderr",
			preflight: readPreflight,
			onChunk: { chunk in
				if let logger,
					let line = String(data: chunk, encoding: .utf8),
					!line.isEmpty {
					logger(line)
				}
			}
		)
		stderrReader = reader
	}

	// MARK: - Writes

	/// Writes a single pre-framed payload to the child's stdin as one atomic
	/// write. Throws `WriteFailure.transportUnavailable` when there is no
	/// process/descriptor; otherwise rethrows the write handler's error
	/// (`FDWriteError` from the default handler).
	public func writeFrame(_ frame: Data) throws {
		guard let process, let stdinDescriptor = process.stdinDescriptor else {
			throw WriteFailure.transportUnavailable
		}
		try writeFrameHandler(stdinDescriptor, frame)
	}

	// MARK: - Termination

	/// Generation-guarded, idempotent synchronous teardown of the
	/// transport-owned state: finishes the chunk channels, cancels the
	/// consumer tasks, and snapshots + releases the process. Returns nil
	/// when the call is stale (`expectedGeneration` mismatch) or the
	/// transport already terminated; otherwise the snapshot the owner must
	/// hand to `finishTermination` exactly once.
	public func invalidate(expectedGeneration: UInt64? = nil) -> TerminationSnapshot? {
		if let expected = expectedGeneration, expected != generation { return nil }
		guard !isTerminated else { return nil }
		isTerminated = true

		stdoutReader?.cancel()
		stderrReader?.cancel()
		stdoutReader = nil
		stderrReader = nil

		let terminating = process
		process = nil
		return TerminationSnapshot(process: terminating)
	}

	/// The single reap site: closes stdin and terminates + reaps the child
	/// under the given policy. (The pipe readers detach their own handlers in
	/// `invalidate()`, which is the only producer of snapshots.) Static and
	/// state-free so the (already-invalidated) snapshot can be finished from
	/// any task without touching the actor-confined transport.
	public static func finishTermination(
		_ snapshot: TerminationSnapshot,
		terminationPolicy: ProcessTerminationPolicy,
		logger: @escaping (String) -> Void = { _ in }
	) async {
		guard let process = snapshot.process else { return }
		process.stdin?.closeFile()
		_ = await ProcessTermination.terminateAndReap(
			pid: process.pid,
			policy: terminationPolicy,
			logger: logger
		)
	}

	// MARK: - Liveness

	/// Non-destructive child-state check: exited/zombie children do not look
	/// healthy, while final reap/cleanup is left to the normal teardown path.
	public static func defaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
		var info = siginfo_t()
		let waitResult = Darwin.waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOHANG | WNOWAIT)
		if waitResult == 0, info.si_pid == process.pid {
			return false
		}
		if waitResult == -1, errno == ECHILD {
			return false
		}

		let pidState = Darwin.kill(process.pid, 0)
		if pidState == -1, errno == ESRCH {
			return false
		}
		guard let stdinDescriptor = process.stdinDescriptor else { return false }
		let descriptorFlags = fcntl(stdinDescriptor, F_GETFD)
		if descriptorFlags == -1, errno == EBADF {
			return false
		}
		return true
	}

#if DEBUG
	/// Installs a fake process for deterministic tests: takes ownership,
	/// clears the terminated flag, and advances the generation exactly as a
	/// real spawn would.
	public func debugInstallProcess(_ process: SpawnedProcess) {
		self.process = process
		isTerminated = false
		generation &+= 1
	}
#endif
}
