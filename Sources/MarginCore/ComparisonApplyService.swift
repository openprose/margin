import Foundation

public enum ComparisonApplyDirection: String, Codable, Sendable {
    case leftToRight
    case rightToLeft

    public var destinationIsLeft: Bool { self == .rightToLeft }
}

public enum ComparisonApplyError: Error, LocalizedError, Sendable {
    case resultDoesNotMatchPair
    case noChangedBlocks
    case unknownBlock(String)
    case duplicateBlock(String)
    case invalidRange(String)
    case overlappingBlocks
    case staleDestination(expected: String, actual: String)
    case resultTooLarge(limit: Int, actual: Int)
    case unresolvedAnchors([String])

    public var code: String {
        switch self {
        case .resultDoesNotMatchPair: return "COMPARISON_RESULT_MISMATCH"
        case .noChangedBlocks: return "NO_COMPARISON_CHANGES"
        case .unknownBlock: return "COMPARISON_BLOCK_NOT_FOUND"
        case .duplicateBlock: return "DUPLICATE_COMPARISON_BLOCK"
        case .invalidRange: return "INVALID_COMPARISON_RANGE"
        case .overlappingBlocks: return "OVERLAPPING_COMPARISON_BLOCKS"
        case .staleDestination: return "COMPARISON_DESTINATION_STALE"
        case .resultTooLarge: return "RESOURCE_LIMIT"
        case .unresolvedAnchors: return "COMPARISON_APPLY_NEEDS_ATTENTION"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .resultDoesNotMatchPair:
            return "The comparison result does not belong to this snapshot generation."
        case .noChangedBlocks:
            return "There are no selected comparison changes to apply."
        case .unknownBlock(let id):
            return "No changed comparison block has id '\(id)'."
        case .duplicateBlock(let id):
            return "Comparison block '\(id)' was selected more than once."
        case .invalidRange(let id):
            return "Comparison block '\(id)' addresses bytes outside its snapshot."
        case .overlappingBlocks:
            return "Selected comparison blocks overlap and cannot be applied safely."
        case .staleDestination(let expected, let actual):
            return "The destination changed after comparison (expected \(expected), found \(actual))."
        case .resultTooLarge(let limit, let actual):
            return "The applied Markdown would contain \(actual) UTF-8 bytes, above the \(limit)-byte limit."
        case .unresolvedAnchors(let ids):
            return "Applying the comparison would leave \(ids.count) comment anchor(s) unresolved: \(ids.joined(separator: ", "))."
        }
    }
}

public struct ComparisonApplyPatch: Codable, Hashable, Sendable {
    public let blockID: String
    public let destination: ComparisonTextRange
    public let replacement: String

    public init(
        blockID: String,
        destination: ComparisonTextRange,
        replacement: String
    ) {
        self.blockID = blockID
        self.destination = destination
        self.replacement = replacement
    }
}

/// A content-only, inert plan. It contains no path and grants no write
/// authority. App and CLI callers must supply a destination explicitly.
public struct ComparisonApplyPlan: Codable, Hashable, Sendable {
    public let pairID: String
    public let snapshotGeneration: Int
    public let direction: ComparisonApplyDirection
    public let expectedDestinationSHA256: String
    public let patches: [ComparisonApplyPatch]

    public init(
        pairID: String,
        snapshotGeneration: Int,
        direction: ComparisonApplyDirection,
        expectedDestinationSHA256: String,
        patches: [ComparisonApplyPatch]
    ) {
        self.pairID = pairID
        self.snapshotGeneration = snapshotGeneration
        self.direction = direction
        self.expectedDestinationSHA256 = expectedDestinationSHA256
        self.patches = patches
    }
}

public struct ComparisonApplyReceipt: Codable, Hashable, Sendable {
    public let changed: Bool
    public let direction: ComparisonApplyDirection
    public let appliedBlockIDs: [String]
    public let previousBodySHA256: String
    public let contentSHA256: String
    public let annotationRevision: Int
    public let refreshedAnchorIDs: [String]

    public init(
        changed: Bool,
        direction: ComparisonApplyDirection,
        appliedBlockIDs: [String],
        previousBodySHA256: String,
        contentSHA256: String,
        annotationRevision: Int,
        refreshedAnchorIDs: [String]
    ) {
        self.changed = changed
        self.direction = direction
        self.appliedBlockIDs = appliedBlockIDs
        self.previousBodySHA256 = previousBodySHA256
        self.contentSHA256 = contentSHA256
        self.annotationRevision = annotationRevision
        self.refreshedAnchorIDs = refreshedAnchorIDs
    }
}

/// The all-or-none result of refreshing selected annotation anchors against a
/// prepared Markdown projection.
public struct ComparisonAnnotationRefresh: Hashable, Sendable {
    public let annotations: [MarginComment]
    public let refreshedAnchorIDs: [String]

    public init(annotations: [MarginComment], refreshedAnchorIDs: [String]) {
        self.annotations = annotations
        self.refreshedAnchorIDs = refreshedAnchorIDs
    }
}

/// The all-or-none result of moving embedded document annotations onto a new
/// Markdown body. Callers invoke this only after the logical body changes.
public struct ComparisonAnnotationReconciliation: Hashable, Sendable {
    public let annotations: [MarginComment]
    public let previousRevision: Int
    public let revision: Int
    public let refreshedAnchorIDs: [String]

    public init(
        annotations: [MarginComment],
        previousRevision: Int,
        revision: Int,
        refreshedAnchorIDs: [String]
    ) {
        self.annotations = annotations
        self.previousRevision = previousRevision
        self.revision = revision
        self.refreshedAnchorIDs = refreshedAnchorIDs
    }
}

public struct ComparisonApplyService: Sendable {
    public var codec: EmbeddedCommentCodec
    public var resolver: AnchorResolver
    public var store: AtomicDocumentStore
    public var limits: ComparisonLimits
    private let timestamp: @Sendable () -> String

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        resolver: AnchorResolver = AnchorResolver(),
        store: AtomicDocumentStore = AtomicDocumentStore(),
        limits: ComparisonLimits = .default,
        timestamp: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        self.codec = codec
        self.resolver = resolver
        self.store = store
        self.limits = limits
        self.timestamp = timestamp
    }

    /// Builds one immutable, all-or-none patch plan. Passing no block IDs means
    /// every changed block; passing an empty array is an error.
    public func plan(
        pair: ComparisonSnapshotPair,
        result: ComparisonDiffResult,
        direction: ComparisonApplyDirection,
        blockIDs: [String]? = nil
    ) throws -> ComparisonApplyPlan {
        guard result.pairID == pair.id,
              result.snapshotGeneration == pair.generation,
              result.leftSHA256 == pair.left.sha256,
              result.rightSHA256 == pair.right.sha256 else {
            throw ComparisonApplyError.resultDoesNotMatchPair
        }

        let changed = result.changedBlocks
        guard !changed.isEmpty else { throw ComparisonApplyError.noChangedBlocks }
        let selected: [ComparisonBlock]
        if let blockIDs {
            guard !blockIDs.isEmpty else { throw ComparisonApplyError.noChangedBlocks }
            var seen = Set<String>()
            let byID = Dictionary(uniqueKeysWithValues: changed.compactMap { block in
                block.id.map { ($0, block) }
            })
            selected = try blockIDs.map { id in
                guard seen.insert(id).inserted else {
                    throw ComparisonApplyError.duplicateBlock(id)
                }
                guard let block = byID[id] else {
                    throw ComparisonApplyError.unknownBlock(id)
                }
                return block
            }
        } else {
            selected = changed
        }

        let destinationSnapshot = direction.destinationIsLeft ? pair.left : pair.right
        let sourceSnapshot = direction.destinationIsLeft ? pair.right : pair.left
        let patches = try selected.map { block -> ComparisonApplyPatch in
            guard let blockID = block.id else {
                throw ComparisonApplyError.invalidRange("unchanged")
            }
            let destination = direction.destinationIsLeft ? block.left : block.right
            let source = direction.destinationIsLeft ? block.right : block.left
            let replacementData = try slice(sourceSnapshot.bodyData, range: source, blockID: blockID)
            _ = try slice(destinationSnapshot.bodyData, range: destination, blockID: blockID)
            guard let replacement = String(data: replacementData, encoding: .utf8) else {
                throw ComparisonError.invalidUTF8
            }
            return ComparisonApplyPatch(
                blockID: blockID,
                destination: destination,
                replacement: replacement
            )
        }.sorted {
            if $0.destination.utf8ByteStart == $1.destination.utf8ByteStart {
                return $0.destination.utf8ByteLength > $1.destination.utf8ByteLength
            }
            return $0.destination.utf8ByteStart > $1.destination.utf8ByteStart
        }
        try validateNonoverlapping(patches)

        return ComparisonApplyPlan(
            pairID: pair.id,
            snapshotGeneration: pair.generation,
            direction: direction,
            expectedDestinationSHA256: destinationSnapshot.sha256,
            patches: patches
        )
    }

    /// Applies the complete plan to an explicitly selected regular file. The
    /// current logical body must still match the compared destination, while a
    /// concurrent annotation-only change is preserved and re-anchored.
    public func apply(
        _ plan: ComparisonApplyPlan,
        to destinationURL: URL,
        cancellation: ComparisonCancellationToken? = nil,
        maximumAnchorScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws -> ComparisonApplyReceipt {
        try validate(plan)
        _ = try ComparisonRegularFile.read(
            at: destinationURL,
            maximumBytes: limits.maxRawDocumentBytes
        )
        return try store.transaction(
            at: destinationURL,
            maximumBytes: limits.maxRawDocumentBytes,
            rejectSymbolicLinks: true
        ) { current in
            guard current.count <= limits.maxRawDocumentBytes else {
                throw ComparisonError.resourceLimit(
                    name: "raw document bytes",
                    limit: limits.maxRawDocumentBytes,
                    actual: current.count
                )
            }
            let decoded = try codec.decode(current)
            let bodyPrefix = Self.leadingBOM(in: decoded.bodyData)
            let logicalOriginal = Data(decoded.bodyData.dropFirst(bodyPrefix.count))
            let actualDigest = MarginSHA256.hexDigest(of: logicalOriginal)
            guard actualDigest == plan.expectedDestinationSHA256 else {
                throw ComparisonApplyError.staleDestination(
                    expected: plan.expectedDestinationSHA256,
                    actual: actualDigest
                )
            }
            let body = try applyingPatches(plan.patches, to: logicalOriginal)
            try validateAppliedLogicalBody(body)
            var physicalBody = bodyPrefix
            physicalBody.append(body)
            guard let physicalBodyString = String(data: physicalBody, encoding: .utf8) else {
                throw ComparisonError.invalidUTF8
            }

            var envelope = decoded.envelope
            var refreshed: [String] = []
            if let currentEnvelope = envelope, body != logicalOriginal {
                let reconciliation = try reconciledEnvelopeAfterBodyChange(
                    currentEnvelope,
                    newPhysicalBody: physicalBodyString,
                    cancellation: cancellation,
                    maximumScalarComparisons: maximumAnchorScalarComparisons
                )
                envelope = reconciliation.envelope
                refreshed = reconciliation.refreshedAnchorIDs
            }
            let replacement = try codec.encode(bodyData: physicalBody, envelope: envelope)
            guard replacement.count <= limits.maxRawDocumentBytes else {
                throw ComparisonError.resourceLimit(
                    name: "raw document bytes",
                    limit: limits.maxRawDocumentBytes,
                    actual: replacement.count
                )
            }
            let receipt = ComparisonApplyReceipt(
                changed: replacement != current,
                direction: plan.direction,
                appliedBlockIDs: plan.patches.map(\.blockID).sorted(),
                previousBodySHA256: actualDigest,
                contentSHA256: MarginSHA256.hexDigest(of: body),
                annotationRevision: envelope?.revision ?? 0,
                refreshedAnchorIDs: refreshed.sorted()
            )
            return AtomicDocumentMutation(data: replacement, result: receipt)
        }
    }

    /// Applies an inert plan to an in-memory logical body. AppKit uses this to
    /// route the same verified patch set through an open editor's undo stack.
    public func applying(_ plan: ComparisonApplyPlan, to bodyData: Data) throws -> Data {
        try validate(plan)
        let bodyPrefix = Self.leadingBOM(in: bodyData)
        let logicalOriginal = Data(bodyData.dropFirst(bodyPrefix.count))
        let actual = MarginSHA256.hexDigest(of: logicalOriginal)
        guard actual == plan.expectedDestinationSHA256 else {
            throw ComparisonApplyError.staleDestination(
                expected: plan.expectedDestinationSHA256,
                actual: actual
            )
        }
        let logicalResult = try applyingPatches(plan.patches, to: logicalOriginal)
        try validateAppliedLogicalBody(logicalResult)
        var result = bodyPrefix
        result.append(logicalResult)
        return result
    }

    /// Reconciles every selection-bearing annotation against one prepared
    /// projection of the new body, preserves resource-target annotations, and
    /// advances the annotation revision exactly once for the body change. The
    /// input is never mutated: an unresolved anchor, cancellation, revision
    /// overflow, or deterministic work-budget exhaustion throws without
    /// returning a partial result.
    public func reconciledAnnotationsAfterBodyChange(
        _ original: [MarginComment],
        revision: Int,
        newPhysicalBody: String,
        cancellation: ComparisonCancellationToken? = nil,
        maximumScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws -> ComparisonAnnotationReconciliation {
        guard revision >= 0 else {
            throw ComparisonError.invalidArtifact(
                "The annotation revision cannot be negative."
            )
        }
        let (nextRevision, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw ComparisonError.invalidArtifact(
                "The annotation revision cannot be advanced safely."
            )
        }
        let refresh = try refreshSelectionAnnotations(
            original,
            withIDs: nil,
            in: newPhysicalBody,
            cancellation: cancellation,
            maximumScalarComparisons: maximumScalarComparisons
        )
        return ComparisonAnnotationReconciliation(
            annotations: refresh.annotations,
            previousRevision: revision,
            revision: nextRevision,
            refreshedAnchorIDs: refresh.refreshedAnchorIDs
        )
    }

    /// Refreshes all selection annotations, or only the supplied annotation
    /// IDs, using one shared scalar projection and one deterministic work
    /// budget. Resource targets and unselected annotations remain byte-for-byte
    /// equivalent. Failure never exposes a partially refreshed array.
    public func refreshSelectionAnnotations(
        _ original: [MarginComment],
        withIDs annotationIDs: Set<String>? = nil,
        in newPhysicalBody: String,
        cancellation: ComparisonCancellationToken? = nil,
        maximumScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws -> ComparisonAnnotationRefresh {
        let work = ComparisonReviewRefreshWork(
            limit: maximumScalarComparisons,
            cancellation: cancellation,
            resourceName: "document anchor reconciliation scalar comparisons"
        )
        try work.checkCancellation()

        var annotations = original
        var refreshed: [String] = []
        var unresolved: [String] = []
        let selectedIndices = annotations.indices.filter { index in
            guard annotationIDs?.contains(annotations[index].id) ?? true,
                  case .selection = annotations[index].target else { return false }
            return true
        }
        if !selectedIndices.isEmpty {
            let bodyBytes = newPhysicalBody.utf8.count
            guard bodyBytes <= limits.maxRawDocumentBytes else {
                throw ComparisonError.resourceLimit(
                    name: "document anchor reconciliation body bytes",
                    limit: limits.maxRawDocumentBytes,
                    actual: bodyBytes
                )
            }
            let projection = ComparisonReviewTextProjection(markdown: newPhysicalBody)
            try work.checkCancellation()
            let preparedResolver = ComparisonReviewPreparedResolver(
                projection: projection,
                contextLength: resolver.contextLength,
                minimumDisambiguatingContext: resolver.minimumDisambiguatingContext
            )
            for index in selectedIndices {
                guard case .selection(let target) = annotations[index].target else { continue }
                let resolution = try preparedResolver.resolve(target, work: work)
                guard resolution.state == .anchored || resolution.state == .moved,
                      let range = resolution.range else {
                    unresolved.append(annotations[index].id)
                    continue
                }
                annotations[index].target = .selection(
                    try projection.selectionTarget(
                        source: target.source,
                        start: range.start,
                        end: range.end,
                        contextLength: resolver.contextLength
                    )
                )
                refreshed.append(annotations[index].id)
            }
        }
        guard unresolved.isEmpty else {
            throw ComparisonApplyError.unresolvedAnchors(unresolved.sorted())
        }
        return ComparisonAnnotationRefresh(
            annotations: annotations,
            refreshedAnchorIDs: refreshed.sorted()
        )
    }

    /// Envelope adapter used by closed-file apply. It shares exactly the same
    /// prepared projection, deterministic budget, and atomic failure semantics
    /// as open-editor apply.
    func reconciledEnvelopeAfterBodyChange(
        _ original: EmbeddedCommentEnvelope,
        newPhysicalBody: String,
        cancellation: ComparisonCancellationToken? = nil,
        maximumScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws -> (envelope: EmbeddedCommentEnvelope, refreshedAnchorIDs: [String]) {
        var envelope = original
        let reconciliation = try reconciledAnnotationsAfterBodyChange(
            original.items,
            revision: original.revision,
            newPhysicalBody: newPhysicalBody,
            cancellation: cancellation,
            maximumScalarComparisons: maximumScalarComparisons
        )
        envelope.items = reconciliation.annotations
        envelope.revision = reconciliation.revision
        envelope.modified = timestamp()
        return (envelope, reconciliation.refreshedAnchorIDs)
    }

    private func slice(
        _ data: Data,
        range: ComparisonTextRange,
        blockID: String
    ) throws -> Data {
        let start = range.utf8ByteStart
        let (end, overflow) = start.addingReportingOverflow(range.utf8ByteLength)
        guard start >= 0, !overflow, end >= start, end <= data.count else {
            throw ComparisonApplyError.invalidRange(blockID)
        }
        return data.subdata(in: start..<end)
    }

    private func applyingPatches(
        _ patches: [ComparisonApplyPatch],
        to original: Data
    ) throws -> Data {
        var result = original
        for patch in patches {
            let start = patch.destination.utf8ByteStart
            let (end, overflow) = start.addingReportingOverflow(
                patch.destination.utf8ByteLength
            )
            guard start >= 0, !overflow, end >= start, end <= result.count else {
                throw ComparisonApplyError.invalidRange(patch.blockID)
            }
            result.replaceSubrange(start..<end, with: patch.replacement.utf8)
        }
        return result
    }

    private func validateAppliedLogicalBody(_ body: Data) throws {
        guard body.count <= limits.maxSnapshotUTF8Bytes else {
            throw ComparisonApplyError.resultTooLarge(
                limit: limits.maxSnapshotUTF8Bytes,
                actual: body.count
            )
        }
        guard let text = String(data: body, encoding: .utf8) else {
            throw ComparisonError.invalidUTF8
        }
        _ = try ComparisonSnapshot(
            markdownBody: text,
            label: "Applied comparison",
            limits: limits
        )
    }

    private func validate(_ plan: ComparisonApplyPlan) throws {
        try ComparisonValidation.validateIdentifier(
            plan.pairID,
            name: "Comparison apply pair ID"
        )
        guard plan.pairID.hasPrefix("urn:margin:comparison-pair:"),
              plan.snapshotGeneration >= 0,
              ComparisonValidation.isSHA256(plan.expectedDestinationSHA256),
              !plan.patches.isEmpty else {
            throw ComparisonApplyError.resultDoesNotMatchPair
        }
        var blockIDs = Set<String>()
        for patch in plan.patches {
            guard patch.blockID.hasPrefix("urn:margin:comparison-block:"),
                  patch.blockID.utf8.count <= ComparisonHardLimits.identifierUTF8Bytes else {
                throw ComparisonApplyError.unknownBlock(patch.blockID)
            }
            guard blockIDs.insert(patch.blockID).inserted else {
                throw ComparisonApplyError.duplicateBlock(patch.blockID)
            }
            guard !patch.replacement.utf8.contains(0) else {
                throw ComparisonError.invalidSnapshot(
                    "Comparison apply replacements cannot contain NUL bytes."
                )
            }
        }
        try validateNonoverlapping(plan.patches)
    }

    private func validateNonoverlapping(_ patches: [ComparisonApplyPatch]) throws {
        var nextStart = Int.max
        var previousStart: Int?
        for patch in patches {
            let start = patch.destination.utf8ByteStart
            let (end, overflow) = start.addingReportingOverflow(
                patch.destination.utf8ByteLength
            )
            guard start >= 0, !overflow, end >= start,
                  end <= nextStart, previousStart != start else {
                throw ComparisonApplyError.overlappingBlocks
            }
            nextStart = start
            previousStart = start
        }
    }

    private static func leadingBOM(in data: Data) -> Data {
        let bom = Data([0xef, 0xbb, 0xbf])
        return data.starts(with: bom) ? bom : Data()
    }
}
