// swift-tools-version: 6.0
import PackageDescription

// CodexAppServerKit — the mechanical Codex app-server transport layer.
//
// Promoted out of RepoPrompt's internal RepoPromptCore package (its
// CodexAppServerRuntime target) as the sixth extraction of the migrate.md
// package map and the second provider-runtime promotion (staged-plan
// step 5, continuing after CodexRuntimeKit). RepoPromptCore's
// CodexAppServerRuntime target is now an @_exported re-export shim over
// this package (the AgentRuntimeKit / PromptAssemblyKit / ApplyEditsKit /
// CodexRuntimeKit promotion precedent).
//
// Scope — transport mechanics only:
//
// - `CodexJSONRPCCodec` — JSON-RPC wire framing and inbound classification
//   (result → error-with-message → server request → unroutable; id-less
//   objects with a method are notifications), plus atomic
//   newline-terminated frame serialization.
// - `CodexJSONStreamDecoder` — the incremental stdout byte pipeline: line
//   framing, JSON decoding, ordered object/diagnostic emission, and
//   malformed-line recovery (concatenated-object splitting, embedded-tail
//   scan, control-character repair) under a per-instance recovery budget.
// - `CodexRPCRequestStore` — request-ID allocation, pending continuations,
//   per-request metadata, timeout tasks, and exactly-once resolution
//   (removal-before-resume), including cancellation and transport-wide
//   failure.
// - `CodexAppServerProcessTransport` — the child-process transport that
//   turns ordered byte streams into app-server traffic: the single spawn
//   site, generation counter, stdout/stderr pipe readers, atomic stdin
//   frame writes, the non-destructive liveness probe, and the
//   invalidate → `TerminationSnapshot` → `finishTermination` teardown
//   path. Its transport-local error (`WriteFailure.transportUnavailable`)
//   lives here too.
//
// Deliberately OUT of scope — RepoPrompt keeps ALL of it:
//
// - Codex session/thread/turn semantics, normalized runtime events,
//   server-request/notification interpretation, tool-event normalization,
//   compatibility/admission, model policy, and the protocol-lock snapshot
//   (those are CodexRuntimeKit, which this package does NOT depend on:
//   the transport is vocabulary-free by construction).
// - CLI launch profiles, executable resolution, environment composition
//   and sanitization, CLI overrides, authentication and refresh policy —
//   `LaunchSpec` arrives fully resolved and the transport only spawns.
// - PID registration, process-ownership bookkeeping, recovery/restart
//   policy, and the *choice* of `ProcessTerminationPolicy` (passed per
//   reap), stderr logging (injected), and the FD read preflight
//   (injected).
// - SwiftUI/AppKit, persistence, workspace authority, view models,
//   AgentChatItem projection, and every application-specific
//   orchestration concern.
// - Generic multi-provider transport abstractions. The neutral NDJSON
//   framing primitives this package rides on stay one level down in
//   ProcessKit's `ProcessStreamFraming` product, shared with RepoPrompt's
//   Claude / ACP / Gemini / Codex-exec consumers.
//
// Platform floor: macOS 14 ONLY — a deliberate divergence from the
// macOS 14 + iOS 17 kits. `CodexAppServerProcessTransport` uses
// `ProcessKit.SpawnedProcess` / `ProcessLauncher` unconditionally, and
// those are declared inside `#if canImport(AppKit)` (macOS), so an iOS
// floor would be unprovable. The ApplyEditsKit precedent: claim only what
// a clean build proves.
//
// Package dependencies:
// - AgentRuntimeKit — `CodexAppServerRequestID` crosses the boundary in
//   `CodexJSONRPCCodec.InboundMessage.serverRequest`.
// - ProcessKit — `ProcessLauncher` / `SpawnedProcess` /
//   `ProcessPipeReader` / `ProcessTermination` / `ProcessTerminationPolicy`
//   for the transport, and the `ProcessStreamFraming` product for the
//   decoder's line framing and raw-byte helpers.
// - CodexRuntimeKit — TEST TARGET ONLY. The moved
//   `CodexRPCRequestStoreTests` characterizes the store against real
//   `CodexClientError` values, exactly as it did in RepoPromptCore. The
//   library target does not link it, so library consumers do not either.
//
// Swift 5 language mode keeps the moved code byte-behaviorally identical
// (AgentRuntimeKit / PromptAssemblyKit / ApplyEditsKit / CodexRuntimeKit /
// RepoPromptCore promoted-target precedent).
let package = Package(
    name: "CodexAppServerKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CodexAppServerKit", targets: ["CodexAppServerKit"])
    ],
    dependencies: [
        // Provider-neutral agent vocabulary: CodexAppServerRequestID.
        // Prerelease lower bound named explicitly (SwiftPM only resolves
        // prerelease tags when the requirement names one — ProcessKit rule).
        .package(url: "https://github.com/ajmcclary/AgentRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.1")),
        // Process primitives + the NDJSON framing layer. 0.1.0-beta.4 is the
        // first tag carrying the separately-linkable ProcessStreamFraming
        // product this package's decoder requires.
        .package(url: "https://github.com/ajmcclary/ProcessKit.git", .upToNextMinor(from: "0.1.0-beta.4")),
        // Test target only — CodexClientError in the moved request-store
        // characterization suite. Not a library dependency.
        .package(url: "https://github.com/ajmcclary/CodexRuntimeKit.git", .upToNextMinor(from: "0.1.0-beta.1"))
    ],
    targets: [
        .target(
            name: "CodexAppServerKit",
            dependencies: [
                .product(name: "AgentRuntimeKit", package: "AgentRuntimeKit"),
                .product(name: "ProcessKit", package: "ProcessKit"),
                .product(name: "ProcessStreamFraming", package: "ProcessKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CodexAppServerKitTests",
            dependencies: [
                "CodexAppServerKit",
                .product(name: "CodexRuntimeKit", package: "CodexRuntimeKit")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
