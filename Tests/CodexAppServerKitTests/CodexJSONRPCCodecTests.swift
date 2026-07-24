import XCTest
@testable import CodexAppServerKit

final class CodexJSONRPCCodecTests: XCTestCase {
	func testResultWinsOverErrorAndMethod() throws {
		let message = CodexJSONRPCCodec.classify([
			"id": 7, "result": ["ok": true], "error": ["message": "x"], "method": "m"
		])
		guard case .response(let id, let result)? = message else {
			return XCTFail("Expected response, got \(String(describing: message))")
		}
		XCTAssertEqual(id, "7")
		XCTAssertEqual(result["ok"] as? Bool, true)
	}

	func testErrorRequiresMessageElseFallsThroughToServerRequest() {
		let message = CodexJSONRPCCodec.classify([
			"id": 3, "error": ["code": -1], "method": "server/ask", "params": ["k": "v"]
		])
		guard case .serverRequest(_, let method, let params)? = message else {
			return XCTFail("Expected serverRequest, got \(String(describing: message))")
		}
		XCTAssertEqual(method, "server/ask")
		XCTAssertEqual(params["k"] as? String, "v")
	}

	func testErrorResponseCarriesOptionalCode() {
		guard case .errorResponse(let id, let code, let message)? =
			CodexJSONRPCCodec.classify(["id": "abc", "error": ["code": -32001, "message": "overloaded"]]) else {
			return XCTFail("Expected errorResponse")
		}
		XCTAssertEqual(id, "abc")
		XCTAssertEqual(code, -32001)
		XCTAssertEqual(message, "overloaded")
		guard case .errorResponse(_, let missingCode, _)? =
			CodexJSONRPCCodec.classify(["id": 1, "error": ["message": "bare"]]) else {
			return XCTFail("Expected errorResponse without code")
		}
		XCTAssertNil(missingCode)
	}

	func testIDWithoutResultErrorOrValidMethodIsUnroutable() {
		guard case .unroutableResponse(let id)? = CodexJSONRPCCodec.classify(["id": 9]) else {
			return XCTFail("Expected unroutableResponse")
		}
		XCTAssertEqual(id, "9")
		// id of an unsupported raw type (array) invalidates the server-request path too
		guard case .unroutableResponse? = CodexJSONRPCCodec.classify(["id": [1, 2], "method": "m"]) else {
			return XCTFail("Expected unroutableResponse for unparseable request id")
		}
	}

	func testMethodWithoutIDIsNotificationAndDefaultsParams() {
		guard case .notification(let method, let params)? =
			CodexJSONRPCCodec.classify(["method": "turn/completed"]) else {
			return XCTFail("Expected notification")
		}
		XCTAssertEqual(method, "turn/completed")
		XCTAssertTrue(params.isEmpty)
	}

	func testObjectWithNeitherIDNorMethodIsDropped() {
		XCTAssertNil(CodexJSONRPCCodec.classify(["params": ["x": 1]]))
	}

	func testFrameAppendsSingleNewline() throws {
		let frame = try CodexJSONRPCCodec.frame(["method": "initialized"])
		XCTAssertEqual(frame.last, 0x0A)
		let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any])
		XCTAssertEqual(payload["method"] as? String, "initialized")
	}
}
