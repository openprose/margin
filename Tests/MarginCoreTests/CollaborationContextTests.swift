import Foundation
import XCTest
@testable import MarginCore

final class CollaborationContextTests: XCTestCase {
    func testStandaloneTemporaryFileDoesNotWalkPastFilesystemRoot() throws {
        let fixture = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("standalone.md")
        try Data("# Standalone\n".utf8).write(to: file)

        let root = try CollaborationRootResolver().resolve(target: file)
        XCTAssertEqual(root.kind, .document)
        XCTAssertEqual(root.path, file.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNil(root.workspaceID)

        let legacyDiscovery = try JSONDecoder().decode(
            CollaborationDiscoveryResult.self,
            from: Data(
                #"{"paths":[],"bytes":0,"omittedFileCount":0,"hitFileLimit":false,"hitByteLimit":false,"hitDepthLimit":false}"#.utf8
            )
        )
        XCTAssertNil(legacyDiscovery.omittedFileCountIsLowerBound)
    }

    func testWorkspaceInitializationDiscoveryAndContextAreBoundedAndDeterministic() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Root\n\nWelcome.\n".utf8).write(to: directory.appendingPathComponent("README.md"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("# Café ☕️\n".utf8).write(to: directory.appendingPathComponent("notes/équipe.md"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("drafts"), withIntermediateDirectories: true)
        try Data("hidden by rule".utf8).write(to: directory.appendingPathComponent("drafts/no.md"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("node_modules/pkg/deep"), withIntermediateDirectories: true)
        for index in 0..<50 {
            try Data("dependency".utf8).write(
                to: directory.appendingPathComponent("node_modules/pkg/deep/\(index).md")
            )
        }
        try Data("hidden by discovery".utf8).write(to: directory.appendingPathComponent(".secret.md"))

        let initialized = try CollaborationWorkspaceService().initialize(
            at: directory,
            id: "urn:workspace:context",
            created: "2026-08-16T12:00:00Z",
            include: ["**/*.md"],
            exclude: ["drafts/**"]
        )
        XCTAssertEqual(initialized.disposition, .created)
        let second = try CollaborationWorkspaceService().initialize(
            at: directory,
            id: "urn:workspace:context",
            created: "2026-08-16T12:00:00Z",
            include: ["**/*.md"],
            exclude: ["drafts/**"]
        )
        XCTAssertEqual(second.disposition, .alreadyPresent)

        let root = try CollaborationRootResolver().resolve(target: directory.appendingPathComponent("README.md"))
        XCTAssertEqual(root.workspaceID, "urn:workspace:context")
        let metadataDirectory = directory.appendingPathComponent(".margin")
        let metadataBefore = try FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path).sorted()
        let context = try CollaborationContextService().context(
            root: root,
            limits: CollaborationContextLimits(
                discovery: CollaborationDiscoveryLimits(maxFiles: 20, maxBytes: 1_000_000, maxDepth: 8),
                maxHeadingsPerFile: 5,
                maxContributionsPerFile: 5
            )
        )
        XCTAssertEqual(context.files.map(\.path), ["README.md", "notes/équipe.md"])
        XCTAssertEqual(context.cursor.files.map(\.path), ["README.md", "notes/équipe.md"])
        XCTAssertFalse(context.truncation.isTruncated)
        XCTAssertEqual(context.truncation.discovery.omittedFileCountIsLowerBound, false)
        XCTAssertEqual(context.files[1].outline.first?.title, "Café ☕️")
        XCTAssertEqual(context.files[0].sourcePreview, "# Root\n\nWelcome.\n")
        XCTAssertFalse(context.files[0].sourcePreviewTruncated)
        XCTAssertTrue(context.availableActions.contains(.readDocument))
        XCTAssertTrue(context.availableActions.contains(.replyToThread))
        XCTAssertTrue(context.availableActions.contains(.resolveThread))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path).sorted(),
            metadataBefore,
            "Read-only context must not create activity, stage, or transaction directories."
        )
    }

    func testContextReportsTypedOpenWorkActorAndAnchorHealth() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("review.md")
        try Data("# Review\n\nA precise boundary.\n".utf8).write(to: file)
        let actor = MarginActor(id: "urn:agent:reviewer", type: .software, name: "Review Bot")
        let service = CommentService()
        _ = try service.add(
            at: file,
            message: "Please justify this.",
            creator: actor,
            anchor: .quote(exact: "precise boundary"),
            annotationID: "urn:question:one"
        )
        _ = try service.add(
            at: file,
            message: "Please own this follow-up.",
            creator: actor,
            anchor: .quote(exact: "boundary"),
            annotationID: "urn:task:two"
        )
        var decoded = try EmbeddedCommentCodec().decode(Data(contentsOf: file))
        decoded.envelope?.items[0].extensions["margin:kind"] = .string("question")
        decoded.envelope?.items[1].extensions["margin:kind"] = .string("task")
        decoded.envelope?.items[1].extensions["margin:assignee"] = .string("urn:agent:owner")
        let encoded = try EmbeddedCommentCodec().encode(bodyData: decoded.bodyData, envelope: decoded.envelope)
        try encoded.write(to: file)

        let root = try CollaborationRootResolver().document(at: file)
        let context = try CollaborationContextService().context(root: root)
        let contribution = try XCTUnwrap(context.files.first?.contributions.first)
        XCTAssertEqual(contribution.kind, .question)
        XCTAssertEqual(contribution.actorName, "Review Bot")
        XCTAssertEqual(contribution.anchorState, .anchored)
        XCTAssertEqual(contribution.threadStatus, .open)
        XCTAssertTrue(context.availableActions.contains(.listThreads))
        XCTAssertEqual(context.actors.first?.id, actor.id)
        let reviewerActivity = try XCTUnwrap(context.activity.first { $0.actorID == actor.id })
        XCTAssertEqual(reviewerActivity.authoredContributionIDs, ["urn:question:one", "urn:task:two"])
        XCTAssertEqual(reviewerActivity.openAuthoredContributionIDs, ["urn:question:one", "urn:task:two"])
        XCTAssertEqual(reviewerActivity.assignedOpenContributionIDs, [])
        let ownerActivity = try XCTUnwrap(context.activity.first { $0.actorID == "urn:agent:owner" })
        XCTAssertEqual(ownerActivity.assignedOpenContributionIDs, ["urn:task:two"])
        XCTAssertTrue(contribution.reference.hasPrefix("document#"))
        XCTAssertEqual(contribution.reference.split(separator: "#").last?.count, 8)
    }

    func testContextSourcePreviewIsBoundedAndExcludesEmbeddedMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.md")
        let body = "# Preview\n\nA deliberately longer logical Markdown source.\n"
        try Data(body.utf8).write(to: file)
        _ = try CommentService().add(
            at: file,
            message: "Metadata must stay out of the source preview.",
            creator: MarginActor(id: "urn:agent:preview", type: .software, name: "Preview Agent"),
            anchor: .document,
            annotationID: "urn:comment:preview"
        )

        let root = try CollaborationRootResolver().document(at: file)
        let context = try CollaborationContextService().context(
            root: root,
            limits: CollaborationContextLimits(maxSourcePreviewBytes: 12)
        )
        let preview = try XCTUnwrap(context.files.first)
        XCTAssertTrue(preview.sourcePreview.hasPrefix("# Preview"))
        XCTAssertTrue(preview.sourcePreviewTruncated)
        XCTAssertLessThanOrEqual(preview.sourcePreview.utf8.count, 15)
        XCTAssertFalse(preview.sourcePreview.contains("margin:comments"))
        XCTAssertFalse(preview.sourcePreview.contains("Metadata must stay out"))
    }

    func testExplicitPathRejectsTraversalAndSymlinkEscapeButAllowsUnicodeAndHiddenFile() throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        try Data("inside".utf8).write(to: directory.appendingPathComponent(".mémoire.md"))
        let root = try CollaborationRootResolver().directory(at: directory)
        let service = CollaborationCursorService()

        XCTAssertThrowsError(try service.capture(root: root, paths: ["../secret.md"]))
        XCTAssertThrowsError(try service.capture(root: root, paths: ["escape/secret.md"])) { error in
            guard case CollaborationError.symlinkNotAllowed = error else {
                return XCTFail("Expected symlink rejection, got \(error)")
            }
        }
        XCTAssertEqual(
            try service.capture(root: root, paths: [".mémoire.md"]).files.first?.path,
            ".mémoire.md"
        )
    }

    func testImmutableStageIsIdempotentAndRejectsIdentityCollision() throws {
        let directory = try temporaryDirectory()
        let state = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: state)
        }
        let file = directory.appendingPathComponent("stage.md")
        try Data("before".utf8).write(to: file)
        let root = try CollaborationRootResolver().document(at: file)
        let cursor = try CollaborationCursorService().capture(root: root)
        let actor = try CollaborationActor(id: "urn:actor:stage", type: .software, name: "Stage Agent")
        let first = try changeSet(
            root: root, cursor: cursor, actor: actor,
            stageID: "urn:stage:fixed", replacement: Data("after".utf8), operationID: "urn:op:one"
        )
        let store = CollaborationStageStore(stateDirectory: state)
        XCTAssertEqual(try store.stage(first).disposition, .created)
        XCTAssertEqual(try store.stage(first).disposition, .alreadyPresent)
        XCTAssertEqual(try store.load(stageID: first.stageID, root: root), first)

        let collision = try changeSet(
            root: root, cursor: cursor, actor: actor,
            stageID: "urn:stage:fixed", replacement: Data("different".utf8), operationID: "urn:op:two"
        )
        XCTAssertThrowsError(try store.stage(collision))
        XCTAssertEqual(try store.list(root: root), [first])

        let second = try changeSet(
            root: root, cursor: cursor, actor: actor,
            stageID: "urn:stage:second", replacement: Data("second".utf8), operationID: "urn:op:second"
        )
        _ = try store.stage(second)
        let bounded = try store.list(root: root, limit: 1)
        XCTAssertEqual(bounded.stages.count, 1)
        XCTAssertEqual(bounded.omittedCount, 1)
        XCTAssertTrue(bounded.isTruncated)
        XCTAssertEqual(try store.list(root: root, limit: 0).omittedCount, 2)

        let missingStageID = "urn:stage:missing"
        XCTAssertThrowsError(try store.load(stageID: missingStageID, root: root)) { error in
            XCTAssertEqual(error as? CollaborationError, .stageNotFound(missingStageID))
        }
    }

    func testShortReferencesAreDeterministicAndExtendOnCollision() {
        var firstContext = Set<String>()
        let first = CollaborationShortReference.make(
            path: "notes/design.md",
            annotationID: "urn:annotation:stable",
            used: &firstContext
        )
        var secondContext = Set<String>()
        let repeated = CollaborationShortReference.make(
            path: "notes/design.md",
            annotationID: "urn:annotation:stable",
            used: &secondContext
        )
        XCTAssertEqual(first, repeated)

        var collisionContext: Set<String> = [first]
        let extended = CollaborationShortReference.make(
            path: "notes/design.md",
            annotationID: "urn:annotation:stable",
            used: &collisionContext
        )
        XCTAssertNotEqual(extended, first)
        XCTAssertTrue(extended.hasPrefix(first))
    }

    func testActivityStoreIsCanonicalIdempotentAndBounded() throws {
        let directory = try temporaryDirectory()
        let state = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: state)
        }
        let file = directory.appendingPathComponent("activity.md")
        try Data("Activity\n".utf8).write(to: file)
        let root = try CollaborationRootResolver().document(at: file)
        let store = CollaborationActivityStore(stateDirectory: state, maximumRecords: 2)
        var records: [CollaborationActivityRecord] = []
        for index in 1...3 {
            records.append(try CollaborationActivityRecord(
                id: "urn:activity:\(index)",
                rootID: root.id,
                actorID: "urn:actor:activity",
                occurredAt: "2026-08-16T12:0\(index):00Z",
                kind: .transactionCommitted,
                paths: ["."],
                requestID: "urn:request:\(index)",
                stageID: "urn:stage:\(index)"
            ))
        }
        XCTAssertEqual(try store.record(records[0], root: root), .created)
        XCTAssertEqual(try store.record(records[0], root: root), .alreadyPresent)
        XCTAssertEqual(try store.record(records[1], root: root), .created)
        XCTAssertEqual(try store.record(records[2], root: root), .created)
        XCTAssertEqual(try store.load(root: root).map(\.id), ["urn:activity:2", "urn:activity:3"])
    }

    func testActivityListingFailsClosedOnExternallyBloatedDirectory() throws {
        let directory = try temporaryDirectory()
        let state = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: state)
        }
        let file = directory.appendingPathComponent("activity-bound.md")
        try Data("Activity\n".utf8).write(to: file)
        let root = try CollaborationRootResolver().document(at: file)
        let store = CollaborationActivityStore(stateDirectory: state, maximumRecords: 2)
        for index in 1...2 {
            _ = try store.record(try CollaborationActivityRecord(
                id: "urn:activity:bounded:\(index)",
                rootID: root.id,
                actorID: "urn:actor:bounded",
                occurredAt: "2026-08-16T12:0\(index):00Z",
                kind: .transactionCommitted,
                paths: ["."]
            ), root: root)
        }
        let files = FileManager.default.enumerator(at: state, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" } ?? []
        let existing = try XCTUnwrap(files.first)
        try FileManager.default.copyItem(
            at: existing,
            to: existing.deletingLastPathComponent().appendingPathComponent("external-extra.json")
        )

        XCTAssertThrowsError(try store.list(root: root, limit: 1)) { error in
            guard case CollaborationError.invalidActivity = error else {
                return XCTFail("Expected a bounded activity-directory failure, got \(error)")
            }
        }
    }

    func testContextHardOutputBudgetTruncatesBeforeSerialization() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large-context.md")
        let body = "# Bounded\n"
        let actor = MarginActor(id: "urn:actor:large-context", type: .software, name: "Context Agent")
        let timestamp = "2026-08-16T12:00:00Z"
        let items = (0..<80).map { index in
            MarginComment(
                id: "urn:comment:large:\(index)",
                motivation: "commenting",
                creator: actor,
                created: timestamp,
                modified: timestamp,
                body: MarginCommentBody(value: String(repeating: "文", count: 8_000)),
                target: .resource("urn:document:large-context"),
                status: .open
            )
        }
        let envelope = EmbeddedCommentEnvelope(
            documentID: "urn:document:large-context",
            modified: timestamp,
            items: items,
            revision: 1
        )
        try EmbeddedCommentCodec().encode(
            bodyData: Data(body.utf8),
            envelope: envelope
        ).write(to: file)
        let root = try CollaborationRootResolver().document(at: file)
        let limit = 1_048_576
        let context = try CollaborationContextService().context(
            root: root,
            limits: CollaborationContextLimits(
                maxHeadingsPerFile: 32,
                maxContributionsPerFile: 80,
                maxBodyPreviewBytes: 24_000,
                maxActivityRecords: 0,
                maxSerializedBytes: limit
            )
        )
        XCTAssertTrue(context.truncation.hitOutputByteLimit)
        XCTAssertTrue(context.truncation.isTruncated)
        XCTAssertGreaterThan(context.truncation.omittedContributionCount, 0)
        XCTAssertLessThanOrEqual(try CollaborationCanonicalJSON.encode(context).count, limit)
    }

    private func changeSet(
        root: CollaborationRoot,
        cursor: CollaborationCursor,
        actor: CollaborationActor,
        stageID: String,
        replacement: Data,
        operationID: String
    ) throws -> CollaborationChangeSet {
        let base = try XCTUnwrap(cursor.files.first)
        let mutation = try CollaborationFileMutation(
            id: "\(operationID):mutation",
            path: ".",
            precondition: .exact(base),
            result: .write(data: replacement, permissions: nil)
        )
        return try CollaborationChangeSet(
            id: "\(operationID):changeset",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: "\(operationID):request",
            stageID: stageID,
            created: "2026-08-16T12:00:00Z",
            operations: [.file(id: operationID, mutation)]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("margin-collaboration-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
