import CoreGraphics
import CryptoKit
import Darwin
import Foundation

private enum BenchmarkFailure: Error, CustomStringConvertible {
    case usage(String)
    case invalidValue(String)
    case launch(String)
    case timeout(Int)
    case measurement(String)

    var description: String {
        switch self {
        case let .usage(message), let .invalidValue(message), let .launch(message),
             let .measurement(message):
            return message
        case let .timeout(milliseconds):
            return "Margin did not finish the comparison within \(milliseconds) ms."
        }
    }
}

private struct Options {
    var appPath = ""
    var reviewPath = ""
    var outputPath = ""
    var runs = 15
    var warmups = 3
    var settleMilliseconds = 250
    var timeoutMilliseconds = 5_000
    var visibleP95LimitMilliseconds: Double?
    var completeP95LimitMilliseconds: Double?

    init(arguments: [String]) throws {
        var index = 0
        func value(after option: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw BenchmarkFailure.usage("Option \(option) requires a value.")
            }
            return arguments[index + 1]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--app": appPath = try value(after: option)
            case "--review": reviewPath = try value(after: option)
            case "--output": outputPath = try value(after: option)
            case "--runs": runs = try Self.positiveInteger(try value(after: option), option: option)
            case "--warmups":
                warmups = try Self.nonnegativeInteger(try value(after: option), option: option)
            case "--settle-ms":
                settleMilliseconds = try Self.nonnegativeInteger(
                    try value(after: option), option: option
                )
            case "--timeout-ms":
                timeoutMilliseconds = try Self.positiveInteger(
                    try value(after: option), option: option
                )
            case "--visible-p95-limit-ms":
                visibleP95LimitMilliseconds = try Self.positiveDouble(
                    try value(after: option), option: option
                )
            case "--complete-p95-limit-ms":
                completeP95LimitMilliseconds = try Self.positiveDouble(
                    try value(after: option), option: option
                )
            default:
                throw BenchmarkFailure.usage("Unknown option \(option).")
            }
            index += 2
        }

        guard !appPath.isEmpty, !reviewPath.isEmpty, !outputPath.isEmpty else {
            throw BenchmarkFailure.usage(
                "usage: comparison-benchmark --app APP --review REVIEW --output JSON "
                    + "[--runs N] [--warmups N] [--visible-p95-limit-ms N] "
                    + "[--complete-p95-limit-ms N]"
            )
        }
    }

    private static func positiveInteger(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw BenchmarkFailure.invalidValue("\(option) expects a positive integer.")
        }
        return value
    }

    private static func nonnegativeInteger(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value >= 0 else {
            throw BenchmarkFailure.invalidValue("\(option) expects a nonnegative integer.")
        }
        return value
    }

    private static func positiveDouble(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite, value > 0 else {
            throw BenchmarkFailure.invalidValue("\(option) expects a positive number.")
        }
        return value
    }
}

private struct Sample {
    let visibleMilliseconds: Double
    let tabVisibleMilliseconds: Double
    let completeMilliseconds: Double
    let residentMemoryMiB: Double
}

private struct Statistics: Encodable {
    let samples: [Double]
    let minimum: Double
    let median: Double
    let p95: Double
    let maximum: Double
    let mean: Double
    let standardDeviation: Double

    init(_ rawSamples: [Double]) {
        let samples = rawSamples.map(Self.rounded)
        let sorted = samples.sorted()
        let count = Double(sorted.count)
        let mean = sorted.reduce(0, +) / count
        let variance = sorted.reduce(0) { $0 + pow($1 - mean, 2) } / count
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        let p95Index = max(0, Int(ceil(count * 0.95)) - 1)

        self.samples = samples
        minimum = Self.rounded(sorted[0])
        self.median = Self.rounded(median)
        p95 = Self.rounded(sorted[p95Index])
        maximum = Self.rounded(sorted[sorted.count - 1])
        self.mean = Self.rounded(mean)
        standardDeviation = Self.rounded(sqrt(variance))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}

private struct BenchmarkReport: Encodable {
    struct System: Encodable {
        let operatingSystem: String
        let architecture: String
        let processorCount: Int
    }

    struct Artifact: Encodable {
        let appPath: String
        let version: String
        let executableSHA256: String
        let reviewBytes: UInt64
        let reviewSHA256: String
    }

    struct Settings: Encodable {
        let measuredRuns: Int
        let warmupRuns: Int
        let settleMilliseconds: Int
        let timeoutMilliseconds: Int
        let visibleP95LimitMilliseconds: Double?
        let completeP95LimitMilliseconds: Double?
    }

    let schema = "urn:margin:comparison-performance:v1"
    let measuredAt: String
    let measurement: String
    let system: System
    let artifact: Artifact
    let settings: Settings
    let visibleMilliseconds: Statistics
    let tabVisibleMilliseconds: Statistics
    let completeMilliseconds: Statistics
    let residentMemoryMiB: Statistics
}

private func isWindowVisible(for processIdentifier: Int32) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]] else { return false }

    for window in windows {
        let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        if owner == processIdentifier, layer == 0, alpha > 0 { return true }
    }
    return false
}

private func eventTimes(at url: URL) -> [String: UInt64] {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return [:] }
    var result: [String: UInt64] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let value = UInt64(parts[1]) else { continue }
        result[String(parts[0])] = value
    }
    return result
}

private func residentMemoryMiB(for processIdentifier: Int32) throws -> Double {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(processIdentifier)]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8),
          let kilobytes = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw BenchmarkFailure.measurement(
            "Could not read resident memory for PID \(processIdentifier)."
        )
    }
    return kilobytes / 1_024
}

private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
        usleep(10_000)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

private func measureOnce(options: Options) throws -> Sample {
    let executable = URL(fileURLWithPath: options.appPath)
        .appendingPathComponent("Contents/MacOS/Margin")
    let eventURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("margin-comparison-events-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = executable
    process.arguments = [options.reviewPath]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "MARGIN_COMPARISON_BENCHMARK_EVENTS_FILE": eventURL.path,
    ]) { _, benchmarkValue in benchmarkValue }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let start = DispatchTime.now().uptimeNanoseconds
    do {
        try process.run()
    } catch {
        throw BenchmarkFailure.launch(
            "Could not launch \(executable.path): \(error.localizedDescription)"
        )
    }
    defer {
        stop(process)
        try? FileManager.default.removeItem(at: eventURL)
    }

    let timeout = UInt64(options.timeoutMilliseconds) * 1_000_000
    var visibleAt: UInt64?
    var events: [String: UInt64] = [:]
    while process.isRunning && DispatchTime.now().uptimeNanoseconds - start < timeout {
        if visibleAt == nil, isWindowVisible(for: process.processIdentifier) {
            visibleAt = DispatchTime.now().uptimeNanoseconds
        }
        events = eventTimes(at: eventURL)
        if visibleAt != nil,
           events["tab-visible"] != nil,
           events["complete-ready"] != nil { break }
        usleep(1_000)
    }

    guard let visibleAt,
          let tabVisibleAt = events["tab-visible"],
          let completeAt = events["complete-ready"] else {
        throw BenchmarkFailure.timeout(options.timeoutMilliseconds)
    }
    guard tabVisibleAt >= start,
          completeAt >= tabVisibleAt else {
        throw BenchmarkFailure.measurement("Comparison milestones were missing or out of order.")
    }

    if options.settleMilliseconds > 0 {
        usleep(useconds_t(options.settleMilliseconds * 1_000))
    }
    guard process.isRunning else {
        throw BenchmarkFailure.measurement(
            "Margin exited before resident memory could be sampled."
        )
    }
    let residentMiB = try residentMemoryMiB(for: process.processIdentifier)
    return Sample(
        visibleMilliseconds: Double(visibleAt - start) / 1_000_000,
        tabVisibleMilliseconds: Double(tabVisibleAt - start) / 1_000_000,
        completeMilliseconds: Double(completeAt - start) / 1_000_000,
        residentMemoryMiB: residentMiB
    )
}

private func fileSize(at url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
}

private func sha256(at url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func writeProgress(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private func requireP95(
    _ statistics: Statistics,
    limit: Double?,
    name: String
) throws {
    guard let limit, statistics.p95 > limit else { return }
    throw BenchmarkFailure.measurement(
        "\(name) p95 \(statistics.p95) ms exceeded the \(limit) ms limit."
    )
}

do {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    let appURL = URL(fileURLWithPath: options.appPath).standardizedFileURL
    let reviewURL = URL(fileURLWithPath: options.reviewPath).standardizedFileURL
    let outputURL = URL(fileURLWithPath: options.outputPath).standardizedFileURL
    let executableURL = appURL.appendingPathComponent("Contents/MacOS/Margin")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw BenchmarkFailure.invalidValue("No executable Margin.app exists at \(appURL.path).")
    }
    guard FileManager.default.isReadableFile(atPath: reviewURL.path) else {
        throw BenchmarkFailure.invalidValue(
            "No readable comparison review exists at \(reviewURL.path)."
        )
    }

    if options.warmups > 0 {
        for index in 1...options.warmups {
            writeProgress("Comparison warm-up \(index)/\(options.warmups)")
            _ = try measureOnce(options: options)
        }
    }

    var samples: [Sample] = []
    for index in 1...options.runs {
        writeProgress("Comparison measured run \(index)/\(options.runs)")
        samples.append(try measureOnce(options: options))
    }

    let visible = Statistics(samples.map(\.visibleMilliseconds))
    let tabVisible = Statistics(samples.map(\.tabVisibleMilliseconds))
    let complete = Statistics(samples.map(\.completeMilliseconds))

    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let bundle = Bundle(url: appURL)
    let report = BenchmarkReport(
        measuredAt: formatter.string(from: Date()),
        measurement: "Direct app process to native comparison milestones; warm local launch proxy",
        system: .init(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: ProcessInfo.processInfo.processorCount
        ),
        artifact: .init(
            appPath: appURL.path,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            executableSHA256: try sha256(at: executableURL),
            reviewBytes: fileSize(at: reviewURL),
            reviewSHA256: try sha256(at: reviewURL)
        ),
        settings: .init(
            measuredRuns: options.runs,
            warmupRuns: options.warmups,
            settleMilliseconds: options.settleMilliseconds,
            timeoutMilliseconds: options.timeoutMilliseconds,
            visibleP95LimitMilliseconds: options.visibleP95LimitMilliseconds,
            completeP95LimitMilliseconds: options.completeP95LimitMilliseconds
        ),
        visibleMilliseconds: visible,
        tabVisibleMilliseconds: tabVisible,
        completeMilliseconds: complete,
        residentMemoryMiB: Statistics(samples.map(\.residentMemoryMiB))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)

    // Preserve every measured sample even when a release threshold fails so
    // the regression can be diagnosed from the benchmark artifact.
    try requireP95(
        visible,
        limit: options.visibleP95LimitMilliseconds,
        name: "Visible-window"
    )
    try requireP95(
        complete,
        limit: options.completeP95LimitMilliseconds,
        name: "Complete-ready"
    )

    print(
        "Comparison visible p95: \(visible.p95) ms; complete p95: \(complete.p95) ms"
    )
} catch {
    FileHandle.standardError.write(Data("comparison-benchmark: \(error)\n".utf8))
    exit(1)
}
