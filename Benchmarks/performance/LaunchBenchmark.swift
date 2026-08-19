import CoreGraphics
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
        case let .usage(message), let .invalidValue(message), let .launch(message), let .measurement(message):
            return message
        case let .timeout(milliseconds):
            return "Margin did not show an on-screen window within \(milliseconds) ms."
        }
    }
}

private struct Options {
    var appPath = ""
    var documentPath = ""
    var outputPath = ""
    var runs = 15
    var warmups = 3
    var settleMilliseconds = 250
    var timeoutMilliseconds = 5_000
    var visibleP95LimitMilliseconds: Double?
    var readyP95LimitMilliseconds: Double?

    init(arguments: [String]) throws {
        var index = 0
        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BenchmarkFailure.usage("Option \(option) requires a value.")
            }
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--app": appPath = try value(after: option)
            case "--document": documentPath = try value(after: option)
            case "--output": outputPath = try value(after: option)
            case "--runs": runs = try Self.positiveInteger(try value(after: option), option: option)
            case "--warmups": warmups = try Self.nonnegativeInteger(try value(after: option), option: option)
            case "--settle-ms": settleMilliseconds = try Self.nonnegativeInteger(try value(after: option), option: option)
            case "--timeout-ms": timeoutMilliseconds = try Self.positiveInteger(try value(after: option), option: option)
            case "--visible-p95-limit-ms":
                visibleP95LimitMilliseconds = try Self.positiveDouble(try value(after: option), option: option)
            case "--ready-p95-limit-ms":
                readyP95LimitMilliseconds = try Self.positiveDouble(try value(after: option), option: option)
            default: throw BenchmarkFailure.usage("Unknown option \(option).")
            }
            index += 2
        }

        guard !appPath.isEmpty, !documentPath.isEmpty, !outputPath.isEmpty else {
            throw BenchmarkFailure.usage(
                "usage: launch-benchmark --app APP --document FILE_OR_DIRECTORY --output JSON [--runs N] [--warmups N] [--visible-p95-limit-ms N] [--ready-p95-limit-ms N]"
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
    let launchMilliseconds: Double
    let readyMilliseconds: Double
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
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[(sorted.count / 2) - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
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
        let bundleLogicalBytes: UInt64
        let executableBytes: UInt64
    }

    struct Settings: Encodable {
        let measuredRuns: Int
        let warmupRuns: Int
        let settleMilliseconds: Int
        let timeoutMilliseconds: Int
        let documentPath: String
        let visibleP95LimitMilliseconds: Double?
        let readyP95LimitMilliseconds: Double?
    }

    let schema = "urn:margin:performance:v2"
    let measuredAt: String
    let measurement: String
    let system: System
    let artifact: Artifact
    let settings: Settings
    let launchMilliseconds: Statistics
    let readyMilliseconds: Statistics
    let residentMemoryMiB: Statistics
}

private func isWindowVisible(for processIdentifier: Int32) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }

    let ownerKey = kCGWindowOwnerPID as String
    let layerKey = kCGWindowLayer as String
    let alphaKey = kCGWindowAlpha as String
    for window in windows {
        guard (window[ownerKey] as? NSNumber)?.int32Value == processIdentifier,
              (window[layerKey] as? NSNumber)?.intValue == 0 else { continue }
        let alpha = (window[alphaKey] as? NSNumber)?.doubleValue ?? 1
        if alpha > 0 { return true }
    }
    return false
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
        throw BenchmarkFailure.measurement("Could not read resident memory for PID \(processIdentifier).")
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
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

private func measureOnce(options: Options) throws -> Sample {
    let executable = URL(fileURLWithPath: options.appPath)
        .appendingPathComponent("Contents/MacOS/Margin")
    let process = Process()
    process.executableURL = executable
    process.arguments = [options.documentPath]
    let readyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("margin-ready-\(UUID().uuidString)", isDirectory: false)
    process.environment = ProcessInfo.processInfo.environment.merging([
        "MARGIN_BENCHMARK_READY_FILE": readyURL.path,
    ]) { _, benchmarkValue in benchmarkValue }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let start = DispatchTime.now().uptimeNanoseconds
    do {
        try process.run()
    } catch {
        throw BenchmarkFailure.launch("Could not launch \(executable.path): \(error.localizedDescription)")
    }
    defer {
        stop(process)
        try? FileManager.default.removeItem(at: readyURL)
    }

    let timeout = UInt64(options.timeoutMilliseconds) * 1_000_000
    var visibleAt: UInt64?
    var readyAt: UInt64?
    while process.isRunning && DispatchTime.now().uptimeNanoseconds - start < timeout {
        if visibleAt == nil, isWindowVisible(for: process.processIdentifier) {
            visibleAt = DispatchTime.now().uptimeNanoseconds
        }
        if readyAt == nil, FileManager.default.fileExists(atPath: readyURL.path) {
            readyAt = DispatchTime.now().uptimeNanoseconds
        }
        if visibleAt != nil, readyAt != nil {
            break
        }
        usleep(1_000)
    }
    guard let visibleAt else {
        throw BenchmarkFailure.timeout(options.timeoutMilliseconds)
    }
    guard let readyAt else {
        throw BenchmarkFailure.measurement(
            "Margin showed a window but did not finish loading the benchmark target within \(options.timeoutMilliseconds) ms."
        )
    }

    if options.settleMilliseconds > 0 {
        usleep(useconds_t(options.settleMilliseconds * 1_000))
    }
    guard process.isRunning else {
        throw BenchmarkFailure.measurement("Margin exited before resident memory could be sampled.")
    }
    let residentMiB = try residentMemoryMiB(for: process.processIdentifier)
    return Sample(
        launchMilliseconds: Double(visibleAt - start) / 1_000_000,
        readyMilliseconds: Double(readyAt - start) / 1_000_000,
        residentMemoryMiB: residentMiB
    )
}

private func logicalBundleSize(at appURL: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: appURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: UInt64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true,
              let bytes = values.fileSize else { continue }
        total += UInt64(bytes)
    }
    return total
}

private func fileSize(at url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
}

private func writeProgress(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

do {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    let appURL = URL(fileURLWithPath: options.appPath).standardizedFileURL
    let executableURL = appURL.appendingPathComponent("Contents/MacOS/Margin")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw BenchmarkFailure.invalidValue("No executable Margin.app exists at \(appURL.path).")
    }

    if options.warmups > 0 {
        for index in 1...options.warmups {
            writeProgress("Warm-up \(index)/\(options.warmups)")
            _ = try measureOnce(options: options)
        }
    }

    var samples: [Sample] = []
    for index in 1...options.runs {
        writeProgress("Measured run \(index)/\(options.runs)")
        samples.append(try measureOnce(options: options))
    }

    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif

    let bundle = Bundle(url: appURL)
    let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let report = BenchmarkReport(
        measuredAt: formatter.string(from: Date()),
        measurement: "Warm direct-executable spawn to first on-screen layer-0 app window and to completion of target loading and initial Markdown presentation; RSS sampled after the settle interval.",
        system: .init(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: ProcessInfo.processInfo.processorCount
        ),
        artifact: .init(
            appPath: appURL.path,
            version: version,
            bundleLogicalBytes: logicalBundleSize(at: appURL),
            executableBytes: fileSize(at: executableURL)
        ),
        settings: .init(
            measuredRuns: options.runs,
            warmupRuns: options.warmups,
            settleMilliseconds: options.settleMilliseconds,
            timeoutMilliseconds: options.timeoutMilliseconds,
            documentPath: URL(fileURLWithPath: options.documentPath).standardizedFileURL.path,
            visibleP95LimitMilliseconds: options.visibleP95LimitMilliseconds,
            readyP95LimitMilliseconds: options.readyP95LimitMilliseconds
        ),
        launchMilliseconds: Statistics(samples.map(\.launchMilliseconds)),
        readyMilliseconds: Statistics(samples.map(\.readyMilliseconds)),
        residentMemoryMiB: Statistics(samples.map(\.residentMemoryMiB))
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(0x0A)
    let outputURL = URL(fileURLWithPath: options.outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)
    FileHandle.standardOutput.write(data)

    if let limit = options.visibleP95LimitMilliseconds, report.launchMilliseconds.p95 > limit {
        throw BenchmarkFailure.measurement(
            "Visible-window p95 \(report.launchMilliseconds.p95) ms exceeds the \(limit) ms limit."
        )
    }
    if let limit = options.readyP95LimitMilliseconds, report.readyMilliseconds.p95 > limit {
        throw BenchmarkFailure.measurement(
            "Target-ready p95 \(report.readyMilliseconds.p95) ms exceeds the \(limit) ms limit."
        )
    }
} catch {
    let message = (error as? BenchmarkFailure)?.description ?? error.localizedDescription
    fputs("launch-benchmark: \(message)\n", stderr)
    exit(1)
}
