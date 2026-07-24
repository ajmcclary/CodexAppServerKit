import Foundation
import ProcessStreamFraming

/// Owns the Codex app-server stdout byte pipeline: line framing, JSON
/// decoding, malformed-line recovery (concatenated-object splitting,
/// embedded-tail scan, control-character repair), and the per-transport
/// recovery budget. One instance per transport generation; the client
/// replaces the instance on process (re)start. Inputs are raw chunks or
/// framed lines; outputs are decoded JSON objects plus diagnostics — no
/// routing, no transport policy.
public struct CodexJSONStreamDecoder {
	public init() {}

	public enum Event {
		case object([String: Any])
		case diagnostic(Diagnostic)
	}

	public enum Diagnostic: Equatable {
		case framerOverflow(droppedBytes: Int, retainedBytes: Int, tailSample: String?)
		case nonJSONCandidateQuoteStateReset
		case recoveredConcatenatedObjects(recovered: Int, segments: Int)
		case recoveredEmbeddedTail(offset: Int)
		case recoveredControlCharacters
		case decodeFailedNoRecovery(preview: String)
		case recoveryBudgetExhausted
	}

	/// Per-transport decode-recovery cap; bounds CPU spent on malformed lines.
	public static let maxRecoveryAttemptsPerInstance = 128
	/// Maximum line size for concatenated-segment recovery to avoid expensive scans.
	private static let maxConcatenatedRecoveryBytes = 2 * 1024 * 1024 // 2 MB
	/// Maximum trailing bytes to scan for embedded-tail recovery.
	private static let maxTailRecoveryScanBytes = 256 * 1024 // 256 KB

	/// JSON-RPC marker byte sequences used to locate potential object start positions.
	private static let jsonRPCMarkers: [[UInt8]] = [
		Array("{\"method\"".utf8),
		Array("{\"id\"".utf8),
		Array("{\"result\"".utf8),
		Array("{\"error\"".utf8),
		Array("{\"jsonrpc\"".utf8),
	]

	private var framer = LineFramer()
	private var tail = Data()
	public private(set) var recoveryAttempts = 0

	/// Feeds a raw stdout chunk; returns decoded objects + diagnostics in order.
	public mutating func ingest(_ chunk: Data) -> [Event] {
		appendTail(&tail, chunk: chunk, limit: 128 * 1024)
		let tailSnapshot = tail
		var events: [Event] = []
		var lines: [Data] = []
		framer.feed(chunk, onDiagnostic: { diagnostic in
			switch diagnostic {
			case .overflow(let droppedBytes, let retainedBytes):
				let sample = makeUTF8Sample(from: tailSnapshot, limit: 180)
					.map { $0.1 ? "\($0.0)…" : $0.0 }
				events.append(.diagnostic(.framerOverflow(
					droppedBytes: droppedBytes,
					retainedBytes: retainedBytes,
					tailSample: sample
				)))
			case .nonJSONCandidateQuoteStateReset:
				events.append(.diagnostic(.nonJSONCandidateQuoteStateReset))
			}
		}, onLine: { lineData in
			lines.append(lineData)
		})
		for lineData in lines {
			events.append(contentsOf: ingestLine(lineData))
		}
		return events
	}

	/// Decodes one framed line (also the debug raw-ingest path).
	public mutating func ingestLine(_ lineData: Data) -> [Event] {
		guard let trimmed = trimmedASCIIWhitespace(lineData) else { return [] }
		if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
			recoveryAttempts = 0
			return [.object(json)]
		}
		guard recoveryAttempts < Self.maxRecoveryAttemptsPerInstance else {
			return [.diagnostic(.recoveryBudgetExhausted)]
		}
		recoveryAttempts += 1
		if let events = recoverConcatenatedJSONLines(from: trimmed) {
			return events
		}
		if let events = recoverEmbeddedJSONTail(from: trimmed) {
			return events
		}
		if let events = recoverInvalidJSONStringControlChars(from: trimmed) {
			return events
		}
		let preview = String(data: trimmed.prefix(500), encoding: .utf8) ?? "<non-utf8>"
		return [.diagnostic(.decodeFailedNoRecovery(preview: preview))]
	}

	/// Drains buffered partial lines (transport teardown path).
	public mutating func flush() -> [Event] {
		var lines: [Data] = []
		framer.flush { lineData in
			lines.append(lineData)
		}
		var events: [Event] = []
		for lineData in lines {
			events.append(contentsOf: ingestLine(lineData))
		}
		return events
	}

	// MARK: - Recovery heuristics

	/// Splits a corrupted line into multiple concatenated JSON objects using
	/// brace-depth scanning. Returns nil when the heuristic does not apply.
	private mutating func recoverConcatenatedJSONLines(from lineData: Data) -> [Event]? {
		guard lineData.count <= Self.maxConcatenatedRecoveryBytes else { return nil }
		let segments = JSONStreamFramer.splitConcatenatedObjects(lineData).frames
		guard !segments.isEmpty else { return nil }
		let looksCorrupted =
			segments.count > 1
			|| (segments.count == 1 && segments[0].count != lineData.count)
		guard looksCorrupted else { return nil }

		var events: [Event] = []
		for segment in segments {
			guard let json = try? JSONSerialization.jsonObject(with: segment) as? [String: Any] else {
				continue
			}
			events.append(.object(json))
		}
		guard !events.isEmpty else { return nil }
		recoveryAttempts = 0
		events.append(.diagnostic(.recoveredConcatenatedObjects(
			recovered: events.count,
			segments: segments.count
		)))
		return events
	}

	/// Scans the tail of a corrupted line for an embedded valid JSON-RPC object.
	private mutating func recoverEmbeddedJSONTail(from lineData: Data) -> [Event]? {
		guard !lineData.isEmpty else { return nil }

		let scanWindow: Data
		let scanOffset: Int
		if lineData.count > Self.maxTailRecoveryScanBytes {
			scanOffset = lineData.count - Self.maxTailRecoveryScanBytes
			scanWindow = lineData.suffix(Self.maxTailRecoveryScanBytes)
		} else {
			scanOffset = 0
			scanWindow = lineData
		}

		let markerOffsets = Self.jsonRPCObjectStartOffsets(in: scanWindow, markers: Self.jsonRPCMarkers)
		guard !markerOffsets.isEmpty else { return nil }

		// Skip offset 0 if it's the start of the original data (already failed upstream).
		let candidateOffsets: [Int]
		if markerOffsets.first == 0, scanOffset == 0 {
			candidateOffsets = Array(markerOffsets.dropFirst())
		} else {
			candidateOffsets = markerOffsets
		}
		guard !candidateOffsets.isEmpty else { return nil }

		// Try candidates from the end (prefer the rightmost / latest embedded JSON).
		for offset in candidateOffsets.reversed() {
			let absoluteOffset = scanOffset + offset
			let suffixData = lineData.suffix(from: lineData.startIndex + absoluteOffset)
			guard let json = try? JSONSerialization.jsonObject(with: suffixData) as? [String: Any] else {
				continue
			}
			recoveryAttempts = 0
			return [
				.object(json),
				.diagnostic(.recoveredEmbeddedTail(offset: absoluteOffset))
			]
		}
		return nil
	}

	private mutating func recoverInvalidJSONStringControlChars(from lineData: Data) -> [Event]? {
		guard let repaired = repairJSONStringControlCharacters(lineData) else { return nil }
		guard let json = try? JSONSerialization.jsonObject(with: repaired) as? [String: Any] else {
			return nil
		}
		recoveryAttempts = 0
		return [.object(json), .diagnostic(.recoveredControlCharacters)]
	}

	/// Finds byte offsets of JSON-RPC marker sequences in raw Data.
	private static func jsonRPCObjectStartOffsets(in data: Data, markers: [[UInt8]]) -> [Int] {
		guard !data.isEmpty, !markers.isEmpty else { return [] }
		var offsets = Set<Int>()
		data.withUnsafeBytes { buffer in
			guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			for marker in markers {
				guard data.count >= marker.count else { continue }
				let searchLimit = data.count - marker.count
				for i in 0...searchLimit {
					var matches = true
					for j in 0..<marker.count {
						if baseAddress[i + j] != marker[j] {
							matches = false
							break
						}
					}
					if matches {
						offsets.insert(i)
					}
				}
			}
		}
		return offsets.sorted()
	}
}
