import XCTest
@testable import CodexAppServerKit

final class CodexJSONStreamDecoderTests: XCTestCase {
	private func objects(_ events: [CodexJSONStreamDecoder.Event]) -> [[String: Any]] {
		events.compactMap { if case .object(let json) = $0 { return json } else { return nil } }
	}

	private func diagnostics(_ events: [CodexJSONStreamDecoder.Event]) -> [CodexJSONStreamDecoder.Diagnostic] {
		events.compactMap { if case .diagnostic(let d) = $0 { return d } else { return nil } }
	}

	func testIngestSplitsChunksIntoLineObjects() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingest(Data("{\"method\":\"a\"}\n{\"method\":\"b\"}\n".utf8))
		let decoded = objects(events)
		XCTAssertEqual(decoded.count, 2)
		XCTAssertEqual(decoded[0]["method"] as? String, "a")
		XCTAssertEqual(decoded[1]["method"] as? String, "b")
		XCTAssertEqual(decoder.recoveryAttempts, 0)
	}

	func testPartialLineHeldUntilNewlineThenFlushDrainsRemainder() {
		var decoder = CodexJSONStreamDecoder()
		XCTAssertTrue(objects(decoder.ingest(Data("{\"method\":".utf8))).isEmpty)
		XCTAssertEqual(objects(decoder.ingest(Data("\"a\"}\n{\"method\":\"tail\"}".utf8))).count, 1)
		let flushed = objects(decoder.flush())
		XCTAssertEqual(flushed.count, 1)
		XCTAssertEqual(flushed[0]["method"] as? String, "tail")
	}

	func testConcatenatedObjectsRecoverWithDiagnostic() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingestLine(Data("{\"method\":\"a\"}{\"method\":\"b\"}".utf8))
		XCTAssertEqual(objects(events).count, 2)
		XCTAssertTrue(diagnostics(events).contains(.recoveredConcatenatedObjects(recovered: 2, segments: 2)))
		XCTAssertEqual(decoder.recoveryAttempts, 0, "Successful recovery resets the budget")
	}

	func testEmbeddedTailRecoversRightmostObject() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingestLine(Data("\u{1B}[0m noisy prefix {\"method\":\"tail/evt\",\"params\":{}}".utf8))
		let decoded = objects(events)
		XCTAssertEqual(decoded.count, 1)
		XCTAssertEqual(decoded[0]["method"] as? String, "tail/evt")
	}

	func testControlCharacterRepairRecovers() {
		var decoder = CodexJSONStreamDecoder()
		// Raw LF inside a JSON string — the repair helper only engages when the
		// payload contains an unescaped LF/CR byte.
		var line = Data("{\"method\":\"ctl\",\"params\":{\"t\":\"a".utf8)
		line.append(0x0A)
		line.append(contentsOf: Data("b\"}}".utf8))
		let events = decoder.ingestLine(line)
		XCTAssertEqual(objects(events).count, 1)
		XCTAssertTrue(diagnostics(events).contains(.recoveredControlCharacters))
	}

	func testUnrecoverableLineEmitsDecodeFailedAndConsumesBudget() {
		var decoder = CodexJSONStreamDecoder()
		let events = decoder.ingestLine(Data("{\"broken".utf8))
		XCTAssertTrue(objects(events).isEmpty)
		guard case .decodeFailedNoRecovery? = diagnostics(events).first else {
			return XCTFail("Expected decodeFailedNoRecovery, got \(diagnostics(events))")
		}
		XCTAssertEqual(decoder.recoveryAttempts, 1)
	}

	func testBudgetExhaustionEmitsDiagnosticInsteadOfRecovering() {
		var decoder = CodexJSONStreamDecoder()
		let malformed = Data("{\"broken".utf8)
		for _ in 0..<CodexJSONStreamDecoder.maxRecoveryAttemptsPerInstance {
			_ = decoder.ingestLine(malformed)
		}
		XCTAssertEqual(decoder.recoveryAttempts, CodexJSONStreamDecoder.maxRecoveryAttemptsPerInstance)
		let events = decoder.ingestLine(malformed)
		XCTAssertEqual(diagnostics(events), [.recoveryBudgetExhausted])
	}

	func testWhitespaceOnlyAndEmptyLinesAreIgnored() {
		var decoder = CodexJSONStreamDecoder()
		XCTAssertTrue(decoder.ingestLine(Data("   \t ".utf8)).isEmpty)
		XCTAssertTrue(decoder.ingestLine(Data()).isEmpty)
		XCTAssertEqual(decoder.recoveryAttempts, 0)
	}
}
