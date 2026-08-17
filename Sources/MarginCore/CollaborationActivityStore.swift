import Darwin
import Foundation

public enum CollaborationActivityWriteDisposition: String, Codable, Sendable {
    case created
    case alreadyPresent = "already-present"
}

public struct CollaborationActivityListing: Codable, Hashable, Sendable {
    public let records: [CollaborationActivityRecord]
    public let omittedCount: Int

    public var isTruncated: Bool { omittedCount > 0 }
}

/// A bounded immutable store of durable collaboration facts. It is consulted only
/// by explicit collaboration context/recovery operations and never during launch.
public struct CollaborationActivityStore: Sendable {
    public static let maximumCanonicalBytes = 4 * 1_024 * 1_024
    public static let maximumAggregateCanonicalBytes = 32 * 1_024 * 1_024
    public static let maximumSupportedRecords = 4_096

    public let maximumRecords: Int
    private let stateDirectory: URL?

    public init(stateDirectory: URL? = nil, maximumRecords: Int = 4_096) {
        self.stateDirectory = stateDirectory
        self.maximumRecords = max(1, min(maximumRecords, Self.maximumSupportedRecords))
    }

    @discardableResult
    public func record(
        _ activity: CollaborationActivityRecord,
        root: CollaborationRoot
    ) throws -> CollaborationActivityWriteDisposition {
        try root.validate()
        try activity.validate()
        guard activity.rootID == root.id else {
            throw CollaborationError.invalidActivity("The activity belongs to another collaboration root.")
        }
        let data = try CollaborationCanonicalJSON.encode(activity)
        let directory = try activityDirectory(root: root, create: true)
        let digest = CollaborationCanonicalJSON.sha256(of: Data(activity.id.utf8))
        let destination = directory.appendingPathComponent("\(digest).json", isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try verifyExisting(data, at: destination)
        }
        // A healthy store is pruned after every creation. Stop before writing if
        // externally supplied metadata already exceeds that invariant.
        _ = try recordURLs(in: directory, maximumCount: maximumRecords)
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw CollaborationError.io("Could not create activity record: \(String(cString: strerror(errno))).")
            }
            return try verifyExisting(data, at: destination)
        }
        var success = false
        defer {
            _ = close(descriptor)
            if !success { _ = unlink(destination.path) }
        }
        guard Self.write(data, descriptor: descriptor), fsync(descriptor) == 0 else {
            throw CollaborationError.io("Could not durably write activity '\(activity.id)'.")
        }
        success = true
        try Self.syncDirectory(directory)
        try prune(directory: directory)
        return .created
    }

    public func load(
        root: CollaborationRoot,
        limit: Int = 4_096
    ) throws -> [CollaborationActivityRecord] {
        try list(root: root, limit: limit).records
    }

    /// Reads at most `limit` canonical records. Directory traversal, retained
    /// paths, record decodes, and bytes are all bounded; hostile excess metadata
    /// fails before any transaction recovery or context mutation occurs.
    public func list(
        root: CollaborationRoot,
        limit: Int = 4_096
    ) throws -> CollaborationActivityListing {
        try root.validate()
        guard (0...Self.maximumSupportedRecords).contains(limit) else {
            throw CollaborationError.invalidActivity(
                "Activity limit must be between 0 and \(Self.maximumSupportedRecords)."
            )
        }
        let effectiveLimit = min(limit, maximumRecords)
        let directory = try activityDirectory(root: root, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return CollaborationActivityListing(records: [], omittedCount: 0)
        }
        let urls = try recordURLs(in: directory, maximumCount: maximumRecords)
        if effectiveLimit == 0 {
            return CollaborationActivityListing(records: [], omittedCount: urls.count)
        }
        var aggregateBytes = 0
        for url in urls {
            let size = try CollaborationPathResolver.size(of: url)
            guard size <= Self.maximumCanonicalBytes,
                  aggregateBytes <= Self.maximumAggregateCanonicalBytes - size else {
                throw CollaborationError.invalidActivity(
                    "Durable activity metadata exceeds its 32 MiB aggregate read budget."
                )
            }
            aggregateBytes += size
        }
        var records: [CollaborationActivityRecord] = []
        records.reserveCapacity(urls.count)
        for url in urls {
            guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
                throw CollaborationError.symlinkNotAllowed(url.path)
            }
            let data = try CollaborationPathResolver.readBounded(
                url,
                maximumBytes: Self.maximumCanonicalBytes
            )
            let record = try CollaborationCanonicalJSON.decode(CollaborationActivityRecord.self, from: data)
            try record.validate()
            guard record.rootID == root.id,
                  try CollaborationCanonicalJSON.encode(record) == data else {
                throw CollaborationError.invalidActivity("An activity record is noncanonical or belongs to another root.")
            }
            records.append(record)
        }
        let omittedCount = max(0, records.count - effectiveLimit)
        records.sort {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return CollaborationValidation.pathLess($0.id, $1.id)
        }
        return CollaborationActivityListing(
            records: Array(records.suffix(effectiveLimit)),
            omittedCount: omittedCount
        )
    }

    /// Loads one immutable activity by id without scanning or creating metadata.
    public func load(
        id: String,
        root: CollaborationRoot
    ) throws -> CollaborationActivityRecord? {
        try root.validate()
        try CollaborationValidation.identifier(id, field: "activity id")
        let directory = try activityDirectory(root: root, create: false)
        let digest = CollaborationCanonicalJSON.sha256(of: Data(id.utf8))
        let url = directory.appendingPathComponent("\(digest).json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
            throw CollaborationError.symlinkNotAllowed(url.path)
        }
        let data = try CollaborationPathResolver.readBounded(url, maximumBytes: Self.maximumCanonicalBytes)
        let record = try CollaborationCanonicalJSON.decode(CollaborationActivityRecord.self, from: data)
        try record.validate()
        guard record.id == id, record.rootID == root.id,
              try CollaborationCanonicalJSON.encode(record) == data else {
            throw CollaborationError.invalidActivity("An activity record is noncanonical or has the wrong identity.")
        }
        return record
    }

    private func activityDirectory(root: CollaborationRoot, create: Bool) throws -> URL {
        let directory: URL
        if root.isPersistentWorkspace {
            let margin = URL(fileURLWithPath: root.path, isDirectory: true)
                .appendingPathComponent(".margin", isDirectory: true)
            guard try CollaborationPathResolver.kind(of: margin) == .directory else {
                throw CollaborationError.symlinkNotAllowed(margin.path)
            }
            directory = margin.appendingPathComponent("activity", isDirectory: true)
        } else {
            let base = stateDirectory ?? CollaborationStateDirectories.defaultRoot()
            let digest = CollaborationCanonicalJSON.sha256(of: try CollaborationCanonicalJSON.encode(root))
            directory = base
                .appendingPathComponent("activity", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
        }
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard try CollaborationPathResolver.kind(of: directory) == .directory else {
                    throw CollaborationError.symlinkNotAllowed(directory.path)
                }
            } catch let error as CollaborationError { throw error }
            catch { throw CollaborationError.io("Could not create activity directory: \(error.localizedDescription)") }
        }
        return directory
    }

    private func prune(directory: URL) throws {
        let urls = try recordURLs(in: directory, maximumCount: maximumRecords + 1)
        guard urls.count > maximumRecords else { return }
        var values: [(URL, CollaborationActivityRecord)] = []
        values.reserveCapacity(urls.count)
        for url in urls {
            let data = try CollaborationPathResolver.readBounded(url, maximumBytes: Self.maximumCanonicalBytes)
            let record = try CollaborationCanonicalJSON.decode(CollaborationActivityRecord.self, from: data)
            values.append((url, record))
        }
        values.sort {
            if $0.1.occurredAt != $1.1.occurredAt { return $0.1.occurredAt < $1.1.occurredAt }
            return CollaborationValidation.pathLess($0.1.id, $1.1.id)
        }
        for (url, _) in values.prefix(values.count - maximumRecords) {
            try FileManager.default.removeItem(at: url)
        }
        try Self.syncDirectory(directory)
    }

    private func recordURLs(in directory: URL, maximumCount: Int) throws -> [URL] {
        let selection = try boundedRecordURLs(
            in: directory,
            limit: maximumCount,
            maximumCount: maximumCount
        )
        return selection.urls
    }

    private func boundedRecordURLs(
        in directory: URL,
        limit: Int,
        maximumCount: Int
    ) throws -> (urls: [URL], omittedCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw CollaborationError.invalidActivity("Could not enumerate durable activity metadata.")
        }
        var allURLs: [URL] = []
        var total = 0
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard total < maximumCount else {
                throw CollaborationError.invalidActivity(
                    "The activity directory exceeds its supported \(maximumCount)-record bound."
                )
            }
            total += 1
            allURLs.append(url)
        }
        allURLs.sort {
            CollaborationValidation.pathLess($0.lastPathComponent, $1.lastPathComponent)
        }
        let urls = Array(allURLs.prefix(limit))
        return (urls, max(0, total - urls.count))
    }

    private func verifyExisting(
        _ expected: Data,
        at destination: URL
    ) throws -> CollaborationActivityWriteDisposition {
        let existing = try CollaborationPathResolver.readBounded(
            destination,
            maximumBytes: Self.maximumCanonicalBytes
        )
        guard existing == expected else {
            throw CollaborationError.preconditionFailed(
                path: destination.path,
                reason: "The immutable activity id is already bound to different content."
            )
        }
        return .alreadyPresent
    }

    private static func write(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return data.isEmpty }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CollaborationError.io("Could not open activity directory for synchronization.")
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL else {
            throw CollaborationError.io("Could not synchronize activity directory.")
        }
    }
}
