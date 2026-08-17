import Foundation
import XCTest
@testable import MarginCore

final class CollaborationModelsTests: XCTestCase {
    func testCursorTokenIsCanonicalDeterministicAndUnicodeSafe() throws {
        let root = try CollaborationRoot(
            id: "urn:workspace:設計",
            kind: .directory,
            path: "/tmp/équipe/設計"
        )
        let alpha = try fileCursor(path: "café/😀.md", seed: "a")
        let beta = try fileCursor(path: "文書.md", seed: "b")
        let cursor = try CollaborationCursor(root: root, files: [beta, alpha])

        let first = try cursor.token()
        let second = try cursor.token()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("="))
        XCTAssertEqual(try CollaborationCursor(token: first), cursor)
        XCTAssertEqual(cursor.files.map(\.path), ["café/😀.md", "文書.md"])

        XCTAssertThrowsError(try CollaborationCursor(token: first + "="))
        XCTAssertThrowsError(try CollaborationCursor(token: "mcur2:" + first.dropFirst(6)))
        var corrupt = Array(first)
        corrupt[corrupt.count - 1] = corrupt.last == "A" ? "B" : "A"
        XCTAssertThrowsError(try CollaborationCursor(token: String(corrupt)))
    }

    func testManifestUnknownNamespacedFieldsRoundTripCanonically() throws {
        let raw = Data(#"{"created":"2026-08-16T12:00:00Z","exclude":[],"id":"urn:workspace:test","include":["**/*.md"],"margin:future":{"emoji":"🧭","nested":[1,true,null]},"margin:version":1,"type":"MarginWorkspace","vendor:flag":"kept"}"#.utf8)
        let manifest = try CollaborationCanonicalJSON.decode(
            CollaborationWorkspaceManifest.self,
            from: raw
        )
        XCTAssertEqual(manifest.extensions["vendor:flag"], .string("kept"))
        XCTAssertNotNil(manifest.extensions["margin:future"])
        XCTAssertEqual(try CollaborationCanonicalJSON.encode(manifest), raw)

        let minimal = Data(#"{"created":"2026-08-16T12:00:00Z","id":"urn:workspace:minimal","margin:version":1,"type":"MarginWorkspace"}"#.utf8)
        let decodedMinimal = try CollaborationCanonicalJSON.decode(
            CollaborationWorkspaceManifest.self,
            from: minimal
        )
        XCTAssertEqual(decodedMinimal.include, CollaborationWorkspaceManifest.defaultInclude)
        XCTAssertEqual(decodedMinimal.exclude, CollaborationWorkspaceManifest.defaultExclude)
    }

    func testSuggestionAndHandoffFactoriesBindCursorAndPreserveActorIdentity() throws {
        let root = try CollaborationRoot(id: "urn:root:test", kind: .document, path: "/tmp/test.md")
        let base = try CollaborationCursor(root: root, files: [fileCursor(path: ".", seed: "base")])
        let actor = try CollaborationActor(
            id: "urn:agent:編者",
            type: .software,
            name: "Éditeur 🤖"
        )
        let suggestion = try CollaborationContributionFactory.suggestion(
            actor: actor,
            path: ".",
            range: UnicodeScalarRange(start: 2, end: 5),
            message: "Prefer the precise phrase.",
            expectedText: "e\u{301}文",
            replacementText: "é文✨",
            baseCursor: base,
            created: "2026-08-16T12:00:00Z",
            id: "urn:suggestion:one"
        )
        let annotation = try CollaborationContributionFactory.annotation(
            from: suggestion,
            actor: actor,
            documentID: "urn:document:one",
            source: "xxe\u{301}文yy"
        )
        XCTAssertEqual(annotation.creator, actor.marginActor)
        XCTAssertEqual(annotation.extensions["margin:kind"], .string("suggestion"))

        let handoff = try CollaborationContributionFactory.handoff(
            actor: actor,
            path: ".",
            message: "Continue from the unresolved decision.",
            startingCursor: base,
            finishingCursor: base,
            touchedAnnotationIDs: ["urn:z", "urn:a", "urn:z"],
            unresolvedIDs: ["urn:open"],
            intendedNextActors: ["urn:agent:next"],
            created: "2026-08-16T12:01:00Z",
            id: "urn:handoff:one"
        )
        guard case .handoff(let details) = handoff.details else {
            return XCTFail("Expected handoff details")
        }
        XCTAssertEqual(details.touchedAnnotationIDs, ["urn:a", "urn:z"])
        XCTAssertEqual(try CollaborationCursor(token: details.startingCursor), base)
    }

    func testChangeSetRejectsContributionAttributedToAnotherActor() throws {
        let root = try CollaborationRoot(id: "urn:root:test", kind: .document, path: "/tmp/test.md")
        let base = try CollaborationCursor(root: root, files: [fileCursor(path: ".", seed: "base")])
        let actor = try CollaborationActor(id: "urn:actor:a", type: .person, name: "A")
        let target = try CollaborationTarget(path: ".")
        let contribution = try CollaborationContribution(
            id: "urn:contribution:test",
            actorID: "urn:actor:b",
            created: "2026-08-16T12:00:00Z",
            body: "Different author",
            target: target,
            details: .comment(CollaborationCommentDetails())
        )
        XCTAssertThrowsError(try CollaborationChangeSet(
            root: root,
            baseCursor: base,
            actor: actor,
            requestID: "urn:request:test",
            stageID: "urn:stage:test",
            created: "2026-08-16T12:00:00Z",
            operations: [.contribution(
                id: "urn:operation:test",
                CollaborationContributionOperation(contribution: contribution)
            )]
        ))
    }

    func testActivitySummaryIsDurableOrderedAndContainsNoPresenceClaim() throws {
        let records = [
            try CollaborationActivityRecord(
                id: "urn:activity:2", rootID: "urn:root", actorID: "urn:actor",
                occurredAt: "2026-08-16T12:01:00Z", kind: .transactionCommitted,
                paths: ["z.md", "a.md"], contributionIDs: ["urn:c2"], contributionKinds: [.task]
            ),
            try CollaborationActivityRecord(
                id: "urn:activity:1", rootID: "urn:root", actorID: "urn:actor",
                occurredAt: "2026-08-16T12:00:00Z", kind: .contributionObserved,
                paths: ["a.md"], contributionIDs: ["urn:c1"], contributionKinds: [.comment, .task]
            ),
        ]
        let summary = try XCTUnwrap(CollaborationActivity.summarize(records).first)
        XCTAssertEqual(summary.firstObservedAt, "2026-08-16T12:00:00Z")
        XCTAssertEqual(summary.lastObservedAt, "2026-08-16T12:01:00Z")
        XCTAssertEqual(summary.filesTouched, ["a.md", "z.md"])
        XCTAssertEqual(summary.contributionCounts["task"], 2)
        let json = String(decoding: try CollaborationCanonicalJSON.encode(summary), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("online"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("presence"))
    }

    func testContributionValidationRejectsConflictingTargetsAndRawHandoffData() throws {
        let root = try CollaborationRoot(id: "urn:root:validation", kind: .document, path: "/tmp/validation.md")
        let cursor = try CollaborationCursor(root: root, files: [fileCursor(path: ".", seed: "validation")])
        let actor = try CollaborationActor(id: "urn:actor:validation", type: .software, name: "Validator")

        XCTAssertThrowsError(try CollaborationContribution(
            id: "urn:comment:mismatch",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Reply",
            target: CollaborationTarget(path: ".", annotationID: "urn:parent:one"),
            details: .comment(CollaborationCommentDetails(parentID: "urn:parent:two"))
        ))
        XCTAssertThrowsError(try CollaborationContribution(
            id: "urn:question:annotation-target",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Question",
            target: CollaborationTarget(path: ".", annotationID: "urn:parent"),
            details: .question(CollaborationQuestionDetails())
        ))
        XCTAssertThrowsError(try CollaborationContribution(
            id: "urn:suggestion:empty",
            actorID: actor.id,
            created: "2026-08-16T12:00:00Z",
            body: "Suggestion",
            target: CollaborationTarget(path: ".", range: UnicodeScalarRange(start: 0, end: 1)),
            details: .suggestion(CollaborationSuggestionDetails(
                expectedText: "",
                replacementText: "replacement",
                baseContentSha256: cursor.files[0].contentSha256
            ))
        ))

        let handoff = try CollaborationContributionFactory.handoff(
            actor: actor,
            path: ".",
            message: "Continue",
            startingCursor: cursor,
            touchedAnnotationIDs: ["urn:a", "urn:b"],
            created: "2026-08-16T12:00:00Z",
            id: "urn:handoff:raw-validation"
        )
        let encoded = try CollaborationCanonicalJSON.encode(handoff)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var details = try XCTUnwrap(object["details"] as? [String: Any])
        var value = try XCTUnwrap(details["value"] as? [String: Any])
        value["startingCursor"] = "mcur1:not-a-canonical-cursor"
        value["touchedAnnotationIDs"] = ["urn:b", "urn:a", "urn:a"]
        details["value"] = value
        object["details"] = details
        object["audience"] = ["urn:z", "urn:a", "urn:a"]
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try CollaborationCanonicalJSON.decode(CollaborationContribution.self, from: raw)
        XCTAssertThrowsError(try decoded.validate())
    }

    func testManifestGlobBoundsAndMemoizedDoubleStarDiscovery() throws {
        XCTAssertThrowsError(try CollaborationWorkspaceManifest(
            created: "2026-08-16T12:00:00Z",
            include: Array(repeating: "**/*.md", count: 257)
        ))
        XCTAssertThrowsError(try CollaborationWorkspaceManifest(
            created: "2026-08-16T12:00:00Z",
            include: [String(repeating: "*", count: 1_025)]
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-glob-dp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var nested = directory
        for index in 0..<16 {
            nested.appendPathComponent("d\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("memoized".utf8).write(to: nested.appendingPathComponent("note.md"))
        let pattern = Array(repeating: "**", count: 128).joined(separator: "/") + "/*.md"
        _ = try CollaborationWorkspaceService().initialize(
            at: directory,
            id: "urn:workspace:glob-dp",
            created: "2026-08-16T12:00:00Z",
            include: [pattern],
            exclude: []
        )
        let root = try CollaborationRootResolver().directory(at: directory)
        let discovery = try CollaborationCursorService().discover(
            root: root,
            limits: CollaborationDiscoveryLimits(maxFiles: 4, maxBytes: 1_024, maxDepth: 32)
        )
        XCTAssertEqual(discovery.paths, [(0..<16).map { "d\($0)" }.joined(separator: "/") + "/note.md"])
    }

    private func fileCursor(path: String, seed: String) throws -> CollaborationFileCursor {
        let a = DocumentRevision(text: "content-\(seed)").sha256
        let b = DocumentRevision(text: "annotations-\(seed)").sha256
        let c = DocumentRevision(text: "whole-\(seed)").sha256
        return try CollaborationFileCursor(
            path: path,
            documentID: "urn:document:\(seed)",
            contentSha256: a,
            annotationRevision: 2,
            annotationSha256: b,
            wholeFileSha256: c
        )
    }
}
