import Foundation
import MarginCore

enum CLIExit: Int32 {
    case success = 0
    case usage = 64
    case data = 65
    case notFound = 66
    case unavailable = 69
    case cannotCreate = 73
    case io = 74
    case temporaryFailure = 75
    case permission = 77
    case configuration = 78
    case software = 70
}

struct CLIError: Error, LocalizedError {
    let code: String
    let message: String
    let exit: CLIExit
    let details: [String: String]?

    init(_ code: String, _ message: String, exit: CLIExit, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.exit = exit
        self.details = details
    }

    var errorDescription: String? { message }

    static func usage(_ message: String) -> CLIError {
        CLIError("USAGE", message, exit: .usage)
    }

    static func notFound(_ message: String) -> CLIError {
        CLIError("NOT_FOUND", message, exit: .notFound)
    }
}

struct CLIErrorPayload: Encodable {
    struct Detail: Encodable {
        let code: String
        let message: String
        let details: [String: String]?
    }

    let schema = "urn:margin:cli:v1"
    let ok = false
    let error: Detail

    init(_ error: CLIError) {
        self.error = Detail(code: error.code, message: error.message, details: error.details)
    }
}

enum CLIOutput {
    static func json<T: Encodable>(
        _ value: T,
        pretty: Bool = false,
        maximumBytes: Int? = nil,
        to handle: FileHandle = .standardOutput
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        data.append(0x0A)
        if let maximumBytes, data.count > maximumBytes {
            throw CLIError(
                "STATIC_OUTPUT_TOO_LARGE",
                "Static output exceeded its declared bound of \(maximumBytes) bytes.",
                exit: .software
            )
        }
        try handle.write(contentsOf: data)
    }

    static func text(_ value: String, to handle: FileHandle = .standardOutput) throws {
        var data = Data(value.utf8)
        if !value.hasSuffix("\n") { data.append(0x0A) }
        try handle.write(contentsOf: data)
    }

    static func error(_ cliError: CLIError, asJSON: Bool) {
        do {
            if asJSON {
                try json(CLIErrorPayload(cliError), to: .standardError)
            } else {
                try text("margin: \(cliError.message)", to: .standardError)
            }
        } catch {
            FileHandle.standardError.write(Data("margin: \(cliError.message)\n".utf8))
        }
    }
}

struct ArgumentCursor {
    private(set) var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    var isEmpty: Bool { values.isEmpty }
    var first: String? { values.first }

    mutating func pop() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }

    mutating func require(_ name: String) throws -> String {
        guard let value = pop(), !value.isEmpty else {
            throw CLIError.usage("Missing \(name).")
        }
        return value
    }

    mutating func takeFlag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func takeFlag(_ names: [String]) -> Bool {
        guard let index = values.firstIndex(where: names.contains) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func takeValue(_ name: String) throws -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        let valueIndex = values.index(after: index)
        guard valueIndex < values.endIndex else {
            throw CLIError.usage("Option \(name) requires a value.")
        }
        let value = values[valueIndex]
        values.removeSubrange(index...valueIndex)
        return value
    }

    mutating func takeValues(_ name: String) throws -> [String] {
        var result: [String] = []
        while let value = try takeValue(name) { result.append(value) }
        return result
    }

    mutating func takeInt(_ name: String) throws -> Int? {
        guard let raw = try takeValue(name) else { return nil }
        guard let value = Int(raw) else {
            throw CLIError.usage("Option \(name) expects an integer, received '\(raw)'.")
        }
        return value
    }

    mutating func takeRemaining() -> [String] {
        defer { values.removeAll() }
        return values
    }

    func rejectRemaining() throws {
        guard let first = values.first else { return }
        throw CLIError.usage("Unexpected argument '\(first)'.")
    }
}

enum PathResolver {
    static func existingFile(_ rawPath: String) throws -> URL {
        let url = resolved(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError.notFound("No file exists at \(url.path).")
        }
        return url
    }

    static func existingItem(_ rawPath: String) throws -> URL {
        let url = resolved(rawPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("No file or directory exists at \(url.path).")
        }
        return url
    }

    static func openableItem(_ rawPath: String) throws -> URL {
        let url = resolved(rawPath)
        do {
            return try OpenTargetPreparer.prepare(at: url).url
        } catch OpenTargetPreparationError.parentNotFound(let parent) {
            throw CLIError.notFound("The parent directory does not exist: \(parent).")
        } catch OpenTargetPreparationError.parentNotDirectory(let parent) {
            throw CLIError(
                "PARENT_NOT_DIRECTORY",
                "The parent path is not a directory: \(parent).",
                exit: .cannotCreate
            )
        } catch OpenTargetPreparationError.cannotCreate(let path, let reason) {
            throw CLIError(
                "CANNOT_CREATE",
                "Could not create \(path): \(reason).",
                exit: .cannotCreate
            )
        }
    }

    static func resolved(_ rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        }
        return url.standardizedFileURL
    }
}
