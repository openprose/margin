import Foundation

struct ScratchpadDescriptor: Codable, Equatable {
    let id: UUID
    let title: String
}

enum ScratchpadStoreError: LocalizedError {
    case couldNotCreateStorage

    var errorDescription: String? {
        switch self {
        case .couldNotCreateStorage:
            return "Margin could not create its private scratchpad storage."
        }
    }
}

/// Gives untitled documents durable, file-backed storage without exposing an
/// implementation path as the document's identity in the UI. Scratchpads use
/// ordinary Markdown bytes so recovery never depends on a database or daemon.
final class ScratchpadStore {
    private let fileManager: FileManager
    private let rootURL: URL
    private let defaults: UserDefaults
    private let counterKey: String

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        defaults: UserDefaults = .standard,
        counterKey: String = "MarginScratchpadCounter.v1"
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.counterKey = counterKey
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
            self.rootURL = applicationSupport
                .appendingPathComponent("Margin", isDirectory: true)
                .appendingPathComponent("Scratchpads", isDirectory: true)
        }
    }

    func create() throws -> ScratchpadDescriptor {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = ScratchpadDescriptor(id: UUID(), title: nextTitle())
        let destination = url(for: descriptor.id)
        guard fileManager.createFile(
            atPath: destination.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ScratchpadStoreError.couldNotCreateStorage
        }
        return descriptor
    }

    func url(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("md")
    }

    func exists(_ descriptor: ScratchpadDescriptor) -> Bool {
        fileManager.fileExists(atPath: url(for: descriptor.id).path)
    }

    func remove(_ descriptor: ScratchpadDescriptor) throws {
        let target = url(for: descriptor.id)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    private func nextTitle() -> String {
        let previous = defaults.integer(forKey: counterKey)
        let next = previous == Int.max ? 1 : previous + 1
        defaults.set(next, forKey: counterKey)
        return "Untitled \(next)"
    }
}
