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
    var scratchpadID: UUID? = nil
    var scratchpadTitle: String? = nil
    var restorationIdentifier: String? = nil
}

struct WorkspaceWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var displayIdentifier: String? = nil
    var displayX: Double? = nil
    var displayY: Double? = nil
    var displayWidth: Double? = nil
    var displayHeight: Double? = nil

    init(
        _ frame: CGRect,
        displayIdentifier: String? = nil,
        displayFrame: CGRect? = nil
    ) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.size.width
        height = frame.size.height
        self.displayIdentifier = displayIdentifier
        displayX = displayFrame.map { Double($0.origin.x) }
        displayY = displayFrame.map { Double($0.origin.y) }
        displayWidth = displayFrame.map { Double($0.size.width) }
        displayHeight = displayFrame.map { Double($0.size.height) }
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var savedDisplayFrame: CGRect? {
        guard let displayX,
              let displayY,
              let displayWidth,
              let displayHeight,
              displayWidth > 0,
              displayHeight > 0 else { return nil }
        return CGRect(
            x: displayX,
            y: displayY,
            width: displayWidth,
            height: displayHeight
        )
    }
}

struct WorkspaceDisplayGeometry: Equatable {
    var identifier: String?
    var visibleFrame: CGRect
}

enum WorkspaceWindowPlacementResolver {
    static func resolve(
        _ state: WorkspaceWindowFrame,
        displays: [WorkspaceDisplayGeometry]
    ) -> CGRect? {
        guard state.width >= 720,
              state.height >= 480,
              !displays.isEmpty else { return nil }

        let savedFrame = state.rect
        let targetDisplay = state.displayIdentifier.flatMap { identifier in
            displays.first { $0.identifier == identifier }
        } ?? bestDisplay(for: state, displays: displays)
        guard let targetDisplay else { return nil }

        var restoredFrame = savedFrame
        if let savedDisplayFrame = state.savedDisplayFrame {
            restoredFrame.origin.x = targetDisplay.visibleFrame.origin.x
                + savedFrame.origin.x - savedDisplayFrame.origin.x
            restoredFrame.origin.y = targetDisplay.visibleFrame.origin.y
                + savedFrame.origin.y - savedDisplayFrame.origin.y
        }
        return constrain(restoredFrame, to: targetDisplay.visibleFrame)
    }

    private static func bestDisplay(
        for state: WorkspaceWindowFrame,
        displays: [WorkspaceDisplayGeometry]
    ) -> WorkspaceDisplayGeometry? {
        let referenceFrame = state.savedDisplayFrame ?? state.rect
        let intersecting = displays.max { left, right in
            intersectionArea(referenceFrame, left.visibleFrame)
                < intersectionArea(referenceFrame, right.visibleFrame)
        }
        if let intersecting,
           intersectionArea(referenceFrame, intersecting.visibleFrame) > 0 {
            return intersecting
        }
        return displays.first
    }

    private static func intersectionArea(_ left: CGRect, _ right: CGRect) -> Double {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func constrain(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(
            max(result.origin.x, visibleFrame.minX),
            visibleFrame.maxX - result.width
        )
        result.origin.y = min(
            max(result.origin.y, visibleFrame.minY),
            visibleFrame.maxY - result.height
        )
        return result
    }
}

struct WorkspaceWindowSession: Codable, Equatable {
    var tabs: [WorkspaceTabSession]
    var selectedIndex: Int
    var frame: WorkspaceWindowFrame?
    var space: WorkspaceSpaceAssignment? = nil
}

struct WorkspaceSpaceAssignment: Codable, Equatable {
    var spaceUUID: String?
    var managedSpaceID: UInt64?
    var displayIdentifier: String?
    var desktopOrdinal: Int?
    var spaceType: Int
}

struct WorkspaceSession: Codable, Equatable {
    static let currentVersion = 2

    var version: Int = currentVersion
    var windows: [WorkspaceWindowSession]
    var selectedWindowIndex: Int
}

private struct LegacyWorkspaceSession: Codable {
    var version: Int
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
        guard let data = defaults.data(forKey: key) else { return nil }
        if let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
           session.version == WorkspaceSession.currentVersion,
           !session.windows.isEmpty,
           session.windows.contains(where: { !$0.tabs.isEmpty }) {
            return session
        }
        guard let legacy = try? JSONDecoder().decode(LegacyWorkspaceSession.self, from: data),
              legacy.version == 1,
              !legacy.tabs.isEmpty else { return nil }
        return WorkspaceSession(
            windows: [WorkspaceWindowSession(
                tabs: legacy.tabs,
                selectedIndex: legacy.selectedIndex,
                frame: nil
            )],
            selectedWindowIndex: 0
        )
    }

    func save(_ session: WorkspaceSession?) {
        guard let session, !session.windows.isEmpty,
              session.windows.contains(where: { !$0.tabs.isEmpty }),
              let data = try? JSONEncoder().encode(session) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
