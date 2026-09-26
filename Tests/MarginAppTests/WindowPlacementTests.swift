import CoreGraphics
import Foundation
import XCTest
@testable import MarginApp

final class WindowPlacementTests: XCTestCase {
    private let laptop = WorkspaceDisplayGeometry(
        identifier: "laptop", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )
    private let external = WorkspaceDisplayGeometry(
        identifier: "external", visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1440)
    )

    func testDisconnectAndReconnectPreserveLargeWindowThroughRepeatedCaptures() throws {
        let preferred = frame(on: external, width: 1900, height: 1100)
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(preferred, displays: [laptop, external])

        // A window callback may arrive before the application notification.
        let fallbackRect = try XCTUnwrap(WorkspaceWindowPlacementResolver.resolve(preferred, displays: [laptop]))
        let fallback = WorkspaceWindowFrame(fallbackRect, displayIdentifier: laptop.identifier, displayFrame: laptop.visibleFrame)
        memory.capture(fallback, displays: [laptop])
        memory.displayConfigurationChanged(to: [laptop])
        XCTAssertEqual(memory.takeFrameForDisplayChange(), preferred)
        XCTAssertNil(memory.takeFrameForDisplayChange())
        for _ in 0..<5 { memory.capture(fallback, displays: [laptop]) }
        XCTAssertEqual(memory.preferredFrame, preferred)
        XCTAssertEqual(fallbackRect.size, laptop.visibleFrame.size)

        memory.displayConfigurationChanged(to: [external, laptop])
        memory.capture(fallback, displays: [external, laptop])
        let reconnect = try XCTUnwrap(memory.takeFrameForDisplayChange())
        XCTAssertEqual(WorkspaceWindowPlacementResolver.resolve(reconnect, displays: [external, laptop]), preferred.rect)
        XCTAssertEqual(memory.preferredFrame, preferred)
    }

    func testSmallWindowDoesNotGrowWhenAnotherDisplayDisappears() throws {
        let preferred = frame(on: laptop, width: 900, height: 650)
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(preferred, displays: [laptop, external])
        memory.displayConfigurationChanged(to: [laptop])
        memory.capture(frame(on: laptop, width: 1440, height: 900), displays: [laptop])
        let request = try XCTUnwrap(memory.takeFrameForDisplayChange())
        XCTAssertEqual(WorkspaceWindowPlacementResolver.resolve(request, displays: [laptop]), preferred.rect)
    }

    func testUserAdjustmentSupersedesPreferenceAndCancelsQueuedDisplayFit() {
        let preferred = frame(on: external, width: 1900, height: 1100)
        let chosen = frame(on: laptop, width: 850, height: 600)
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(preferred, displays: [laptop, external])
        memory.displayConfigurationChanged(to: [laptop])
        memory.userWillChangeFrame()
        XCTAssertNil(memory.takeFrameForDisplayChange())
        memory.capture(chosen, displays: [laptop])
        memory.displayConfigurationChanged(to: [laptop, external])
        XCTAssertEqual(memory.takeFrameForDisplayChange(), chosen)
        XCTAssertEqual(memory.preferredFrame, chosen)
    }

    func testStableDisplaysContinueToRememberOrdinaryGeometryChanges() {
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(frame(on: laptop, width: 900, height: 650), displays: [laptop, external])
        let chosen = frame(on: laptop, width: 1100, height: 700)
        memory.capture(chosen, displays: [external, laptop])
        XCTAssertEqual(memory.preferredFrame, chosen)
        XCTAssertFalse(memory.displayConfigurationChanged(to: [laptop, external]))
        XCTAssertNil(memory.takeFrameForDisplayChange())
    }

    func testUnchangedRestoredFrameAllowsSubsequentNativeGeometryChanges() {
        let original = frame(on: laptop, width: 900, height: 650)
        var memory = WorkspaceWindowPlacementMemory(preferredFrame: original)
        memory.capture(original, displays: [laptop])
        let tiled = frame(on: laptop, width: 720, height: 900)
        memory.capture(tiled, displays: [laptop])
        XCTAssertEqual(memory.preferredFrame, tiled)
    }

    func testDockAndSpaceVisibilityChangesDoNotTriggerDisplayRecovery() {
        let physicalFrame = CGRect(x: 0, y: 0, width: 1440, height: 960)
        let withDock = WorkspaceDisplayGeometry(identifier: "laptop", visibleFrame: laptop.visibleFrame, screenFrame: physicalFrame)
        let withoutDock = WorkspaceDisplayGeometry(identifier: "laptop", visibleFrame: physicalFrame, screenFrame: physicalFrame)
        let original = frame(on: laptop, width: 900, height: 650)
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(original, displays: [withDock])
        XCTAssertFalse(memory.displayConfigurationChanged(to: [withoutDock]))
        memory.capture(original, displays: [withoutDock])
        XCTAssertFalse(memory.needsDisplayAdjustment)
        XCTAssertNil(memory.takeFrameForDisplayChange())
    }

    func testResolutionChangeAndLateSystemResizeCannotReplacePreference() throws {
        let preferred = frame(on: laptop, width: 1200, height: 800)
        let scaled = WorkspaceDisplayGeometry(identifier: laptop.identifier, visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 700))
        var memory = WorkspaceWindowPlacementMemory()
        memory.capture(preferred, displays: [laptop])
        memory.displayConfigurationChanged(to: [scaled])
        let request = try XCTUnwrap(memory.takeFrameForDisplayChange())
        let fitted = try XCTUnwrap(WorkspaceWindowPlacementResolver.resolve(request, displays: [scaled]))
        memory.capture(WorkspaceWindowFrame(fitted, displayIdentifier: scaled.identifier, displayFrame: scaled.visibleFrame), displays: [scaled])
        XCTAssertEqual(memory.preferredFrame, preferred)
        XCTAssertEqual(fitted.size, scaled.visibleFrame.size)
        memory.displayConfigurationChanged(to: [laptop])
        XCTAssertEqual(memory.takeFrameForDisplayChange(), preferred)
    }

    func testPreferredFrameSurvivesQuitAndRelaunchOnFallbackDisplay() throws {
        let preferred = frame(on: external, width: 1900, height: 1100)
        let current = frame(on: laptop, width: 1440, height: 900)
        let window = WorkspaceWindowSession(tabs: [], selectedIndex: 0, frame: current, preferredFrame: preferred)
        let saved = try JSONEncoder().encode(window)
        let restored = try JSONDecoder().decode(WorkspaceWindowSession.self, from: saved)
        XCTAssertEqual(restored.frame, current)
        var memory = WorkspaceWindowPlacementMemory(preferredFrame: restored.preferredFrame)
        memory.capture(current, displays: [laptop])
        XCTAssertEqual(memory.preferredFrame, preferred)
        memory.displayConfigurationChanged(to: [laptop, external])
        XCTAssertEqual(memory.takeFrameForDisplayChange(), preferred)
    }

    func testOlderSessionWithoutPreferredFrameStillDecodes() throws {
        let original = WorkspaceWindowSession(tabs: [], selectedIndex: 0, frame: frame(on: laptop, width: 900, height: 650))
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["preferredFrame"])
        let decoded = try JSONDecoder().decode(WorkspaceWindowSession.self, from: data)
        XCTAssertEqual(decoded.frame, original.frame)
        XCTAssertNil(decoded.preferredFrame)
    }

    private func frame(on display: WorkspaceDisplayGeometry, width: Double, height: Double) -> WorkspaceWindowFrame {
        WorkspaceWindowFrame(
            CGRect(x: display.visibleFrame.minX + 50, y: display.visibleFrame.minY + 40, width: width, height: height),
            displayIdentifier: display.identifier, displayFrame: display.visibleFrame
        )
    }
}
