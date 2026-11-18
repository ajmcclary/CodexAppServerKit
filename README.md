# CodexAppServerKit

The transport layer for talking to a `codex app-server` child process over JSON-RPC on stdio.

CodexAppServerKit moves bytes and requests, and nothing else: it spawns the child, writes
newline-terminated JSON-RPC frames to its stdin, turns its stdout into decoded JSON objects
(recovering from malformed lines), classifies each object as a response, error, server request
or notification, and keeps exactly-once bookkeeping for pending requests and their timeouts.
It is vocabulary-free: it knows the JSON-RPC envelope but not what any Codex method or
notification means.

## What's inside

- `CodexJSONRPCCodec` — `classify(_:)` sorts a decoded object into an `InboundMessage`
  (`response`, `errorResponse`, `serverRequest`, `notification`, `unroutableResponse`);
  `frame(_:)` serializes a payload into one atomic newline-terminated frame.
- `CodexJSONStreamDecoder` — incremental stdout pipeline: line framing, JSON decoding, ordered
  `Event`s (`object` or `diagnostic`), and recovery from concatenated objects, embedded tails and
  raw control characters inside strings, bounded by a per-instance recovery budget. Use one
  decoder per transport generation.
- `CodexRPCRequestStore` — request-ID allocation, pending continuations with per-request
  `Metadata`, timeout tasks, cancellation and `failAll`. Each request resolves exactly once;
  late or duplicate responses are dropped. Thread-safe (lock-serialized, `Sendable`).
- `CodexAppServerProcessTransport` — the child process: `spawn(_:)` from a fully resolved
  `LaunchSpec`, ordered stdout/stderr readers, `writeFrame(_:)`, a non-destructive liveness
  probe, a `generation` counter that stops stale tasks from touching a newer process, and
  teardown via `invalidate()` → `TerminationSnapshot` →
  `finishTermination(_:terminationPolicy:)`.

## When to use it / when not

Use it when:

- you are building your own Codex app-server client and want framing, decoding, request
  bookkeeping and process lifetime handled correctly;
- you need to decode a recorded app-server stdout stream (the codec and decoder need no process).

Pick something else when:

- you need to know what a message *means* — thread/turn routing, approval and permission
  requests, tool events, token usage, version compatibility. That is
  [CodexRuntimeKit](https://github.com/ajmcclary/CodexRuntimeKit). This package does not depend
  on it (only its tests do), so you can pair the two or use either alone.
- you want a complete Codex client: the `AgentCodexClient` product of
  [AgentExecutionKit](https://github.com/ajmcclary/AgentExecutionKit) combines this transport
  with CodexRuntimeKit and adds single-flight startup, experimental admission, retries, timeouts,
  subscriptions, model pagination and teardown. (`AgentCodexExec` there drives the separate
  `codex exec` CLI path and does not use this package.)
- you only need generic process spawning or NDJSON line framing — use
  [ProcessKit](https://github.com/ajmcclary/ProcessKit) and its `ProcessStreamFraming` product
  directly.

Out of scope: locating the `codex` executable, composing or sanitizing the environment, CLI
overrides, authentication and token refresh, PID registration, recovery and restart policy, the
choice of termination policy, logging, and UI. The transport takes these as inputs — a resolved
`LaunchSpec`, injected write/liveness/preflight closures, a stderr logger, and a
`ProcessTerminationPolicy` per teardown.

## Installation

```swift
dependencies: [
    // 0.1.0-beta.6 is a prerelease identifier — SwiftPM only resolves
    // prerelease tags when the lower bound itself names one.
    .package(url: "https://github.com/ajmcclary/CodexAppServerKit.git", .upToNextMinor(from: "0.1.0-beta.6"))
]
```

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "CodexAppServerKit", package: "CodexAppServerKit")
])
```

`import CodexAppServerKit` also re-exports [ProcessKit](https://github.com/ajmcclary/ProcessKit),
whose types (`SpawnedProcess`, `ProcessTerminationPolicy`, `FDWriteSupport`) appear in or are
used with the transport's API, so you don't need a separate dependency to name them.

## Usage

```swift
import CodexAppServerKit
import Foundation

/// Spawns `codex app-server`, sends `initialize`, and routes what comes back.
/// `codexPath` and `environment` come from your own resolution policy.
func runAppServer(codexPath: String, environment: [String: String]) async throws {
    let transport = CodexAppServerProcessTransport(
        writeFrameHandler: { fd, frame in try FDWriteSupport.writeAll(frame, to: fd) },
        livenessProbe: CodexAppServerProcessTransport.defaultProcessAppearsAlive,
        readPreflight: { _, _ in }
    )
    _ = try transport.spawn(.init(command: codexPath, arguments: ["app-server"],
                                  environment: environment, workingDirectory: nil))

    let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
    try transport.startReaders(onStdoutChunk: { sink.yield($0) },
                               onStdoutEOF: { _ in sink.finish() },
                               stderrLogger: { print("stderr:", $0) })
    try transport.writeFrame(CodexJSONRPCCodec.frame(
        ["jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": ["clientInfo": ["name": "example", "version": "1.0"]]]))

    var decoder = CodexJSONStreamDecoder()  // one per transport generation
    stream: for await chunk in chunks {
        for case .object(let json) in decoder.ingest(chunk) {
            switch CodexJSONRPCCodec.classify(json) {
            case .response(let id, let result)?:
                print("response \(id):", result.keys.sorted()); break stream
            case .errorResponse(let id, let code, let message)?:
                print("error \(id) [\(code ?? 0)]: \(message)"); break stream
            case .notification(let method, _)?:
                print("notification:", method)
            case .serverRequest, .unroutableResponse, nil:
                break
            }
        }
    }

    if let snapshot = transport.invalidate() {
        await CodexAppServerProcessTransport.finishTermination(snapshot, terminationPolicy: .default)
    }
}
```

A real client registers each request in a `CodexRPCRequestStore` before writing it and resolves
it from the `response` / `errorResponse` cases; `AgentCodexClient` is a complete example.

## Requirements

- Swift tools 6.0, Swift 6 language mode with strict concurrency; built with Xcode 27.
- **macOS 27.0 only.** The transport spawns the child with ProcessKit's `ProcessLauncher` /
  `SpawnedProcess`, which are only available where AppKit is (`#if canImport(AppKit)`), so an
  iOS build cannot compile.
- Dependencies: [AgentRuntimeKit](https://github.com/ajmcclary/AgentRuntimeKit)
  (`CodexAppServerRequestID` in `InboundMessage.serverRequest`) and
  [ProcessKit](https://github.com/ajmcclary/ProcessKit) (its `ProcessKit` and
  `ProcessStreamFraming` products). CodexRuntimeKit is a test-only dependency. No third-party
  dependencies.

## Stability

Pre-1.0 (`0.1.0-beta.x`): the public API may change between minor versions, so pin with
`.upToNextMinor`.

## Development

`swift build` and `swift test` (fast; one test spawns a real `/bin/cat` child).

## Origin

Extracted from the RepoPrompt app (Apache-2.0).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
