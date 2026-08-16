import Foundation

/// A deliberately tiny, path-only recent list. Reads happen only when the
/// command palette opens; writes are scheduled after a workspace is visible.
final class RecentWorkspaceStore {
    private static let persistenceQueue = DispatchQueue(
        label: "ink.margin.recent-workspaces",
        qos: .utility
    )

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "MarginRecentWorkspaces.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func urls(limit: Int = 10) -> [URL] {
        Array(
            (defaults.stringArray(forKey: key) ?? [])
                .prefix(max(0, limit))
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
        )
    }

    func record(_ url: URL, limit: Int = 12) {
        let path = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(max(1, limit))), forKey: key)
    }

    static func recordAfterLaunch(_ url: URL) {
        persistenceQueue.async {
            RecentWorkspaceStore().record(url)
        }
    }
}
