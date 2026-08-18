import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CollaborationDiscoveryLimits: Codable, Hashable, Sendable {
    public static let `default` = CollaborationDiscoveryLimits()

    public let maxFiles: Int
    public let maxBytes: Int
    public let maxDepth: Int

    public init(maxFiles: Int = 128, maxBytes: Int = 16 * 1_024 * 1_024, maxDepth: Int = 32) {
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
    }

    public func validate() throws {
        guard (1...16_384).contains(maxFiles),
              (1...1_073_741_824).contains(maxBytes),
              (0...256).contains(maxDepth) else {
            throw CollaborationError.invalidRoot("Discovery limits are outside their supported bounds.")
        }
    }
}

public struct CollaborationDiscoveryResult: Codable, Hashable, Sendable {
    public let paths: [String]
    public let bytes: Int
    public let omittedFileCount: Int
    public let hitFileLimit: Bool
    public let hitByteLimit: Bool
    public let hitDepthLimit: Bool

    public var isTruncated: Bool {
        omittedFileCount > 0 || hitFileLimit || hitByteLimit || hitDepthLimit
    }
}

/// Resolves collaboration roots only when a collaboration operation is explicitly
/// requested. Merely opening a document in the editor does not construct this type.
public struct CollaborationRootResolver: Sendable {
    public init() {}

    public func resolve(
        target: URL,
        explicitRoot: URL? = nil,
        discoverWorkspace: Bool = true
    ) throws -> CollaborationRoot {
        let target = try CollaborationPathResolver.canonicalExistingURL(target)
        let targetKind = try CollaborationPathResolver.kind(of: target)
        guard targetKind == .regularFile || targetKind == .directory else {
            throw CollaborationError.invalidRoot("The target must be a regular file or directory.")
        }

        if let explicitRoot {
            let boundary = try CollaborationPathResolver.canonicalExistingURL(explicitRoot)
            guard try CollaborationPathResolver.kind(of: boundary) == .directory else {
                throw CollaborationError.invalidRoot("An explicit root must be a directory.")
            }
            guard CollaborationPathResolver.contains(boundary, target) else {
                throw CollaborationError.pathEscapesRoot(target.path)
            }
            return try directoryRoot(at: boundary)
        }

        if targetKind == .directory {
            return try directoryRoot(at: target)
        }

        if discoverWorkspace, let workspace = try nearestWorkspace(containing: target) {
            return try directoryRoot(at: workspace)
        }
        let identity = Self.transientIdentity(kind: .document, path: target.path)
        return try CollaborationRoot(id: identity, kind: .document, path: target.path)
    }

    public func document(at url: URL) throws -> CollaborationRoot {
        let canonical = try CollaborationPathResolver.canonicalExistingURL(url)
        guard try CollaborationPathResolver.kind(of: canonical) == .regularFile else {
            throw CollaborationError.invalidRoot("A document root must be a regular file.")
        }
        return try CollaborationRoot(
            id: Self.transientIdentity(kind: .document, path: canonical.path),
            kind: .document,
            path: canonical.path
        )
    }

    public func directory(at url: URL) throws -> CollaborationRoot {
        let canonical = try CollaborationPathResolver.canonicalExistingURL(url)
        guard try CollaborationPathResolver.kind(of: canonical) == .directory else {
            throw CollaborationError.invalidRoot("A directory root must be a directory.")
        }
        return try directoryRoot(at: canonical)
    }

    public func manifest(for root: CollaborationRoot) throws -> CollaborationWorkspaceManifest? {
        try root.validate()
        guard root.kind == .directory else { return nil }
        let manifestURL = URL(fileURLWithPath: root.path, isDirectory: true)
            .appendingPathComponent(".margin/workspace.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let resolved = try CollaborationPathResolver.resolve(
            root: root,
            relativePath: ".margin/workspace.json",
            allowMissingFinal: false,
            allowHiddenMetadata: true
        )
        let data = try CollaborationPathResolver.readBounded(resolved, maximumBytes: 1_048_576)
        let manifest = try CollaborationCanonicalJSON.decode(CollaborationWorkspaceManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    private func directoryRoot(at directory: URL) throws -> CollaborationRoot {
        let transientID = Self.transientIdentity(kind: .directory, path: directory.path)
        let provisional = try CollaborationRoot(
            id: transientID,
            kind: .directory,
            path: directory.path
        )
        guard let manifest = try manifest(for: provisional) else { return provisional }
        return try CollaborationRoot(
            id: manifest.id,
            kind: .directory,
            path: directory.path,
            workspaceID: manifest.id
        )
    }

    private func nearestWorkspace(containing file: URL) throws -> URL? {
        var directory = file.deletingLastPathComponent()
        var device = try CollaborationPathResolver.device(of: directory)
        while true {
            let manifest = directory
                .appendingPathComponent(".margin", isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: manifest.path) {
                let root = try directoryRoot(at: directory)
                if root.workspaceID != nil { return directory }
            }
            if directory.path == "/" { return nil }
            let parentPath = (directory.path as NSString).deletingLastPathComponent
            let normalizedParent = parentPath.isEmpty ? "/" : parentPath
            let parent = URL(fileURLWithPath: normalizedParent, isDirectory: true).standardizedFileURL
            guard parent.path.count < directory.path.count else { return nil }
            let parentDevice = try CollaborationPathResolver.device(of: parent)
            if parentDevice != device { return nil }
            device = parentDevice
            directory = parent
        }
    }

    private static func transientIdentity(kind: CollaborationRootKind, path: String) -> String {
        let digest = CollaborationCanonicalJSON.sha256(of: Data("\(kind.rawValue)\0\(path)".utf8))
        return "urn:margin:root:sha256:\(digest)"
    }
}

public struct CollaborationCursorService: Sendable {
    private let codec: EmbeddedCommentCodec
    private let rootResolver: CollaborationRootResolver

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        rootResolver: CollaborationRootResolver = CollaborationRootResolver()
    ) {
        self.codec = codec
        self.rootResolver = rootResolver
    }

    public func capture(
        root: CollaborationRoot,
        paths requestedPaths: [String]? = nil,
        limits: CollaborationDiscoveryLimits = .default
    ) throws -> CollaborationCursor {
        let discovery = try discover(root: root, paths: requestedPaths, limits: limits)
        guard !discovery.paths.isEmpty else {
            throw CollaborationError.invalidCursor("No Markdown documents were selected by the bounded discovery.")
        }
        let files = try discovery.paths.map { try fileCursor(root: root, path: $0) }
        return try CollaborationCursor(root: root, files: files)
    }

    public func verify(_ cursor: CollaborationCursor) throws {
        try cursor.validate()
        let live = try capture(
            root: cursor.root,
            paths: cursor.files.map(\.path),
            limits: CollaborationDiscoveryLimits(
                maxFiles: max(1, cursor.files.count),
                maxBytes: 1_073_741_824,
                maxDepth: 256
            )
        )
        guard live == cursor else {
            let mismatch = zip(cursor.files, live.files).first { $0 != $1 }
            throw CollaborationError.preconditionFailed(
                path: mismatch?.0.path ?? cursor.root.path,
                reason: "The complete collaboration cursor no longer matches disk state."
            )
        }
    }

    public func fileCursor(root: CollaborationRoot, path: String) throws -> CollaborationFileCursor {
        try root.validate()
        let url = try CollaborationPathResolver.resolve(
            root: root,
            relativePath: path,
            allowMissingFinal: false
        )
        guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
            throw CollaborationError.invalidPath(path)
        }
        let data = try CollaborationPathResolver.readBounded(url, maximumBytes: 128 * 1_024 * 1_024)
        let decoded: EmbeddedCommentDocument
        do {
            decoded = try codec.decode(data)
        } catch {
            throw CollaborationError.invalidCursor("Could not inspect '\(path)': \(error.localizedDescription)")
        }
        let annotations = decoded.envelope?.items ?? []
        return try CollaborationFileCursor(
            path: path,
            documentID: decoded.envelope?.document.id,
            contentSha256: DocumentRevision(data: decoded.bodyData).sha256,
            annotationRevision: decoded.envelope?.revision ?? 0,
            annotationSha256: try CollaborationCanonicalJSON.sha256(of: annotations),
            wholeFileSha256: CollaborationCanonicalJSON.sha256(of: data)
        )
    }

    public func discover(
        root: CollaborationRoot,
        paths requestedPaths: [String]? = nil,
        limits: CollaborationDiscoveryLimits = .default
    ) throws -> CollaborationDiscoveryResult {
        try root.validate()
        try limits.validate()
        if root.kind == .document {
            if let requestedPaths, requestedPaths != ["."] {
                throw CollaborationError.invalidPath(requestedPaths.joined(separator: ","))
            }
            let url = try CollaborationPathResolver.resolve(
                root: root,
                relativePath: ".",
                allowMissingFinal: false
            )
            let size = try CollaborationPathResolver.size(of: url)
            guard size <= limits.maxBytes else {
                return CollaborationDiscoveryResult(
                    paths: [], bytes: 0, omittedFileCount: 1,
                    hitFileLimit: false, hitByteLimit: true, hitDepthLimit: false
                )
            }
            return CollaborationDiscoveryResult(
                paths: ["."], bytes: size, omittedFileCount: 0,
                hitFileLimit: false, hitByteLimit: false, hitDepthLimit: false
            )
        }

        if let requestedPaths {
            let paths = CollaborationValidation.sortedUnique(requestedPaths)
            guard paths.count == requestedPaths.count else {
                throw CollaborationError.invalidCursor("Requested paths must be unique.")
            }
            var accepted: [String] = []
            var bytes = 0
            var omitted = 0
            var byteLimit = false
            for path in paths {
                try CollaborationValidation.relativePath(path, allowingRootDocument: false)
                let depth = path.split(separator: "/").count - 1
                guard depth <= limits.maxDepth else {
                    omitted += 1
                    continue
                }
                let url = try CollaborationPathResolver.resolve(
                    root: root,
                    relativePath: path,
                    allowMissingFinal: false
                )
                guard try CollaborationPathResolver.kind(of: url) == .regularFile else {
                    throw CollaborationError.invalidPath(path)
                }
                let size = try CollaborationPathResolver.size(of: url)
                guard accepted.count < limits.maxFiles else { omitted += 1; continue }
                guard bytes <= limits.maxBytes - size else {
                    byteLimit = true
                    omitted += 1
                    continue
                }
                accepted.append(path)
                bytes += size
            }
            return CollaborationDiscoveryResult(
                paths: accepted, bytes: bytes, omittedFileCount: omitted,
                hitFileLimit: accepted.count == limits.maxFiles && omitted > 0,
                hitByteLimit: byteLimit,
                hitDepthLimit: requestedPaths.contains { $0.split(separator: "/").count - 1 > limits.maxDepth }
            )
        }

        let manifest = try rootResolver.manifest(for: root)
        return try discoverDirectory(root: root, manifest: manifest, limits: limits)
    }

    private func discoverDirectory(
        root: CollaborationRoot,
        manifest: CollaborationWorkspaceManifest?,
        limits: CollaborationDiscoveryLimits
    ) throws -> CollaborationDiscoveryResult {
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        ]
        let heavyDirectories: Set<String> = [
            ".build", ".git", ".hg", ".svn", ".swiftpm", "DerivedData", "node_modules", "vendor",
        ]
        var paths: [String] = []
        var bytes = 0
        var hitDepth = false
        var hitBytes = false
        var hitFiles = false
        var omitted = 0
        var stopped = false

        func visit(_ directory: URL, relativeDirectory: String, depth: Int) throws {
            guard !stopped else { return }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ).sorted {
                    CollaborationValidation.pathLess($0.lastPathComponent, $1.lastPathComponent)
                }
            } catch {
                throw CollaborationError.io("Could not enumerate '\(directory.path)': \(error.localizedDescription)")
            }
            for url in children {
                guard !stopped else { break }
                let name = url.lastPathComponent
                let relative = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    guard values.isPackage != true, !heavyDirectories.contains(name) else { continue }
                    if depth >= limits.maxDepth {
                        hitDepth = true
                    } else {
                        try visit(url, relativeDirectory: relative, depth: depth + 1)
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      Self.isMarkdown(relative),
                      Self.matchesManifest(relative, manifest: manifest) else { continue }
                guard paths.count < limits.maxFiles else {
                    hitFiles = true
                    omitted += 1
                    stopped = true
                    break
                }
                let size = max(0, values.fileSize ?? 0)
                guard bytes <= limits.maxBytes - size else {
                    hitBytes = true
                    omitted += 1
                    stopped = true
                    break
                }
                paths.append(relative)
                bytes += size
            }
        }
        try visit(rootURL, relativeDirectory: "", depth: 0)
        return CollaborationDiscoveryResult(
            paths: paths,
            bytes: bytes,
            omittedFileCount: omitted,
            hitFileLimit: hitFiles,
            hitByteLimit: hitBytes,
            hitDepthLimit: hitDepth
        )
    }

    private static func isMarkdown(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private static func matchesManifest(
        _ path: String,
        manifest: CollaborationWorkspaceManifest?
    ) -> Bool {
        guard let manifest else { return true }
        let included = manifest.include.contains { CollaborationGlob.matches(path, pattern: $0) }
        let excluded = manifest.exclude.contains { CollaborationGlob.matches(path, pattern: $0) }
        return included && !excluded
    }
}

enum CollaborationFileKind {
    case regularFile
    case directory
    case symbolicLink
    case other
}

enum CollaborationPathResolver {
    static func canonicalExistingURL(_ url: URL) throws -> URL {
        let absolute = url.standardizedFileURL.resolvingSymlinksInPath()
        guard absolute.path.hasPrefix("/"), FileManager.default.fileExists(atPath: absolute.path) else {
            throw CollaborationError.invalidRoot("'\(url.path)' does not exist.")
        }
        return absolute
    }

    static func resolve(
        root: CollaborationRoot,
        relativePath: String,
        allowMissingFinal: Bool,
        allowHiddenMetadata: Bool = false
    ) throws -> URL {
        try root.validate()
        try CollaborationValidation.relativePath(relativePath, allowingRootDocument: true)
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: root.kind == .directory).standardizedFileURL
        if root.kind == .document {
            guard relativePath == "." else { throw CollaborationError.pathEscapesRoot(relativePath) }
            do {
                guard try kind(of: rootURL) == .regularFile else {
                    throw CollaborationError.invalidRoot("The document root is no longer a regular file.")
                }
            } catch let error as CollaborationError {
                if allowMissingFinal, case .io(let message) = error, message.hasPrefix("ENOENT:") {
                    return rootURL
                }
                throw error
            }
            return rootURL
        }
        guard relativePath != "." else { throw CollaborationError.invalidPath(relativePath) }
        _ = allowHiddenMetadata // Hidden files are valid explicit targets; discovery alone skips them.
        guard try kind(of: rootURL) == .directory else {
            throw CollaborationError.invalidRoot("The directory root is no longer a directory.")
        }

        // The relative path validator already rejects dot and traversal
        // components. Keep this append lexical: some Foundation builds resolve
        // the final symlink during URL standardization, which would turn a
        // precise symlink rejection into a generic root-escape result.
        let target = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        guard contains(rootURL, target), target.path != rootURL.path else {
            throw CollaborationError.pathEscapesRoot(relativePath)
        }
        let components = relativePath.split(separator: "/").map(String.init)
        var current = rootURL
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: false)
            do {
                let itemKind = try kind(of: current)
                if itemKind == .symbolicLink {
                    throw CollaborationError.symlinkNotAllowed(relativePath)
                }
                if index < components.count - 1, itemKind != .directory {
                    throw CollaborationError.invalidPath(relativePath)
                }
            } catch let error as CollaborationError {
                if case .io(let message) = error,
                   message.hasPrefix("ENOENT:"), index == components.count - 1, allowMissingFinal {
                    return target
                }
                throw error
            }
        }
        return target
    }

    static func contains(_ root: URL, _ target: URL) -> Bool {
        var rootPath = root.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        let targetPath = target.path
        if rootPath == "/" { return targetPath.hasPrefix("/") }
        return targetPath.hasPrefix(rootPath + "/")
    }

    static func kind(of url: URL) throws -> CollaborationFileKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT {
                throw CollaborationError.io("ENOENT: '\(url.path)' does not exist.")
            }
            throw CollaborationError.io("Could not inspect '\(url.path)': \(String(cString: strerror(code))).")
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    static func device(of url: URL) throws -> dev_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CollaborationError.io("Could not inspect filesystem boundary for '\(url.path)'.")
        }
        return info.st_dev
    }

    static func size(of url: URL) throws -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size >= 0, info.st_size <= Int.max else {
            throw CollaborationError.io("Could not determine the size of '\(url.path)'.")
        }
        return Int(info.st_size)
    }

    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        let byteCount = try size(of: url)
        guard byteCount <= maximumBytes else {
            throw CollaborationError.io("'\(url.path)' exceeds the \(maximumBytes)-byte collaboration limit.")
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw CollaborationError.io("Could not read '\(url.path)': \(error.localizedDescription)")
        }
    }
}

private enum CollaborationGlob {
    static func matches(_ path: String, pattern: String) -> Bool {
        match(path.split(separator: "/", omittingEmptySubsequences: false).map(String.init),
              pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    private static func match(_ path: [String], _ pattern: [String]) -> Bool {
        struct Key: Hashable { let path: Int; let pattern: Int }
        var memo: [Key: Bool] = [:]
        func visit(_ pathIndex: Int, _ patternIndex: Int) -> Bool {
            let key = Key(path: pathIndex, pattern: patternIndex)
            if let cached = memo[key] { return cached }
            let result: Bool
            if patternIndex == pattern.count {
                result = pathIndex == path.count
            } else if pattern[patternIndex] == "**" {
                result = visit(pathIndex, patternIndex + 1)
                    || (pathIndex < path.count && visit(pathIndex + 1, patternIndex))
            } else if pathIndex < path.count,
                      component(path[pathIndex], matches: pattern[patternIndex]) {
                result = visit(pathIndex + 1, patternIndex + 1)
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return visit(0, 0)
    }

    private static func component(_ value: String, matches pattern: String) -> Bool {
        let value = Array(value)
        let pattern = Array(pattern)
        struct Key: Hashable { let value: Int; let pattern: Int }
        var memo: [Key: Bool] = [:]
        func visit(_ valueIndex: Int, _ patternIndex: Int) -> Bool {
            let key = Key(value: valueIndex, pattern: patternIndex)
            if let cached = memo[key] { return cached }
            let result: Bool
            if patternIndex == pattern.count {
                result = valueIndex == value.count
            } else if pattern[patternIndex] == "*" {
                result = visit(valueIndex, patternIndex + 1)
                    || (valueIndex < value.count && visit(valueIndex + 1, patternIndex))
            } else if valueIndex < value.count,
                      pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex] {
                result = visit(valueIndex + 1, patternIndex + 1)
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return visit(0, 0)
    }
}
