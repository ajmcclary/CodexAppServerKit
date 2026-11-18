// ProcessKit types (`SpawnedProcess`, `ProcessTerminationPolicy`) appear in
// `CodexAppServerProcessTransport`'s public API. Re-export the module so a
// client that imports CodexAppServerKit can name them without adding a
// second dependency and import. Only the `ProcessKit` module is re-exported;
// `ProcessStreamFraming` stays an implementation detail of the decoder.
@_exported import ProcessKit
