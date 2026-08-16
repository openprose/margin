import Foundation

struct EditorContinuityState: Codable, Equatable {
    var selectionLocation: Int
    var selectionLength: Int
    var scrollFraction: Double
    var selectedThreadID: String?

    static let beginning = EditorContinuityState(
        selectionLocation: 0,
        selectionLength: 0,
        scrollFraction: 0,
        selectedThreadID: nil
    )
}

protocol WorkspaceContinuityProviding: AnyObject {
    func captureContinuityState() -> EditorContinuityState
    func restoreContinuityState(_ state: EditorContinuityState)
}

struct WorkspaceTabSession: Codable, Equatable {
    var workspacePath: String
    var documentPath: String?
    var readerMode: Bool
    var navigatorVisible: Bool
    var commentsVisible: Bool
    var editor: EditorContinuityState
}

struct WorkspaceSession: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var tabs: [WorkspaceTabSession]
    var selectedIndex: Int
}

final class WorkspaceSessionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "MarginWorkspaceSession.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> WorkspaceSession? {
        guard let data = defaults.data(forKey: key),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
              session.version == WorkspaceSession.currentVersion,
              !session.tabs.isEmpty else { return nil }
        return session
    }

    func save(_ session: WorkspaceSession?) {
        guard let session, !session.tabs.isEmpty,
              let data = try? JSONEncoder().encode(session) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
