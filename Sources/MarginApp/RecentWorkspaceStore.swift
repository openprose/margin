import Foundation

struct RecentWorkspace: Equatable {
    let url: URL
    let lastOpened: Date?
}

/// A deliberately tiny, bounded recent list. Persistence work is kept on a
/// utility queue; callers decide when they are far enough past first display to
/// read it. Entries contain paths and timestamps only—never directory contents.
final class RecentWorkspaceStore {
    private struct PersistedWorkspace: Codable {
        let path: String
        let lastOpened: Date
    }

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

    func workspaces(limit: Int = 10) -> [RecentWorkspace] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }

        if let data = defaults.data(forKey: key),
           let persisted = try? PropertyListDecoder().decode([PersistedWorkspace].self, from: data) {
            return Array(
                Self.sortedByRecency(persisted)
                    .prefix(limit)
                    .map {
                        RecentWorkspace(
                            url: URL(fileURLWithPath: $0.path).standardizedFileURL,
                            lastOpened: $0.lastOpened
                        )
                    }
            )
        }

        // Margin 0.4 and earlier stored an ordered string array. Preserve those
        // paths without inventing dates; the next open upgrades each entry.
        return Array(
            (defaults.stringArray(forKey: key) ?? [])
                .prefix(limit)
                .map {
                    RecentWorkspace(
                        url: URL(fileURLWithPath: $0).standardizedFileURL,
                        lastOpened: nil
                    )
                }
        )
    }

    func urls(limit: Int = 10) -> [URL] {
        workspaces(limit: limit).map(\.url)
    }

    func record(_ url: URL, at date: Date = Date(), limit: Int = 12) {
        let standardizedURL = url.standardizedFileURL
        var entries = workspaces(limit: max(limit, 12)).map {
            PersistedWorkspace(
                path: $0.url.path,
                lastOpened: $0.lastOpened ?? .distantPast
            )
        }
        entries.removeAll { $0.path == standardizedURL.path }
        entries.insert(PersistedWorkspace(path: standardizedURL.path, lastOpened: date), at: 0)
        entries = Self.sortedByRecency(entries)

        guard let data = try? PropertyListEncoder().encode(
            Array(entries.prefix(max(1, limit)))
        ) else { return }
        defaults.set(data, forKey: key)
    }

    func recordAfterLaunch(_ url: URL, at date: Date = Date()) {
        Self.persistenceQueue.async { [self] in
            record(url, at: date)
        }
    }

    func loadAfterPendingWrites(
        limit: Int = 10,
        completion: @escaping ([RecentWorkspace]) -> Void
    ) {
        Self.persistenceQueue.async { [self] in
            completion(workspaces(limit: limit))
        }
    }

    private static func sortedByRecency(
        _ entries: [PersistedWorkspace]
    ) -> [PersistedWorkspace] {
        entries.enumerated().sorted { lhs, rhs in
            if lhs.element.lastOpened != rhs.element.lastOpened {
                return lhs.element.lastOpened > rhs.element.lastOpened
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
