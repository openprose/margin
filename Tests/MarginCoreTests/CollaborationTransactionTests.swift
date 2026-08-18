import Foundation
import XCTest
@testable import MarginCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CollaborationTransactionTests: XCTestCase {
    func testCrossFileSubmitAndRetryAreAtomicAndIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "new α\n", "nested/b.md": "new β\n"],
            pathOrder: ["nested/b.md", "a.md"]
        )
        let engine = fixture.engine()
        let evaluator = CollaborationChangeSetEvaluator(reader: engine)

        let first = try engine.submit(changeSet, evaluatedMutations: evaluator.evaluate(changeSet))
        XCTAssertEqual(first.disposition, .applied)
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "new α\n")
        XCTAssertEqual(try String(contentsOf: fixture.file("nested/b.md")), "new β\n")
        XCTAssertEqual(first.files.map(\.path), ["a.md", "nested/b.md"])

        let retry = try engine.submit(changeSet, evaluatedMutations: evaluator.evaluate(changeSet))
        XCTAssertEqual(retry.disposition, .alreadyApplied)
        XCTAssertEqual(retry.transactionID, first.transactionID)
        let activityStore = CollaborationActivityStore(stateDirectory: fixture.state)
        let records = try activityStore.load(root: fixture.root)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .transactionCommitted)
        XCTAssertEqual(records[0].actorID, changeSet.actor.id)
        let context = try CollaborationContextService(
            activityStore: activityStore,
            reader: fixture.engine()
        ).context(root: fixture.root)
        XCTAssertTrue(context.actors.contains { $0.id == changeSet.actor.id })
        XCTAssertTrue(context.activity.contains { $0.actorID == changeSet.actor.id })
    }

    func testOrdinaryFailureAfterFirstInstallRollsBackEveryFile() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "changed a", "nested/b.md": "changed b"]
        )
        struct Injected: Error {}
        let engine = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 0 { throw Injected() }
            }
        )
        XCTAssertThrowsError(try engine.submit(changeSet))
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "old a\n")
        XCTAssertEqual(try String(contentsOf: fixture.file("nested/b.md")), "old b\n")
        XCTAssertTrue(try recoveryJSON(in: fixture.state).isEmpty)
    }

#if canImport(Darwin)
    func testCommitAndRollbackPreserveModeAndExtendedAttributes() throws {
        let attribute = "com.margin.tests.collaboration"

        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let file = fixture.file("a.md")
            XCTAssertEqual(chmod(file.path, 0o640), 0)
            try setExtendedAttribute(Data("commit-tag".utf8), name: attribute, at: file)
            try addTestACL(at: file)
            let aclBefore = try aclText(at: file)
            let changeSet = try makeChangeSet(
                fixture: fixture,
                replacements: ["a.md": "committed with metadata"],
                identity: "metadata-commit"
            )

            XCTAssertEqual(try fixture.engine().submit(changeSet).disposition, .applied)
            XCTAssertEqual(try permissions(of: file), 0o640)
            XCTAssertEqual(try extendedAttribute(name: attribute, at: file), Data("commit-tag".utf8))
            XCTAssertEqual(try aclText(at: file), aclBefore)
        }

        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let file = fixture.file("a.md")
            XCTAssertEqual(chmod(file.path, 0o604), 0)
            try setExtendedAttribute(Data("rollback-tag".utf8), name: attribute, at: file)
            try addTestACL(at: file)
            let aclBefore = try aclText(at: file)
            let changeSet = try makeChangeSet(
                fixture: fixture,
                replacements: ["a.md": "temporary a", "nested/b.md": "temporary b"],
                identity: "metadata-rollback"
            )
            struct Injected: Error {}
            let engine = CollaborationTransactionEngine(
                stateDirectory: fixture.state,
                faultInjector: { phase, index, _ in
                    if case .afterInstall = phase, index == 0 { throw Injected() }
                }
            )

            XCTAssertThrowsError(try engine.submit(changeSet))
            XCTAssertEqual(try String(contentsOf: file), "old a\n")
            XCTAssertEqual(try permissions(of: file), 0o604)
            XCTAssertEqual(try extendedAttribute(name: attribute, at: file), Data("rollback-tag".utf8))
            XCTAssertEqual(try aclText(at: file), aclBefore)
        }
    }
#else
    func testCommitAndRollbackPreserveMode() throws {
        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let file = fixture.file("a.md")
            XCTAssertEqual(chmod(file.path, 0o640), 0)
            let changeSet = try makeChangeSet(
                fixture: fixture,
                replacements: ["a.md": "committed with metadata"],
                identity: "metadata-commit"
            )

            XCTAssertEqual(try fixture.engine().submit(changeSet).disposition, .applied)
            XCTAssertEqual(try permissions(of: file), 0o640)
        }

        do {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let file = fixture.file("a.md")
            XCTAssertEqual(chmod(file.path, 0o604), 0)
            let changeSet = try makeChangeSet(
                fixture: fixture,
                replacements: ["a.md": "temporary a", "nested/b.md": "temporary b"],
                identity: "metadata-rollback"
            )
            struct Injected: Error {}
            let engine = CollaborationTransactionEngine(
                stateDirectory: fixture.state,
                faultInjector: { phase, index, _ in
                    if case .afterInstall = phase, index == 0 { throw Injected() }
                }
            )

            XCTAssertThrowsError(try engine.submit(changeSet))
            XCTAssertEqual(try String(contentsOf: file), "old a\n")
            XCTAssertEqual(try permissions(of: file), 0o604)
        }
    }
#endif

    func testCrashJournalRecoversExactOriginalsAndCleansMaterial() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let originalA = try Data(contentsOf: fixture.file("a.md"))
        let originalB = try Data(contentsOf: fixture.file("nested/b.md"))
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "crash a", "nested/b.md": "crash b"]
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 0 { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        XCTAssertFalse(try recoveryJSON(in: fixture.state).isEmpty)

        let recovered = try fixture.engine().recover(root: fixture.root)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].disposition, .recovered)
        XCTAssertEqual(try Data(contentsOf: fixture.file("a.md")), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.file("nested/b.md")), originalB)
        XCTAssertTrue(try recoveryJSON(in: fixture.state).isEmpty)
        XCTAssertFalse(try containsRecoveryMaterial(in: fixture.directory))
        let records = try CollaborationActivityStore(stateDirectory: fixture.state).load(root: fixture.root)
        XCTAssertEqual(records.map(\.kind), [.transactionRecovered])
    }

    func testConcurrentRecoverySerializesJournalDiscoveryAndCleanup() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let originalA = try Data(contentsOf: fixture.file("a.md"))
        let originalB = try Data(contentsOf: fixture.file("nested/b.md"))
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "interrupted a", "nested/b.md": "interrupted b"],
            identity: "concurrent-recovery"
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 0 { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        XCTAssertEqual(try recoveryJSON(in: fixture.state).count, 1)

        let results = RecoveryResultBox()
        let ready = DispatchGroup()
        let done = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            ready.enter()
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { done.leave() }
                ready.leave()
                start.wait()
                do { results.append(.success(try fixture.engine().recover(root: fixture.root))) }
                catch { results.append(.failure(error)) }
            }
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        start.signal()
        start.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(results.values.count, 2)
        let successful = results.values.compactMap { try? $0.get() }
        XCTAssertEqual(successful.count, 2)
        XCTAssertEqual(successful.flatMap { $0 }.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.file("a.md")), originalA)
        XCTAssertEqual(try Data(contentsOf: fixture.file("nested/b.md")), originalB)
        XCTAssertTrue(try recoveryJSON(in: fixture.state).isEmpty)
        XCTAssertFalse(try containsRecoveryMaterial(in: fixture.directory))
    }

    func testRecoveryPreservesExternalEditAndJournalOnConflict() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "Margin result", "nested/b.md": "other result"],
            identity: "external-recovery-conflict"
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 0 { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        try Data("external writer wins".utf8).write(to: fixture.file("a.md"))
        let journalsBefore = try recoveryJSON(in: fixture.state)

        XCTAssertThrowsError(try fixture.engine().recover(root: fixture.root)) { error in
            guard case CollaborationError.recoveryFailed = error else {
                return XCTFail("Expected fail-closed recovery conflict, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "external writer wins")
        XCTAssertEqual(try String(contentsOf: fixture.file("nested/b.md")), "old b\n")
        XCTAssertEqual(try recoveryJSON(in: fixture.state), journalsBefore)
        XCTAssertTrue(try containsRecoveryMaterial(in: fixture.directory))
    }

    func testRecoveryPreflightsEveryPathBeforeRollingBackAnyPath() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "installed a", "nested/b.md": "installed b"],
            identity: "all-path-recovery-preflight"
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 1 { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        XCTAssertEqual(try String(contentsOf: fixture.file("nested/b.md")), "installed b")
        try Data("external a".utf8).write(to: fixture.file("a.md"))
        let beforeA = try Data(contentsOf: fixture.file("a.md"))
        let beforeB = try Data(contentsOf: fixture.file("nested/b.md"))

        XCTAssertThrowsError(try fixture.engine().recover(root: fixture.root))
        XCTAssertEqual(try Data(contentsOf: fixture.file("a.md")), beforeA)
        XCTAssertEqual(
            try Data(contentsOf: fixture.file("nested/b.md")),
            beforeB,
            "A later-path conflict must not partially restore an earlier path."
        )
        XCTAssertFalse(try recoveryJSON(in: fixture.state).isEmpty)
    }

    func testRecoveryPreservesIndependentlyCreatedFormerlyAbsentTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cursor = try fixture.cursor()
        let mutation = try CollaborationFileMutation(
            id: "urn:mutation:create-conflict",
            path: "created.md",
            precondition: .absent,
            result: .write(data: Data("Margin creation".utf8), permissions: nil)
        )
        let changeSet = try fixture.changeSet(
            cursor: cursor,
            identity: "create-recovery-conflict",
            mutations: [mutation]
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, _, _ in
                if case .afterJournalPrepared = phase { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        try Data("independent creation".utf8).write(to: fixture.file("created.md"))

        XCTAssertThrowsError(try fixture.engine().recover(root: fixture.root))
        XCTAssertEqual(try String(contentsOf: fixture.file("created.md")), "independent creation")
        XCTAssertFalse(try recoveryJSON(in: fixture.state).isEmpty)
    }

    func testRetryCleansOnlyValidatedPreJournalArtifacts() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "retry result"],
            identity: "pre-journal-retry"
        )
        let unrelated = fixture.file(".margin-user-keeps-this.stage")
        try Data("unrelated".utf8).write(to: unrelated)
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterStagingFile = phase, index == 0 { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        XCTAssertTrue(try recoveryJSON(in: fixture.state).isEmpty)
        XCTAssertTrue(try containsRecoveryMaterial(in: fixture.directory))

        let receipt = try fixture.engine().submit(changeSet)
        XCTAssertEqual(receipt.disposition, .applied)
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "retry result")
        XCTAssertEqual(try String(contentsOf: unrelated), "unrelated")
        XCTAssertFalse(try containsTransactionMaterial(in: fixture.directory))
    }

    func testRecoveryJournalEnumerationFailsBeforeUnboundedDecode() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "interrupted"],
            identity: "bounded-journals"
        )
        let crashing = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, _, _ in
                if case .afterJournalPrepared = phase { throw CollaborationSimulatedCrash() }
            }
        )
        XCTAssertThrowsError(try crashing.submit(changeSet))
        let originalJournal = try XCTUnwrap(recoveryJSON(in: fixture.state).first)
        for index in 0..<64 {
            try FileManager.default.copyItem(
                at: originalJournal,
                to: originalJournal.deletingLastPathComponent()
                    .appendingPathComponent(String(format: "%064x.json", index + 1))
            )
        }
        let beforeA = try Data(contentsOf: fixture.file("a.md"))
        XCTAssertThrowsError(try fixture.engine().recover(root: fixture.root)) { error in
            guard case CollaborationError.recoveryFailed = error else {
                return XCTFail("Expected bounded recovery failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file("a.md")), beforeA)
        XCTAssertEqual(try recoveryJSON(in: fixture.state).count, 65)
    }

    func testAlreadyAppliedRetryPreservesOriginalActivityTimestamp() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let original = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "activity result"],
            identity: "fresh-retry-time"
        )
        let later = try CollaborationChangeSet(
            id: original.id,
            root: original.root,
            baseCursor: original.baseCursor,
            actor: original.actor,
            requestID: original.requestID,
            stageID: original.stageID,
            created: "2026-08-16T13:00:00Z",
            operations: original.operations,
            extensions: original.extensions
        )
        let engine = fixture.engine()
        XCTAssertEqual(try engine.submit(original).disposition, .applied)
        XCTAssertEqual(try engine.submit(later).disposition, .alreadyApplied)
        let records = try CollaborationActivityStore(stateDirectory: fixture.state).load(root: fixture.root)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].occurredAt, original.created)
    }

    func testTransactionSharesDocumentLocksWithCommentWriter() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "new a\n", "nested/b.md": "new b\n"],
            identity: "shared-document-lock"
        )
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let submitDone = DispatchSemaphore(value: 0)
        let submitResult = ResultBox()
        let engine = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .afterInstall = phase, index == 0 {
                    paused.signal()
                    resume.wait()
                }
            }
        )
        DispatchQueue.global(qos: .userInitiated).async {
            defer { submitDone.signal() }
            do { submitResult.append(.success(try engine.submit(changeSet))) }
            catch { submitResult.append(.failure(error)) }
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)

        let commentStarted = DispatchSemaphore(value: 0)
        let commentDone = DispatchSemaphore(value: 0)
        let commentError = ErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            commentStarted.signal()
            defer { commentDone.signal() }
            do {
                _ = try CommentService().add(
                    at: fixture.file("nested/b.md"),
                    message: "After the complete transaction",
                    creator: MarginActor(id: "urn:commenter:lock", type: .person, name: "Commenter"),
                    anchor: .document,
                    annotationID: "urn:comment:shared-lock"
                )
            } catch { commentError.set(error) }
        }
        XCTAssertEqual(commentStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(commentDone.wait(timeout: .now() + 0.2), .timedOut)
        resume.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(commentDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(commentError.value)
        XCTAssertNoThrow(try submitResult.values.first?.get())
        let final = try EmbeddedCommentCodec().decode(Data(contentsOf: fixture.file("nested/b.md")))
        XCTAssertEqual(final.body, "new b\n")
        XCTAssertEqual(final.envelope?.items.map(\.id), ["urn:comment:shared-lock"])
    }

    func testTransactionLocksNonTargetFilesBoundByBaseCursor() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "only a changes\n"],
            identity: "base-cursor-lock"
        )
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let submitDone = DispatchSemaphore(value: 0)
        let engine = CollaborationTransactionEngine(
            stateDirectory: fixture.state,
            faultInjector: { phase, index, _ in
                if case .beforeInstall = phase, index == 0 {
                    paused.signal()
                    resume.wait()
                }
            }
        )
        let submitResult = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { submitDone.signal() }
            do { submitResult.append(.success(try engine.submit(changeSet))) }
            catch { submitResult.append(.failure(error)) }
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 5), .success)

        let commentStarted = DispatchSemaphore(value: 0)
        let commentDone = DispatchSemaphore(value: 0)
        let commentError = ErrorBox()
        DispatchQueue.global(qos: .userInitiated).async {
            commentStarted.signal()
            defer { commentDone.signal() }
            do {
                _ = try CommentService().add(
                    at: fixture.file("nested/b.md"),
                    message: "Cursor-bound write",
                    creator: MarginActor(id: "urn:commenter:cursor", type: .person, name: "Commenter"),
                    anchor: .document,
                    annotationID: "urn:comment:cursor-lock"
                )
            } catch { commentError.set(error) }
        }
        XCTAssertEqual(commentStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(commentDone.wait(timeout: .now() + 0.2), .timedOut)
        resume.signal()
        XCTAssertEqual(submitDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(commentDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(commentError.value)
        XCTAssertNoThrow(try submitResult.values.first?.get())
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "only a changes\n")
        XCTAssertEqual(
            try CommentService().list(at: fixture.file("nested/b.md")).comments.map(\.annotation.id),
            ["urn:comment:cursor-lock"]
        )
    }

    func testConcurrentReverseOrderSubmissionsDoNotDeadlockOrMixStates() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let first = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "one-a", "nested/b.md": "one-b"],
            pathOrder: ["a.md", "nested/b.md"],
            identity: "one"
        )
        let second = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "two-a", "nested/b.md": "two-b"],
            pathOrder: ["nested/b.md", "a.md"],
            identity: "two"
        )
        let results = ResultBox()
        let group = DispatchGroup()
        for changeSet in [first, second] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do { results.append(.success(try fixture.engine().submit(changeSet))) }
                catch { results.append(.failure(error)) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(results.values.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(results.values.filter { if case .failure = $0 { true } else { false } }.count, 1)
        let a = try String(contentsOf: fixture.file("a.md"))
        let b = try String(contentsOf: fixture.file("nested/b.md"))
        XCTAssertTrue((a == "one-a" && b == "one-b") || (a == "two-a" && b == "two-b"))
    }

    func testCompleteCursorDetectsChangeInUntouchedInput() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let changeSet = try makeChangeSet(
            fixture: fixture,
            replacements: ["a.md": "only a"]
        )
        try Data("external b".utf8).write(to: fixture.file("nested/b.md"))
        XCTAssertThrowsError(try fixture.engine().submit(changeSet)) { error in
            guard case CollaborationError.preconditionFailed(let path, _) = error else {
                return XCTFail("Expected cursor precondition failure, got \(error)")
            }
            XCTAssertEqual(path, "nested/b.md")
        }
        XCTAssertEqual(try String(contentsOf: fixture.file("a.md")), "old a\n")
    }

    func testCreateAndRemoveCommitTogetherAndRetryIdempotently() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cursor = try fixture.cursor()
        let remove = try CollaborationFileMutation(
            id: "urn:mutation:remove",
            path: "a.md",
            precondition: .exact(try XCTUnwrap(cursor["a.md"])),
            result: .remove
        )
        let create = try CollaborationFileMutation(
            id: "urn:mutation:create",
            path: "created.md",
            precondition: .absent,
            result: .write(data: Data("created 🧭".utf8), permissions: 0o640)
        )
        let changeSet = try fixture.changeSet(
            cursor: cursor,
            identity: "create-remove",
            mutations: [create, remove]
        )
        let engine = fixture.engine()
        let evaluator = CollaborationChangeSetEvaluator(reader: engine)
        XCTAssertEqual(
            try engine.submit(changeSet, evaluatedMutations: evaluator.evaluate(changeSet)).disposition,
            .applied
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file("a.md").path))
        XCTAssertEqual(try String(contentsOf: fixture.file("created.md")), "created 🧭")
        XCTAssertEqual(try permissions(of: fixture.file("created.md")), 0o640)
        XCTAssertEqual(
            try engine.submit(changeSet, evaluatedMutations: evaluator.evaluate(changeSet)).disposition,
            .alreadyApplied
        )
    }

    func testSymlinkTargetAndTraversalAreRejectedWithoutTouchingOutsideFile() throws {
        let fixture = try makeFixture()
        let outside = try temporaryDirectory(prefix: "margin-collaboration-outside")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("outside.md")
        try Data("do not touch".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.file("linked.md"),
            withDestinationURL: outsideFile
        )
        let cursor = try fixture.cursor()
        let mutation = try CollaborationFileMutation(
            id: "urn:mutation:link",
            path: "linked.md",
            precondition: .absent,
            result: .write(data: Data("bad".utf8), permissions: nil)
        )
        let changeSet = try fixture.changeSet(cursor: cursor, identity: "link", mutations: [mutation])
        XCTAssertThrowsError(try fixture.engine().submit(changeSet)) { error in
            guard case CollaborationError.symlinkNotAllowed = error else {
                return XCTFail("Expected symlink rejection, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: outsideFile), "do not touch")
        XCTAssertThrowsError(try CollaborationFileMutation(
            id: "urn:mutation:traversal",
            path: "../outside.md",
            precondition: .absent,
            result: .write(data: Data(), permissions: nil)
        ))
    }

    private func makeChangeSet(
        fixture: Fixture,
        replacements: [String: String],
        pathOrder: [String]? = nil,
        identity: String = "test"
    ) throws -> CollaborationChangeSet {
        let cursor = try fixture.cursor()
        let paths = pathOrder ?? replacements.keys.sorted()
        let mutations = try paths.map { path in
            try CollaborationFileMutation(
                id: "urn:mutation:\(identity):\(path)",
                path: path,
                precondition: .exact(try XCTUnwrap(cursor[path])),
                result: .write(data: Data(try XCTUnwrap(replacements[path]).utf8), permissions: nil)
            )
        }
        return try fixture.changeSet(cursor: cursor, identity: identity, mutations: mutations)
    }

    private func makeFixture() throws -> Fixture {
        let directory = try temporaryDirectory(prefix: "margin-collaboration-transaction")
        let state = try temporaryDirectory(prefix: "margin-collaboration-state")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data("old a\n".utf8).write(to: directory.appendingPathComponent("a.md"))
        try Data("old b\n".utf8).write(to: directory.appendingPathComponent("nested/b.md"))
        let root = try CollaborationRootResolver().directory(at: directory)
        return Fixture(directory: directory, state: state, root: root)
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recoveryJSON(in state: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: state, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "json" && $0.path.contains("/transactions/")
        }
    }

    private func containsRecoveryMaterial(in directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.compactMap { $0 as? URL }.contains {
            $0.lastPathComponent.hasPrefix(".margin-")
        }
    }

    private func containsTransactionMaterial(in directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.compactMap { $0 as? URL }.contains {
            let name = $0.lastPathComponent
            guard name.hasPrefix(".margin-"),
                  name.count > ".margin-".count + 65,
                  $0.pathExtension == "backup" || $0.pathExtension == "stage" else { return false }
            let remainder = name.dropFirst(".margin-".count)
            let digest = remainder.prefix(64)
            return digest.count == 64
                && digest.allSatisfy { $0.isHexDigit }
                && remainder.dropFirst(64).first == "-"
        }
    }

    private func permissions(of url: URL) throws -> UInt16 {
        var value = stat()
        guard stat(url.path, &value) == 0 else {
            throw CollaborationError.io("Could not inspect test permissions.")
        }
        return UInt16(value.st_mode & 0o777)
    }

#if canImport(Darwin)
    private func setExtendedAttribute(_ data: Data, name: String, at url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else {
            throw CollaborationError.io("Could not set test xattr: \(String(cString: strerror(errno))).")
        }
    }

    private func extendedAttribute(name: String, at url: URL) throws -> Data {
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        guard count >= 0 else {
            throw CollaborationError.io("Could not size test xattr: \(String(cString: strerror(errno))).")
        }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard read == count else {
            throw CollaborationError.io("Could not read test xattr: \(String(cString: strerror(errno))).")
        }
        return data
    }

    private func addTestACL(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CollaborationError.io("Could not install the test ACL.")
        }
    }

    private func aclText(at url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            throw CollaborationError.io("Could not read the test ACL.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else {
            throw CollaborationError.io("Could not serialize the test ACL.")
        }
        defer { acl_free(text) }
        return String(cString: text)
    }
#endif
}

private struct Fixture: @unchecked Sendable {
    let directory: URL
    let state: URL
    let root: CollaborationRoot

    func file(_ path: String) -> URL { directory.appendingPathComponent(path) }

    func cursor() throws -> CollaborationCursor {
        try CollaborationCursorService().capture(
            root: root,
            paths: ["a.md", "nested/b.md"]
        )
    }

    func engine() -> CollaborationTransactionEngine {
        CollaborationTransactionEngine(lockTimeout: 2, stateDirectory: state)
    }

    func changeSet(
        cursor: CollaborationCursor,
        identity: String,
        mutations: [CollaborationFileMutation]
    ) throws -> CollaborationChangeSet {
        let actor = try CollaborationActor(id: "urn:actor:\(identity)", type: .software, name: "Agent \(identity)")
        return try CollaborationChangeSet(
            id: "urn:changeset:\(identity)",
            root: root,
            baseCursor: cursor,
            actor: actor,
            requestID: "urn:request:\(identity)",
            stageID: "urn:stage:\(identity)",
            created: "2026-08-16T12:00:00Z",
            operations: mutations.enumerated().map { index, mutation in
                .file(id: "urn:operation:\(identity):\(index)", mutation)
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: state)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<CollaborationTransactionReceipt, Error>] = []

    var values: [Result<CollaborationTransactionReceipt, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Result<CollaborationTransactionReceipt, Error>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class RecoveryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<[CollaborationTransactionReceipt], Error>] = []

    var values: [Result<[CollaborationTransactionReceipt], Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Result<[CollaborationTransactionReceipt], Error>) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ error: Error) {
        lock.lock()
        storage = error
        lock.unlock()
    }
}
