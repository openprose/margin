import Foundation

enum AppLauncher {
    static func open(_ item: URL?, wait: Bool, appOverride: String?) throws {
        let app = try locateApp(override: appOverride)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments: [String] = []
        if wait {
            arguments.append(contentsOf: ["-W", "-n"])
        }
        arguments.append(contentsOf: ["-a", app.path])
        if let item { arguments.append(item.path) }
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError("APP_LAUNCH_FAILED", "Could not launch Margin: \(error.localizedDescription)", exit: .io)
        }
        guard process.terminationStatus == 0 else {
            throw CLIError("APP_LAUNCH_FAILED", "The macOS open service could not launch Margin.", exit: .io)
        }
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
