import Foundation

/// Test-only milestones for the invoked comparison benchmark.
///
/// Ordinary launches do not create or inspect comparison state. These calls
/// happen only after a comparison was explicitly requested, and remain inert
/// unless the benchmark supplies a private event-file path in the system
/// temporary directory.
enum ComparisonPerformanceSignal {
    enum Event: String {
        case tabVisible = "tab-visible"
        case completeReady = "complete-ready"
        case cancelled
    }

    private static let lock = NSLock()

    static func record(_ event: Event) {
        guard let path = ProcessInfo.processInfo.environment[
            "MARGIN_COMPARISON_BENCHMARK_EVENTS_FILE"
        ], !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        guard url.deletingLastPathComponent() == temporaryDirectory,
              url.lastPathComponent.hasPrefix("margin-comparison-events-") else { return }

        let line = "\(event.rawValue) \(DispatchTime.now().uptimeNanoseconds)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Benchmark telemetry must never affect comparison behavior.
        }
    }
}
