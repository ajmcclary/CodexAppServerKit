import XCTest
import Foundation
import AgentRuntimeKit
import ProcessKit
import ProcessStreamFraming
import CodexAppServerKit

/// Public-API contract for CodexAppServerKit. Deliberately imports WITHOUT
/// `@testable`: everything asserted here must be reachable by an external
/// consumer. RepoPrompt's `CodexAppServerClient` drives exactly this
/// surface through the `CodexAppServerRuntime` re-export shim, so a symbol
/// that stops compiling here is a breaking change for the app.
///
/// The moved suites (`CodexJSONRPCCodecTests`,
/// `CodexJSONStreamDecoderTests`, `CodexRPCRequestStoreTests`) still use
/// `@testable` exactly as they did in RepoPromptCore — this file is the
/// additive external-visibility proof, not a replacement for them.
final class CodexAppServerKitPublicAPIContractTests: XCTestCase {

	// MARK: - CodexJSONRPCCodec

	func testCodecClassificationCascadeIsPubliclyMatchable() throws {
		// result wins
		guard case .response(let responseID, let result)? = CodexJSONRPCCodec.classify(
			["id": 7, "result": ["ok": true]]
		) else { return XCTFail("Expected .response") }
		XCTAssertEqual(responseID, "7")
		XCTAssertEqual(result["ok"] as? Bool, true)

		// error-with-message
		guard case .errorResponse(let errorID, let code, let message)? = CodexJSONRPCCodec.classify(
			["id": 8, "error": ["code": -32000, "message": "nope"]]
		) else { return XCTFail("Expected .errorResponse") }
		XCTAssertEqual(errorID, "8")
		XCTAssertEqual(code, -32000)
		XCTAssertEqual(message, "nope")

		// server request — carries an AgentRuntimeKit identifier across the boundary
		guard case .serverRequest(let requestID, let method, let params)? = CodexJSONRPCCodec.classify(
			["id": 9, "method": "codex/askUser", "params": ["k": "v"]]
		) else { return XCTFail("Expected .serverRequest") }
		XCTAssertEqual(requestID, CodexAppServerRequestID.int(9))
		XCTAssertEqual(requestID.displayValue, "9")
		XCTAssertEqual(method, "codex/askUser")
		XCTAssertEqual(params["k"] as? String, "v")

		// notification
		guard case .notification(let notificationMethod, _)? = CodexJSONRPCCodec.classify(
			["method": "codex/event"]
		) else { return XCTFail("Expected .notification") }
		XCTAssertEqual(notificationMethod, "codex/event")

		// unroutable
		guard case .unroutableResponse(let unroutableID)? = CodexJSONRPCCodec.classify(["id": 10])
		else { return XCTFail("Expected .unroutableResponse") }
		XCTAssertEqual(unroutableID, "10")

		// dropped
		XCTAssertNil(CodexJSONRPCCodec.classify(["nothing": true]))
	}

	func testFrameIsASingleAtomicNewlineTerminatedBuffer() throws {
		let frame = try CodexJSONRPCCodec.frame(["jsonrpc": "2.0", "id": 1])
		XCTAssertEqual(frame.last, 0x0A, "The newline must ride in the same buffer as the payload")
		XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
		let decoded = try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any]
		XCTAssertEqual(decoded?["jsonrpc"] as? String, "2.0")
	}

	// MARK: - CodexJSONStreamDecoder

	func testDecoderRecoveryBudgetIsPinned() {
		XCTAssertEqual(CodexJSONStreamDecoder.maxRecoveryAttemptsPerInstance, 128)
	}

	func testDecoderPublicSurfaceIsDrivableFromOutside() {
		var decoder = CodexJSONStreamDecoder()
		XCTAssertEqual(decoder.recoveryAttempts, 0)

		let events = decoder.ingest(Data("{\"method\":\"a\"}\n{\"method\":\"b\"}\n".utf8))
		let methods: [String] = events.compactMap {
			if case .object(let json) = $0 { return json["method"] as? String }
			return nil
		}
		XCTAssertEqual(methods, ["a", "b"], "Objects are emitted in arrival order")

		// ingestLine and flush are part of the public surface too.
		let single = decoder.ingestLine(Data("{\"method\":\"c\"}".utf8))
		XCTAssertEqual(single.count, 1)
		XCTAssertTrue(decoder.flush().isEmpty, "Nothing is buffered after complete lines")
	}

	func testDecoderDiagnosticsAreEquatableAndMatchable() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingestLine(Data("{\"a\":1}{\"b\":2}".utf8))
		let diagnostics: [CodexJSONStreamDecoder.Diagnostic] = events.compactMap {
			if case .diagnostic(let d) = $0 { return d }
			return nil
		}
		XCTAssertEqual(diagnostics, [.recoveredConcatenatedObjects(recovered: 2, segments: 2)])

		// Every case is constructible by a consumer that wants to switch on them.
		let all: [CodexJSONStreamDecoder.Diagnostic] = [
			.framerOverflow(droppedBytes: 1, retainedBytes: 2, tailSample: "x"),
			.nonJSONCandidateQuoteStateReset,
			.recoveredConcatenatedObjects(recovered: 1, segments: 1),
			.recoveredEmbeddedTail(offset: 3),
			.recoveredControlCharacters,
			.decodeFailedNoRecovery(preview: "p"),
			.recoveryBudgetExhausted
		]
		XCTAssertEqual(Set(all.map(String.init(describing:))).count, 7)
	}

	func testMalformedInputWithoutRecoveryReportsADiagnosticRatherThanThrowing() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingestLine(Data("not json at all".utf8))
		guard case .diagnostic(.decodeFailedNoRecovery(let preview))? = events.first else {
			return XCTFail("Expected .decodeFailedNoRecovery, got \(events)")
		}
		XCTAssertEqual(preview, "not json at all")
		XCTAssertEqual(decoder.recoveryAttempts, 1, "A failed line consumes exactly one budget unit")
	}

	// MARK: - CodexRPCRequestStore

	func testRequestStoreMetadataIsEquatableWithPreservedLabels() {
		let metadata = CodexRPCRequestStore.Metadata(method: "thread/start", transportGeneration: 4)
		XCTAssertEqual(metadata, CodexRPCRequestStore.Metadata(method: "thread/start", transportGeneration: 4))
		XCTAssertEqual(metadata.method, "thread/start")
		XCTAssertEqual(metadata.transportGeneration, 4)
	}

	func testRequestStoreCountersAreExternallyObservable() {
		let store = CodexRPCRequestStore()
		XCTAssertEqual(store.peekNextRequestID, 1)
		XCTAssertEqual(store.makeRequestID(), "1")
		XCTAssertEqual(store.pendingCount, 0)
		XCTAssertEqual(store.timeoutTaskCount, 0)
		XCTAssertFalse(store.resolveSuccess(id: "nope", result: [:]), "Late responses drop silently")
		XCTAssertFalse(store.resolveFailure(id: "nope", error: CancellationError()))
	}

	/// The store is `Sendable`: its state is serialized internally, so an
	/// external consumer may hand it across isolation domains. RepoPrompt's
	/// `CodexAppServerClient` still confines its instance to one actor, but
	/// that is now an ownership choice rather than a memory-safety
	/// precondition — the type used to carry unsynchronized mutable state
	/// behind a doc-comment-only confinement rule.
	func testRequestStoreIsSendableAndUsableAcrossIsolationDomains() async {
		func requireSendable<Value: Sendable>(_ value: Value) -> Value { value }
		let store = requireSendable(CodexRPCRequestStore())
		let id = store.makeRequestID()
		await Task.detached { store.scheduleTimeout(for: id, after: 60, onTimeout: { _, _ in }) }.value
		XCTAssertEqual(store.timeoutTaskCount, 1)
		store.failAll(error: CancellationError())
		XCTAssertEqual(store.timeoutTaskCount, 0)
	}

	/// `PendingContinuation` is the type the owning actor must be able to
	/// name when it registers a request.
	func testPendingContinuationTypealiasIsPublic() async {
		let store = CodexRPCRequestStore()
		let value: [String: Any] = await withCheckedContinuation { outer in
			Task {
				let result: [String: Any] = await withCheckedContinuation { inner in
					let continuation: CodexRPCRequestStore.PendingContinuation? = nil
					XCTAssertNil(continuation)
					inner.resume(returning: ["ok": true])
				}
				_ = store
				outer.resume(returning: result)
			}
		}
		XCTAssertEqual(value["ok"] as? Bool, true)
	}

	// MARK: - CodexAppServerProcessTransport

	func testLaunchSpecMemberwiseLabelsArePreserved() {
		let spec = CodexAppServerProcessTransport.LaunchSpec(
			command: "/usr/bin/codex",
			arguments: ["app-server"],
			environment: ["PATH": "/usr/bin"],
			workingDirectory: "/tmp"
		)
		XCTAssertEqual(spec.command, "/usr/bin/codex")
		XCTAssertEqual(spec.arguments, ["app-server"])
		XCTAssertEqual(spec.environment, ["PATH": "/usr/bin"])
		XCTAssertEqual(spec.workingDirectory, "/tmp")
	}

	func testTransportIsConstructibleThroughItsInjectedPortsOnly() {
		let transport = CodexAppServerProcessTransport(
			writeFrameHandler: { fd, data in try FDWriteSupport.writeAll(data, to: fd) },
			livenessProbe: { CodexAppServerProcessTransport.defaultProcessAppearsAlive($0) },
			readPreflight: { _, _ in }
		)
		XCTAssertEqual(transport.generation, 0)
		XCTAssertFalse(transport.isTerminated)
		XCTAssertFalse(transport.hasProcess)
		XCTAssertNil(transport.pid)
	}

	func testWriteFailureIsPubliclyMatchable() {
		let error: Error = CodexAppServerProcessTransport.WriteFailure.transportUnavailable
		guard case CodexAppServerProcessTransport.WriteFailure.transportUnavailable = error else {
			return XCTFail("Expected .transportUnavailable")
		}
	}

	// MARK: - Cross-package composition

	/// The kit sits above AgentRuntimeKit and ProcessKit and below nothing:
	/// this pins that all three vocabularies meet in one expression an app
	/// can write.
	func testTransportAndCodecComposeWithTheDependencyVocabularies() throws {
		let requestID = try XCTUnwrap(CodexAppServerRequestID(raw: "abc"))
		guard case .serverRequest(let decoded, _, _)? = CodexJSONRPCCodec.classify(
			["id": "abc", "method": "m"]
		) else { return XCTFail("Expected .serverRequest") }
		XCTAssertEqual(decoded, requestID)

		let policy = ProcessTerminationPolicy.default
		XCTAssertGreaterThan(policy.sigtermGracePeriod, .zero)

		var framer = LineFramer()
		var lines = 0
		framer.feed(try CodexJSONRPCCodec.frame(["id": 1])) { _ in lines += 1 }
		XCTAssertEqual(lines, 1, "A codec frame is exactly one NDJSON line")
	}
}
