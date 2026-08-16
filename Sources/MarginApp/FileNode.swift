import Foundation

final class FileNode: NSObject {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]

    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool

    private(set) var children: [FileNode]?
    private var isLoadingChildren = false
    private var loadGeneration = 0
    private var pendingCompletions: [(Result<[FileNode], Error>) -> Void] = []

    var isExpandableDirectory: Bool {
        isDirectory && !isPackage && !isSymbolicLink
    }

    var isMarkdown: Bool {
        !isDirectory && Self.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    init(url: URL, prefetchedValues: URLResourceValues? = nil) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
        ]
        let values = prefetchedValues ?? (try? url.resourceValues(forKeys: keys))
        var fallbackDirectory = ObjCBool(false)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &fallbackDirectory)

        self.isDirectory = values?.isDirectory ?? fallbackDirectory.boolValue
        self.isPackage = values?.isPackage ?? false
        self.isSymbolicLink = values?.isSymbolicLink ?? false
        self.isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        super.init()
    }

    func loadChildren(
        force: Bool = false,
        completion: @escaping (Result<[FileNode], Error>) -> Void
    ) {
        precondition(Thread.isMainThread)

        if !force, let children {
            completion(.success(children))
            return
        }

        pendingCompletions.append(completion)
        guard !isLoadingChildren else { return }

        isLoadingChildren = true
        loadGeneration += 1
        let generation = loadGeneration
        let directoryURL = url

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.children(in: directoryURL) }
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.isLoadingChildren = false
                if case let .success(children) = result {
                    self.children = children
                }
                let completions = self.pendingCompletions
                self.pendingCompletions.removeAll()
                completions.forEach { $0(result) }
            }
        }
    }

    func discardChildren() {
        precondition(Thread.isMainThread)
        children = nil
        loadGeneration += 1
        isLoadingChildren = false
        pendingCompletions.removeAll()
    }

    static func children(in directoryURL: URL) throws -> [FileNode] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return FileNode(url: url, prefetchedValues: values)
            }
            .filter { !$0.isHidden && !$0.name.hasPrefix(".") }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func firstMarkdownFile(
        beneath rootURL: URL,
        maximumVisitedEntries: Int = 50_000
    ) -> URL? {
        let excludedDirectories: Set<String> = [
            ".build", ".git", ".hg", ".svn", ".swiftpm", "DerivedData", "node_modules",
        ]
        var queue: [URL] = [rootURL]
        var cursor = 0
        var visitedEntries = 0

        while cursor < queue.count, visitedEntries < maximumVisitedEntries {
            let directory = queue[cursor]
            cursor += 1

            guard let nodes = try? children(in: directory) else { continue }
            visitedEntries += nodes.count

            if directory == rootURL,
               let readme = nodes.first(where: { $0.isMarkdown && $0.name.lowercased() == "readme.md" }) {
                return readme.url
            }

            if let markdown = nodes.first(where: \.isMarkdown) {
                return markdown.url
            }

            for node in nodes where node.isExpandableDirectory {
                guard !node.isHidden, !excludedDirectories.contains(node.name) else { continue }
                queue.append(node.url)
            }
        }

        return nil
    }
}
