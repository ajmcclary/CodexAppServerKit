import Foundation
import AgentRuntimeKit

/// Pure JSON-RPC framing + inbound classification for the Codex app-server
/// wire protocol. Owns no transport state: decoded objects in, typed
/// messages out; payloads in, atomic newline-terminated frames out.
public enum CodexJSONRPCCodec {
	/// A decoded inbound JSON-RPC object, classified with the app-server
	/// routing cascade: result → error-with-message → server request →
	/// unroutable; id-less objects with a method are notifications.
	public enum InboundMessage {
		case response(id: String, result: [String: Any])
		case errorResponse(id: String, code: Int?, message: String)
		case serverRequest(id: CodexAppServerRequestID, method: String, params: [String: Any])
		case notification(method: String, params: [String: Any])
		case unroutableResponse(id: String)
	}

	/// Returns nil for objects with neither an id nor a method (dropped,
	/// preserving the legacy silent-ignore behavior).
	public static func classify(_ json: [String: Any]) -> InboundMessage? {
		if let idValue = json["id"] {
			let idString = String(describing: idValue)
			if let result = json["result"] as? [String: Any] {
				return .response(id: idString, result: result)
			}
			if let error = json["error"] as? [String: Any],
				let message = error["message"] as? String {
				return .errorResponse(id: idString, code: error["code"] as? Int, message: message)
			}
			if let method = json["method"] as? String,
				let requestID = CodexAppServerRequestID(raw: idValue) {
				return .serverRequest(
					id: requestID,
					method: method,
					params: json["params"] as? [String: Any] ?? [:]
				)
			}
			return .unroutableResponse(id: idString)
		}
		if let method = json["method"] as? String {
			return .notification(method: method, params: json["params"] as? [String: Any] ?? [:])
		}
		return nil
	}

	/// Serializes a payload into a single atomic frame (JSON + trailing
	/// newline). Combining payload and newline into one buffer prevents pipe
	/// interleaving between two separate writes.
	public static func frame(_ payload: [String: Any]) throws -> Data {
		var data = try JSONSerialization.data(withJSONObject: payload, options: [])
		data.append(0x0A)
		return data
	}
}
