import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum AppLauncher {
    static let comparisonRequestExtension = "margincompare-request"
    static let maximumComparisonRequestBytes = 64 * 1_024 * 1_024

    static func open(_ item: URL?, wait: Bool, appOverride: String?) throws {
        try open(item.map { [$0] } ?? [], wait: wait, appOverride: appOverride)
    }

    static func open(_ items: [URL], wait: Bool, appOverride: String?) throws {
#if os(macOS)
        let app = try locateApp(override: appOverride)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = launchArguments(app: app, items: items, wait: wait)

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError("APP_LAUNCH_FAILED", "Could not launch Margin: \(error.localizedDescription)", exit: .io)
        }
        guard process.terminationStatus == 0 else {
            throw CLIError("APP_LAUNCH_FAILED", "The macOS open service could not launch Margin.", exit: .io)
        }
#else
        _ = items
        _ = wait
        _ = appOverride
        throw CLIError(
            "APP_UNAVAILABLE",
            "Margin's graphical application is available on macOS. This Linux build provides the complete collaboration CLI.",
            exit: .unavailable
        )
#endif
    }

    /// Writes the comparison request without exposing its snapshots, labels, or
    /// review destination in process arguments. Margin.app owns claiming and
    /// removing the file after it has decoded the bounded request successfully.
    static func openComparisonRequest(
        _ encodedRequest: Data,
        wait: Bool = false,
        appOverride: String? = nil,
        opening: ([URL], Bool, String?) throws -> Void = { items, wait, appOverride in
            try open(items, wait: wait, appOverride: appOverride)
        }
    ) throws {
        let requestURL = try writePrivateComparisonRequest(encodedRequest)
        do {
            try opening([requestURL], wait, appOverride)
        } catch {
            try? FileManager.default.removeItem(at: requestURL)
            throw error
        }
    }

    static func writePrivateComparisonRequest(
        _ encodedRequest: Data,
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard encodedRequest.count <= maximumComparisonRequestBytes else {
            throw CLIError(
                "COMPARISON_REQUEST_TOO_LARGE",
                "The comparison launch request exceeds the \(maximumComparisonRequestBytes)-byte limit.",
                exit: .data
            )
        }

        let requestURL = directory
            .appendingPathComponent("margin-\(UUID().uuidString.lowercased())")
            .appendingPathExtension(comparisonRequestExtension)
        let descriptor = requestURL.path.withCString { path in
#if canImport(Darwin)
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
#elseif canImport(Glibc)
            Glibc.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
#else
            -1
#endif
        }
        guard descriptor >= 0 else {
            throw CLIError(
                "COMPARISON_REQUEST_CREATE_FAILED",
                "Could not create a private comparison launch request.",
                exit: .cannotCreate
            )
        }

        var shouldRemove = true
        defer {
            if shouldRemove {
                try? FileManager.default.removeItem(at: requestURL)
            }
        }

        var descriptorIsOpen = true
        do {
#if canImport(Darwin)
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(.EPERM)
            }
#elseif canImport(Glibc)
            guard Glibc.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(.EPERM)
            }
#endif
            try encodedRequest.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let base = buffer.baseAddress!.advanced(by: offset)
#if canImport(Darwin)
                    let count = Darwin.write(descriptor, base, buffer.count - offset)
#elseif canImport(Glibc)
                    let count = Glibc.write(descriptor, base, buffer.count - offset)
#else
                    let count = -1
#endif
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    offset += count
                }
            }
#if canImport(Darwin)
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXError(.EIO)
            }
            let closeResult = Darwin.close(descriptor)
#elseif canImport(Glibc)
            guard Glibc.fsync(descriptor) == 0 else {
                throw POSIXError(.EIO)
            }
            let closeResult = Glibc.close(descriptor)
#endif
            descriptorIsOpen = false
            guard closeResult == 0 else { throw POSIXError(.EIO) }
            shouldRemove = false
            return requestURL
        } catch {
            if descriptorIsOpen {
#if canImport(Darwin)
                _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
                _ = Glibc.close(descriptor)
#endif
            }
            throw CLIError(
                "COMPARISON_REQUEST_WRITE_FAILED",
                "Could not write the private comparison launch request.",
                exit: .io
            )
        }
    }

    static func launchArguments(app: URL, items: [URL], wait: Bool) -> [String] {
        var arguments: [String] = []
        if wait {
            arguments.append(contentsOf: ["-W", "-n"])
        }
        arguments.append(contentsOf: ["-a", app.path])
        arguments.append(contentsOf: items.map(\.path))
        return arguments
    }

    static func locateApp(override: String?) throws -> URL {
        if let override {
            return try validatedApp(at: PathResolver.resolved(override), source: "--app")
        }
        if let environmentPath = ProcessInfo.processInfo.environment["MARGIN_APP_PATH"], !environmentPath.isEmpty {
            return try validatedApp(at: PathResolver.resolved(environmentPath), source: "MARGIN_APP_PATH")
        }

        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.standardizedFileURL {
            let binDirectory = executable.deletingLastPathComponent()
            candidates.append(binDirectory.appendingPathComponent("Margin.app"))

            // A CLI copied into Margin.app/Contents/Helpers can always find its host.
            if binDirectory.lastPathComponent == "Helpers" {
                candidates.append(binDirectory.deletingLastPathComponent().deletingLastPathComponent())
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Applications/Margin.app"))
        candidates.append(URL(fileURLWithPath: "/Applications/Margin.app"))

        for candidate in candidates {
            let executable = candidate.appendingPathComponent("Contents/MacOS/Margin")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return candidate
            }
        }
        throw CLIError(
            "APP_NOT_INSTALLED",
            "Margin.app was not found. Run 'make install' from the Margin source directory or set MARGIN_APP_PATH.",
            exit: .configuration
        )
    }

    private static func validatedApp(at candidate: URL, source: String) throws -> URL {
        let executable = candidate.appendingPathComponent("Contents/MacOS/Margin")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CLIError(
                "APP_NOT_FOUND",
                "The Margin app specified by \(source) is not executable at \(candidate.path).",
                exit: .configuration
            )
        }
        return candidate
    }
}
