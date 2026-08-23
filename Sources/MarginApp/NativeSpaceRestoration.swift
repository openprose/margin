import AppKit
import Foundation
import MarginPrivateSupport

struct WorkspaceSpaceDescriptor: Equatable {
    var managedSpaceID: UInt64
    var spaceUUID: String?
    var displayIdentifier: String
    var desktopOrdinal: Int?
    var spaceType: Int
    var isActive: Bool
}

enum WorkspaceSpaceResolver {
    static func resolve(
        _ assignment: WorkspaceSpaceAssignment,
        in catalog: [WorkspaceSpaceDescriptor]
    ) -> WorkspaceSpaceDescriptor? {
        let desktops = catalog.filter { $0.spaceType == 0 }
        if let uuid = assignment.spaceUUID,
           let exact = desktops.first(where: { $0.spaceUUID == uuid }) {
            return exact
        }
        if assignment.spaceUUID == nil,
           let id = assignment.managedSpaceID,
           let hinted = desktops.first(where: {
               $0.managedSpaceID == id
                   && displayMatches(assignment.displayIdentifier, $0.displayIdentifier)
           }) {
            return hinted
        }
        if let display = assignment.displayIdentifier,
           let ordinal = assignment.desktopOrdinal,
           let ordinalMatch = desktops.first(where: {
               $0.displayIdentifier == display && $0.desktopOrdinal == ordinal
           }) {
            return ordinalMatch
        }
        if let display = assignment.displayIdentifier,
           let active = desktops.first(where: {
               $0.displayIdentifier == display && $0.isActive
           }) {
            return active
        }
        return nil
    }

    private static func displayMatches(_ saved: String?, _ candidate: String) -> Bool {
        saved == nil || saved == candidate
    }
}

protocol WorkspaceSpaceRestorationBackend: AnyObject {
    var isAvailable: Bool { get }
    func windowsAreOnActiveSpace(_ windowIDs: [CGWindowID]) -> Bool?
    func captureAssignment(
        forWindowIDs windowIDs: [CGWindowID]
    ) -> WorkspaceSpaceAssignment?
    func restore(
        windowIDs: [CGWindowID],
        assignment: WorkspaceSpaceAssignment,
        completion: @escaping (Bool) -> Void
    )
}

final class AppKitSpaceRestorationBackend: WorkspaceSpaceRestorationBackend {
    let isAvailable = false

    func windowsAreOnActiveSpace(_ windowIDs: [CGWindowID]) -> Bool? {
        nil
    }

    func captureAssignment(
        forWindowIDs windowIDs: [CGWindowID]
    ) -> WorkspaceSpaceAssignment? {
        nil
    }

    func restore(
        windowIDs: [CGWindowID],
        assignment: WorkspaceSpaceAssignment,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
}

final class TahoeNativeSpaceRestorationBackend: WorkspaceSpaceRestorationBackend {
    private static let supportedMajorVersion = 26
    private static let maximumVerificationAttempts = 20
    private static let verificationInterval: TimeInterval = 0.05

    let isAvailable: Bool

    init(processInfo: ProcessInfo = .processInfo) {
        isAvailable = processInfo.operatingSystemVersion.majorVersion
            == Self.supportedMajorVersion
            && MarginNativeSpacesAvailable()
    }

    func windowsAreOnActiveSpace(_ windowIDs: [CGWindowID]) -> Bool? {
        guard isAvailable, !windowIDs.isEmpty else { return nil }
        let activeSpaceIDs = Set(
            spaceCatalog().filter(\.isActive).map(\.managedSpaceID)
        )
        guard !activeSpaceIDs.isEmpty else { return nil }
        return !activeSpaceIDs.isDisjoint(with: spaceIDs(for: windowIDs))
    }

    func captureAssignment(
        forWindowIDs windowIDs: [CGWindowID]
    ) -> WorkspaceSpaceAssignment? {
        guard isAvailable, !windowIDs.isEmpty else { return nil }
        let catalog = spaceCatalog()
        let windowSpaces = Set(spaceIDs(for: windowIDs))
        let matchingDesktops = catalog.filter {
            $0.spaceType == 0 && windowSpaces.contains($0.managedSpaceID)
        }
        guard matchingDesktops.count == 1, let space = matchingDesktops.first else {
            return nil
        }
        return WorkspaceSpaceAssignment(
            spaceUUID: space.spaceUUID,
            managedSpaceID: space.managedSpaceID,
            displayIdentifier: space.displayIdentifier,
            desktopOrdinal: space.desktopOrdinal,
            spaceType: space.spaceType
        )
    }

    func restore(
        windowIDs: [CGWindowID],
        assignment: WorkspaceSpaceAssignment,
        completion: @escaping (Bool) -> Void
    ) {
        guard isAvailable,
              assignment.spaceType == 0,
              !windowIDs.isEmpty,
              let destination = WorkspaceSpaceResolver.resolve(
                  assignment,
                  in: spaceCatalog()
              ) else {
            completion(false)
            return
        }
        if allWindows(windowIDs, occupy: destination.managedSpaceID) {
            completion(true)
            return
        }
        let invoked = windowIDs.withUnsafeBufferPointer { buffer in
            MarginNativeSpacesMoveWindows(
                buffer.baseAddress,
                buffer.count,
                destination.managedSpaceID
            )
        }
        guard invoked else {
            completion(false)
            return
        }
        verify(
            windowIDs: windowIDs,
            destinationSpaceID: destination.managedSpaceID,
            remainingAttempts: Self.maximumVerificationAttempts,
            completion: completion
        )
    }

    private func verify(
        windowIDs: [CGWindowID],
        destinationSpaceID: UInt64,
        remainingAttempts: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if allWindows(windowIDs, occupy: destinationSpaceID) {
            completion(true)
            return
        }
        guard remainingAttempts > 1 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verificationInterval) {
            [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.verify(
                windowIDs: windowIDs,
                destinationSpaceID: destinationSpaceID,
                remainingAttempts: remainingAttempts - 1,
                completion: completion
            )
        }
    }

    private func allWindows(_ windowIDs: [CGWindowID], occupy spaceID: UInt64) -> Bool {
        windowIDs.allSatisfy { spaceIDs(for: [$0]).contains(spaceID) }
    }

    private func spaceIDs(for windowIDs: [CGWindowID]) -> [UInt64] {
        guard !windowIDs.isEmpty else { return [] }
        let spaces = windowIDs.withUnsafeBufferPointer { buffer in
            MarginNativeSpacesCopySpacesForWindows(buffer.baseAddress, buffer.count)
        }
        return (spaces as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    private func spaceCatalog() -> [WorkspaceSpaceDescriptor] {
        guard let managedDisplays = MarginNativeSpacesCopyManagedDisplaySpaces()
            as? [[String: Any]] else { return [] }
        var result: [WorkspaceSpaceDescriptor] = []
        for managedDisplay in managedDisplays {
            guard let rawDisplayIdentifier = managedDisplay["Display Identifier"] as? String,
                  let spaces = managedDisplay["Spaces"] as? [[String: Any]] else { continue }
            let displayIdentifier = normalizedDisplayIdentifier(rawDisplayIdentifier)
            let activeID = spaceID(in: managedDisplay["Current Space"])
            var desktopOrdinal = 0
            for space in spaces {
                guard let managedSpaceID = spaceID(in: space) else { continue }
                let type = (space["type"] as? NSNumber)?.intValue
                    ?? Int(MarginNativeSpacesGetType(managedSpaceID))
                let ordinal: Int?
                if type == 0 {
                    ordinal = desktopOrdinal
                    desktopOrdinal += 1
                } else {
                    ordinal = nil
                }
                let copiedName = MarginNativeSpacesCopyName(managedSpaceID) as String?
                let dictionaryUUID = space["uuid"] as? String
                result.append(WorkspaceSpaceDescriptor(
                    managedSpaceID: managedSpaceID,
                    spaceUUID: copiedName ?? dictionaryUUID,
                    displayIdentifier: displayIdentifier,
                    desktopOrdinal: ordinal,
                    spaceType: type,
                    isActive: activeID == managedSpaceID
                ))
            }
        }
        return result
    }

    private func spaceID(in value: Any?) -> UInt64? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return (dictionary["id64"] as? NSNumber)?.uint64Value
            ?? (dictionary["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    private func normalizedDisplayIdentifier(_ identifier: String) -> String {
        guard identifier == "Main" else { return identifier }
        return WorkspaceScreenIdentity.identifier(for: NSScreen.main) ?? identifier
    }
}

enum WorkspaceSpaceRestorationBackendFactory {
    static func make() -> WorkspaceSpaceRestorationBackend {
        let native = TahoeNativeSpaceRestorationBackend()
        return native.isAvailable ? native : AppKitSpaceRestorationBackend()
    }
}
