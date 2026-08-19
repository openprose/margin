import Foundation

/// A test-only readiness marker for the external launch benchmark.
///
/// Normal launches do no I/O here because the environment variable is absent.
/// Benchmarks use a fresh path for every process and watch for the atomic marker
/// after the initial document has been decoded and presented by the editor.
enum StartupPerformanceSignal {
    private static var didSignal = false

    static func documentReady() {
        precondition(Thread.isMainThread)
        guard !didSignal,
              let path = ProcessInfo.processInfo.environment["MARGIN_BENCHMARK_READY_FILE"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard url.deletingLastPathComponent() == temporaryDirectory,
              url.lastPathComponent.hasPrefix("margin-ready-") else { return }
        didSignal = true
        try? Data("ready\n".utf8).write(to: url, options: .atomic)
    }
}
