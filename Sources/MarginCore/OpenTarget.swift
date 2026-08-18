#if os(Linux)
@preconcurrency import Foundation
#else
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct PreparedOpenTarget: Equatable, Sendable {
    public let url: URL
    public let wasCreated: Bool

    public init(url: URL, wasCreated: Bool) {
        self.url = url
        self.wasCreated = wasCreated
    }
}

public enum OpenTargetPreparationError: Error, LocalizedError, Equatable, Sendable {
    case parentNotFound(String)
    case parentNotDirectory(String)
    case cannotCreate(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .parentNotFound(let path):
            return "The parent directory does not exist: \(path)."
        case .parentNotDirectory(let path):
            return "The parent path is not a directory: \(path)."
        case .cannotCreate(let path, let reason):
            return "Could not create '\(path)': \(reason)."
        }
    }
}

/// Prepares a command-line open target without modifying existing items.
///
/// macOS's `open` command refuses to deliver a URL for a path that does not yet
/// exist. Margin therefore creates an empty file first, matching the familiar
/// `editor new-file.md` workflow. The exclusive create keeps simultaneous
/// launchers from truncating one another's work.
public enum OpenTargetPreparer {
    public static func prepare(at inputURL: URL) throws -> PreparedOpenTarget {
        let url = inputURL.standardizedFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) {
            return PreparedOpenTarget(url: url, wasCreated: false)
        }

        let parent = url.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
            throw OpenTargetPreparationError.parentNotFound(parent.path)
        }
        guard parentIsDirectory.boolValue else {
            throw OpenTargetPreparationError.parentNotDirectory(parent.path)
        }

        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        if descriptor >= 0 {
            guard close(descriptor) == 0 else {
                let reason = String(cString: strerror(errno))
                throw OpenTargetPreparationError.cannotCreate(path: url.path, reason: reason)
            }
            return PreparedOpenTarget(url: url, wasCreated: true)
        }

        let creationError = errno
        if creationError == EEXIST, fileManager.fileExists(atPath: url.path) {
            return PreparedOpenTarget(url: url, wasCreated: false)
        }
        if creationError == ENOENT {
            throw OpenTargetPreparationError.parentNotFound(parent.path)
        }
        if creationError == ENOTDIR {
            throw OpenTargetPreparationError.parentNotDirectory(parent.path)
        }
        throw OpenTargetPreparationError.cannotCreate(
            path: url.path,
            reason: String(cString: strerror(creationError))
        )
    }
}
