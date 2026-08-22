import Foundation

private extension CodingUserInfoKey {
    static let comparisonReviewPrevalidated = CodingUserInfoKey(
        rawValue: "ink.margin.comparison-review.prevalidated"
    )!
}

public enum ComparisonReviewSide: String, Codable, Sendable {
    case left
    case right
    case pair
}

public enum ComparisonReviewAnchorState: String, Codable, Sendable {
    case resolved
    case moved
    case ambiguous
    case orphaned
    case historical
}

/// Internal, deterministic evidence that review validation materializes each
/// current snapshot projection once rather than once per annotation. Tests use
/// these counts instead of wall-clock thresholds.
struct ComparisonReviewValidationMetrics: Equatable {
    var snapshotProjectionsBuilt = 0
    var snapshotScalarsMaterialized = 0
    var anchorsChecked = 0
    var exactScalarsCompared = 0
}

struct ComparisonReviewTextProjection {
    let snapshotSHA256: String
    let text: String
    let scalars: [Unicode.Scalar]
    private let graphemeBoundaries: [Bool]?

    init(snapshot: ComparisonSnapshot, preparesSelectionTargets: Bool = false) {
        snapshotSHA256 = snapshot.sha256
        text = AnchorResolver.normalizedProjection(snapshot.content)
        scalars = Array(text.unicodeScalars)
        graphemeBoundaries = preparesSelectionTargets
            ? Self.makeGraphemeBoundaries(in: text, scalarCount: scalars.count)
            : nil
    }

    init(
        markdown: String,
        snapshotSHA256: String = "",
        preparesSelectionTargets: Bool = true
    ) {
        self.snapshotSHA256 = snapshotSHA256
        text = AnchorResolver.normalizedProjection(markdown)
        scalars = Array(text.unicodeScalars)
        graphemeBoundaries = preparesSelectionTargets
            ? Self.makeGraphemeBoundaries(in: text, scalarCount: scalars.count)
            : nil
    }

    func exactMatches(
        _ quote: TextQuoteSelector,
        at position: TextPositionSelector,
        metrics: inout ComparisonReviewValidationMetrics
    ) -> Bool {
        guard position.start >= 0,
              position.end > position.start,
              position.end <= scalars.count else { return false }
        let exact = Array(AnchorResolver.normalizedProjection(quote.exact).unicodeScalars)
        guard exact.count == position.end - position.start else { return false }
        for offset in exact.indices {
            metrics.exactScalarsCompared += 1
            if scalars[position.start + offset] != exact[offset] { return false }
        }
        return true
    }

    func selectionTarget(
        source: MarginSourceReference,
        start: Int,
        end: Int,
        contextLength: Int = 32
    ) throws -> CommentSelectionTarget {
        guard start >= 0, end > start, end <= scalars.count,
              isGraphemeBoundary(start), isGraphemeBoundary(end) else {
            throw ComparisonError.invalidArtifact(
                "A refreshed review anchor is outside the snapshot or splits a grapheme."
            )
        }
        let exact = string(scalars[start..<end])
        let prefixStart = max(0, start - contextLength)
        let suffixEnd = min(scalars.count, end + contextLength)
        return CommentSelectionTarget(
            source: source,
            selector: [
                .position(TextPositionSelector(start: start, end: end)),
                .quote(TextQuoteSelector(
                    exact: exact,
                    prefix: string(scalars[prefixStart..<start]),
                    suffix: string(scalars[end..<suffixEnd])
                )),
            ]
        )
    }

    private func isGraphemeBoundary(_ offset: Int) -> Bool {
        guard let graphemeBoundaries,
              offset >= 0,
              offset < graphemeBoundaries.count else { return false }
        return graphemeBoundaries[offset]
    }

    private static func makeGraphemeBoundaries(
        in text: String,
        scalarCount: Int
    ) -> [Bool] {
        var boundaries = [Bool](repeating: false, count: scalarCount + 1)
        var scalarOffset = 0
        for character in text {
            boundaries[scalarOffset] = true
            scalarOffset += character.unicodeScalars.count
        }
        boundaries[scalarOffset] = true
        return boundaries
    }

    private func string(_ values: ArraySlice<Unicode.Scalar>) -> String {
        var output = String.UnicodeScalarView()
        output.append(contentsOf: values)
        return String(output)
    }
}

final class ComparisonReviewRefreshWork {
    let limit: Int
    private(set) var comparisons = 0
    let cancellation: ComparisonCancellationToken?
    let resourceName: String

    init(
        limit: Int = ComparisonHardLimits.anchorRefreshScalarComparisons,
        cancellation: ComparisonCancellationToken?,
        resourceName: String = "review anchor refresh scalar comparisons"
    ) {
        self.limit = min(
            max(0, limit),
            ComparisonHardLimits.anchorRefreshScalarComparisons
        )
        self.cancellation = cancellation
        self.resourceName = resourceName
    }

    func compare(_ lhs: Unicode.Scalar, _ rhs: Unicode.Scalar) throws -> Bool {
        let (next, overflow) = comparisons.addingReportingOverflow(1)
        guard !overflow, next <= limit else {
            throw ComparisonError.resourceLimit(
                name: resourceName,
                limit: limit,
                actual: overflow ? Int.max : next
            )
        }
        comparisons = next
        if comparisons & 0xfff == 0, cancellation?.isCancelled == true {
            throw ComparisonError.cancelled
        }
        return lhs == rhs
    }

    func checkCancellation() throws {
        if cancellation?.isCancelled == true { throw ComparisonError.cancelled }
    }
}

struct ComparisonReviewPreparedResolver {
    let projection: ComparisonReviewTextProjection
    let contextLength: Int
    let minimumDisambiguatingContext: Int

    init(
        projection: ComparisonReviewTextProjection,
        contextLength: Int = 32,
        minimumDisambiguatingContext: Int = 8
    ) {
        self.projection = projection
        self.contextLength = max(0, contextLength)
        self.minimumDisambiguatingContext = max(0, minimumDisambiguatingContext)
    }

    func resolve(
        _ selector: CommentSelectionTarget,
        work: ComparisonReviewRefreshWork
    ) throws -> (state: AnchorResolutionState, range: UnicodeScalarRange?) {
        try work.checkCancellation()
        guard let quote = selector.quoteSelector, !quote.exact.isEmpty else {
            throw ComparisonError.invalidArtifact("Review anchors require a non-empty quote.")
        }
        let exact = Array(AnchorResolver.normalizedProjection(quote.exact).unicodeScalars)
        let prefix = Array(AnchorResolver.normalizedProjection(quote.prefix).unicodeScalars)
        let suffix = Array(AnchorResolver.normalizedProjection(quote.suffix).unicodeScalars)
        if let position = selector.positionSelector,
           try exactMatches(exact, at: position, work: work) {
            return (
                .anchored,
                UnicodeScalarRange(start: position.start, end: position.end)
            )
        }

        let prefixTable = try makePrefixTable(exact, work: work)
        var matched = 0
        var occurrenceCount = 0
        var onlyStart: Int?
        var bestStart: Int?
        var bestScore = -1
        var bestCount = 0
        for index in projection.scalars.indices {
            try work.checkCancellationIfNeeded(index)
            while matched > 0,
                  try !work.compare(projection.scalars[index], exact[matched]) {
                matched = prefixTable[matched - 1]
            }
            if try work.compare(projection.scalars[index], exact[matched]) {
                matched += 1
            }
            guard matched == exact.count else { continue }
            let start = index + 1 - exact.count
            occurrenceCount += 1
            if occurrenceCount == 1 { onlyStart = start }
            let end = index + 1
            let score = try matchingPrefixContext(
                prefix,
                before: start,
                work: work
            ) + matchingSuffixContext(
                suffix,
                after: end,
                work: work
            )
            if score > bestScore {
                bestScore = score
                bestStart = start
                bestCount = 1
            } else if score == bestScore {
                bestCount += 1
            }
            matched = prefixTable[matched - 1]
        }
        guard occurrenceCount > 0 else { return (.orphaned, nil) }
        if occurrenceCount == 1, let onlyStart {
            return (
                .moved,
                UnicodeScalarRange(start: onlyStart, end: onlyStart + exact.count)
            )
        }
        let threshold = min(minimumDisambiguatingContext, prefix.count + suffix.count)
        if bestCount == 1, bestScore >= threshold, threshold > 0, let bestStart {
            return (
                .moved,
                UnicodeScalarRange(start: bestStart, end: bestStart + exact.count)
            )
        }
        return (.ambiguous, nil)
    }

    private func exactMatches(
        _ exact: [Unicode.Scalar],
        at position: TextPositionSelector,
        work: ComparisonReviewRefreshWork
    ) throws -> Bool {
        guard position.start >= 0,
              position.end > position.start,
              position.end <= projection.scalars.count,
              position.end - position.start == exact.count else { return false }
        for offset in exact.indices {
            if try !work.compare(projection.scalars[position.start + offset], exact[offset]) {
                return false
            }
        }
        return true
    }

    private func makePrefixTable(
        _ pattern: [Unicode.Scalar],
        work: ComparisonReviewRefreshWork
    ) throws -> [Int] {
        guard !pattern.isEmpty else { return [] }
        var table = [Int](repeating: 0, count: pattern.count)
        var matched = 0
        if pattern.count > 1 {
            for index in 1..<pattern.count {
                while matched > 0, try !work.compare(pattern[index], pattern[matched]) {
                    matched = table[matched - 1]
                }
                if try work.compare(pattern[index], pattern[matched]) { matched += 1 }
                table[index] = matched
            }
        }
        return table
    }

    private func matchingPrefixContext(
        _ prefix: [Unicode.Scalar],
        before start: Int,
        work: ComparisonReviewRefreshWork
    ) throws -> Int {
        let possible = min(prefix.count, start)
        guard possible > 0 else { return 0 }
        var matched = 0
        while matched < possible,
              try work.compare(
                prefix[prefix.count - 1 - matched],
                projection.scalars[start - 1 - matched]
              ) {
            matched += 1
        }
        return matched
    }

    private func matchingSuffixContext(
        _ suffix: [Unicode.Scalar],
        after end: Int,
        work: ComparisonReviewRefreshWork
    ) throws -> Int {
        let possible = min(suffix.count, projection.scalars.count - end)
        guard possible > 0 else { return 0 }
        var matched = 0
        while matched < possible,
              try work.compare(suffix[matched], projection.scalars[end + matched]) {
            matched += 1
        }
        return matched
    }
}

private extension ComparisonReviewRefreshWork {
    func checkCancellationIfNeeded(_ index: Int) throws {
        if index & 0xfff == 0 { try checkCancellation() }
    }
}

/// A quote selector bound to the exact snapshot digest against which it was
/// resolved. Positions use Margin's half-open, normalized Markdown
/// Unicode-scalar projection; they are never unlabeled byte coordinates.
public struct ComparisonReviewAnchor: Codable, Hashable, Sendable {
    public var snapshotSHA256: String
    public var selector: CommentSelectionTarget
    public var state: ComparisonReviewAnchorState
    public var extensions: [String: JSONValue]

    public init(
        snapshotSHA256: String,
        selector: CommentSelectionTarget,
        state: ComparisonReviewAnchorState = .resolved,
        extensions: [String: JSONValue] = [:]
    ) throws {
        guard ComparisonValidation.isSHA256(snapshotSHA256) else {
            throw ComparisonError.invalidArtifact("Review anchor has an invalid snapshot digest.")
        }
        guard selector.quoteSelector != nil else {
            throw ComparisonError.invalidArtifact("Review anchors require a TextQuoteSelector.")
        }
        self.snapshotSHA256 = snapshotSHA256
        self.selector = selector
        self.state = state
        self.extensions = extensions
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: ComparisonHardLimits.extensionJSONBytes
        )
    }

    public init(
        snapshot: ComparisonSnapshot,
        input: CommentAnchorInput,
        resolver: AnchorResolver = AnchorResolver(),
        extensions: [String: JSONValue] = [:]
    ) throws {
        let target: CommentTarget
        do {
            target = try resolver.target(
                for: input,
                documentID: Self.sourceID(for: snapshot.sha256),
                in: snapshot.content
            )
        } catch {
            throw ComparisonError.invalidArtifact(error.localizedDescription)
        }
        guard case .selection(let selection) = target else {
            throw ComparisonError.invalidArtifact("Comparison review comments require a text selection.")
        }
        try self.init(
            snapshotSHA256: snapshot.sha256,
            selector: selection,
            extensions: extensions
        )
    }

    public static func sourceID(for digest: String) -> String {
        "urn:sha256:\(digest)"
    }

    fileprivate func validated(
        against projection: ComparisonReviewTextProjection?,
        metrics: inout ComparisonReviewValidationMetrics
    ) throws {
        guard ComparisonValidation.isSHA256(snapshotSHA256),
              selector.type == "SpecificResource",
              selector.source.id == Self.sourceID(for: snapshotSHA256),
              selector.source.format == "text/markdown",
              selector.selector.count == 2,
              selector.selector.filter({
                  if case .position = $0 { return true }
                  return false
              }).count == 1,
              selector.selector.filter({
                  if case .quote = $0 { return true }
                  return false
              }).count == 1,
              let quote = selector.quoteSelector,
              quote.type == "TextQuoteSelector",
              !quote.exact.isEmpty,
              quote.exact.utf8.count <= ComparisonHardLimits.snapshotUTF8Bytes,
              quote.prefix.unicodeScalars.count <= ComparisonHardLimits.anchorContextUnicodeScalars,
              quote.suffix.unicodeScalars.count <= ComparisonHardLimits.anchorContextUnicodeScalars else {
            throw ComparisonError.invalidArtifact("Review anchor source, digest, or quote is invalid.")
        }
        metrics.anchorsChecked += 1
        guard let position = selector.positionSelector,
              position.type == "TextPositionSelector" else {
            throw ComparisonError.invalidArtifact("Review anchors require one position selector.")
        }
        guard position.start >= 0,
              position.end > position.start,
              position.end <= ComparisonHardLimits.snapshotUTF8Bytes else {
                throw ComparisonError.invalidArtifact("Review anchor position is not a non-empty half-open range.")
        }
        guard let projection else {
            guard state != .resolved, state != .moved else {
                throw ComparisonError.invalidArtifact(
                    "A resolved review anchor must reference a current snapshot."
                )
            }
            return
        }
        guard projection.snapshotSHA256 == snapshotSHA256 else {
            throw ComparisonError.invalidArtifact("Review anchor digest does not match its snapshot.")
        }
        switch state {
        case .resolved, .moved:
            guard projection.exactMatches(quote, at: position, metrics: &metrics) else {
                throw ComparisonError.invalidArtifact(
                    "Resolved review anchor does not match its stored quote and position."
                )
            }
        case .ambiguous, .orphaned, .historical:
            // These are bounded declarations of evidence. Re-running a global
            // quote search while decoding an untrusted artifact would make
            // load cost proportional to snapshot size times annotation count.
            break
        }
    }

    fileprivate func refreshed(
        from oldSnapshot: ComparisonSnapshot,
        to newSnapshot: ComparisonSnapshot,
        isOpen: Bool,
        resolver: ComparisonReviewPreparedResolver,
        work: ComparisonReviewRefreshWork
    ) throws -> ComparisonReviewAnchor {
        guard oldSnapshot.sha256 != newSnapshot.sha256 else { return self }
        var output = self
        guard isOpen else {
            output.state = .historical
            return output
        }
        let source = MarginSourceReference(id: Self.sourceID(for: newSnapshot.sha256))
        let candidate = CommentSelectionTarget(
            source: source,
            selector: selector.selector
        )
        do {
            let resolution = try resolver.resolve(candidate, work: work)
            switch resolution.state {
            case .anchored, .moved:
                guard let range = resolution.range else {
                    output.state = .orphaned
                    return output
                }
                let refreshed = try resolver.projection.selectionTarget(
                    source: source,
                    start: range.start,
                    end: range.end,
                    contextLength: resolver.contextLength
                )
                output.snapshotSHA256 = newSnapshot.sha256
                output.selector = refreshed
                output.state = resolution.state == .anchored ? .resolved : .moved
            case .ambiguous:
                output.state = .ambiguous
            case .orphaned:
                output.state = .orphaned
            }
        } catch let error as ComparisonError {
            switch error {
            case .cancelled, .resourceLimit:
                throw error
            default:
                output.state = .orphaned
            }
        } catch {
            output.state = .orphaned
        }
        return output
    }
}

public struct ComparisonReviewTarget: Codable, Hashable, Sendable {
    public var side: ComparisonReviewSide
    public var left: ComparisonReviewAnchor?
    public var right: ComparisonReviewAnchor?
    public var changedBlockID: String?
    public var extensions: [String: JSONValue]

    public init(
        side: ComparisonReviewSide,
        left: ComparisonReviewAnchor? = nil,
        right: ComparisonReviewAnchor? = nil,
        changedBlockID: String? = nil,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.side = side
        self.left = left
        self.right = right
        self.changedBlockID = changedBlockID
        self.extensions = extensions
        try validateShape()
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: ComparisonHardLimits.extensionJSONBytes
        )
    }

    fileprivate func validated(
        leftProjection: ComparisonReviewTextProjection?,
        rightProjection: ComparisonReviewTextProjection?,
        metrics: inout ComparisonReviewValidationMetrics
    ) throws {
        try validateShape()
        try left?.validated(
            against: projection(for: left, current: leftProjection),
            metrics: &metrics
        )
        try right?.validated(
            against: projection(for: right, current: rightProjection),
            metrics: &metrics
        )
    }

    fileprivate mutating func refresh(
        from old: ComparisonSnapshotPair,
        to new: ComparisonSnapshotPair,
        isOpen: Bool,
        leftResolver: ComparisonReviewPreparedResolver,
        rightResolver: ComparisonReviewPreparedResolver,
        work: ComparisonReviewRefreshWork
    ) throws {
        if let anchor = left {
            left = try anchor.refreshed(
                from: old.left,
                to: new.left,
                isOpen: isOpen,
                resolver: leftResolver,
                work: work
            )
        }
        if let anchor = right {
            right = try anchor.refreshed(
                from: old.right,
                to: new.right,
                isOpen: isOpen,
                resolver: rightResolver,
                work: work
            )
        }
        // A block ID belongs only to its exact old pair. Reattachment requires
        // an explicit later comparison; never silently reuse the old identity.
        if old.id != new.id { changedBlockID = nil }
    }

    private func projection(
        for anchor: ComparisonReviewAnchor?,
        current: ComparisonReviewTextProjection?
    ) -> ComparisonReviewTextProjection? {
        guard let anchor, let current,
              anchor.snapshotSHA256 == current.snapshotSHA256 else { return nil }
        return current
    }

    private func validateShape() throws {
        switch side {
        case .left:
            guard left != nil, right == nil else {
                throw ComparisonError.invalidArtifact("A left target must contain only a left anchor.")
            }
        case .right:
            guard right != nil, left == nil else {
                throw ComparisonError.invalidArtifact("A right target must contain only a right anchor.")
            }
        case .pair:
            guard left != nil, right != nil else {
                throw ComparisonError.invalidArtifact("A pair target requires both anchors.")
            }
        }
        if let changedBlockID,
           !changedBlockID.hasPrefix("urn:margin:comparison-block:")
            || changedBlockID.utf8.count > ComparisonHardLimits.identifierUTF8Bytes {
            throw ComparisonError.invalidArtifact("Changed-block ID is invalid.")
        }
    }
}

public struct ComparisonReviewComment: Codable, Hashable, Sendable {
    public var id: String
    public var parentID: String?
    public var creator: MarginActor
    public var created: String
    public var modified: String
    public var body: MarginCommentBody
    public var extensions: [String: JSONValue]

    public init(
        id: String,
        parentID: String? = nil,
        creator: MarginActor,
        created: String,
        modified: String,
        body: MarginCommentBody,
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        self.parentID = parentID
        self.creator = creator
        self.created = created
        self.modified = modified
        self.body = body
        self.extensions = extensions
        try validate(limits: .default)
    }

    func validate(limits: ComparisonLimits) throws {
        try ComparisonValidation.validateIdentifier(id, name: "Review comment ID")
        if let parentID {
            try ComparisonValidation.validateIdentifier(parentID, name: "Review comment parent ID")
        }
        try ComparisonValidation.validateActor(creator, name: "Review comment creator")
        guard ComparisonValidation.isTimestamp(created),
              ComparisonValidation.isTimestamp(modified),
              !body.value.isEmpty,
              body.value.utf8.count <= limits.maxCommentBodyUTF8Bytes,
              body.format == "text/markdown" else {
            throw ComparisonError.invalidArtifact("Review comment provenance or Markdown body is invalid.")
        }
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
    }
}

public struct ComparisonReviewThread: Codable, Hashable, Sendable {
    public var id: String
    public var target: ComparisonReviewTarget
    public var status: MarginCommentStatus
    public var statusModified: String
    public var statusModifiedBy: MarginActor
    public var comments: [ComparisonReviewComment]
    public var extensions: [String: JSONValue]

    public init(
        id: String,
        target: ComparisonReviewTarget,
        status: MarginCommentStatus = .open,
        statusModified: String,
        statusModifiedBy: MarginActor,
        comments: [ComparisonReviewComment],
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        self.target = target
        self.status = status
        self.statusModified = statusModified
        self.statusModifiedBy = statusModifiedBy
        self.comments = comments
        self.extensions = extensions
        try validateGraph(limits: .default)
    }

    /// ID-idempotent reply insertion. An identical retry is a no-op; reuse of
    /// the ID for different content fails closed.
    @discardableResult
    public mutating func add(_ comment: ComparisonReviewComment) throws -> Bool {
        if let existing = comments.first(where: { $0.id == comment.id }) {
            guard existing == comment else { throw ComparisonError.idConflict(comment.id) }
            return false
        }
        guard status == .open else {
            throw ComparisonError.invalidArtifact("Cannot reply to a resolved comparison thread.")
        }
        comments.append(comment)
        do {
            try validateGraph(limits: .default)
        } catch {
            comments.removeLast()
            throw error
        }
        return true
    }

    @discardableResult
    public mutating func setStatus(
        _ status: MarginCommentStatus,
        modified: String,
        actor: MarginActor
    ) throws -> Bool {
        try ComparisonValidation.validateActor(actor, name: "Thread status modifier")
        guard ComparisonValidation.isTimestamp(modified) else {
            throw ComparisonError.invalidArtifact("Thread status timestamp is not ISO 8601.")
        }
        guard self.status != status else { return false }
        self.status = status
        statusModified = modified
        statusModifiedBy = actor
        return true
    }

    func validateGraph(limits: ComparisonLimits) throws {
        try ComparisonValidation.validateIdentifier(id, name: "Review thread ID")
        try ComparisonValidation.validateActor(statusModifiedBy, name: "Thread status modifier")
        guard ComparisonValidation.isTimestamp(statusModified),
              !comments.isEmpty,
              comments.count <= limits.maxCommentsPerThread else {
            throw ComparisonError.invalidArtifact("Review thread provenance or comment count is invalid.")
        }
        for comment in comments { try comment.validate(limits: limits) }
        let grouped = Dictionary(grouping: comments, by: \.id)
        guard grouped.count == comments.count else {
            throw ComparisonError.invalidArtifact("Review thread contains duplicate comment IDs.")
        }
        let roots = comments.filter { $0.parentID == nil }
        guard roots.count == 1, roots[0].id == id else {
            throw ComparisonError.invalidArtifact("Review thread requires one root whose ID is the thread ID.")
        }
        let ids = Set(comments.map(\.id))
        for comment in comments {
            if let parent = comment.parentID {
                guard parent != comment.id, ids.contains(parent) else {
                    throw ComparisonError.invalidArtifact("Review comment parent is missing or self-referential.")
                }
            }
        }
        var visited = Set<String>()
        var active = Set<String>()
        func visit(_ id: String, depth: Int) throws {
            guard depth <= ComparisonHardLimits.replyDepth else {
                throw ComparisonError.resourceLimit(
                    name: "review reply depth",
                    limit: ComparisonHardLimits.replyDepth,
                    actual: depth
                )
            }
            guard !active.contains(id) else {
                throw ComparisonError.invalidArtifact("Review comment graph contains a cycle.")
            }
            guard visited.insert(id).inserted else { return }
            active.insert(id)
            for child in comments where child.parentID == id {
                try visit(child.id, depth: depth + 1)
            }
            active.remove(id)
        }
        try visit(self.id, depth: 0)
        guard visited.count == comments.count else {
            throw ComparisonError.invalidArtifact("Review comment graph is disconnected.")
        }
        try ComparisonValidation.validateExtensionBytes(
            extensions,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
    }
}

public enum ComparisonReviewLayout: String, Codable, Sendable {
    case inline
    case sideBySide
}

public struct ComparisonReviewDisplayOptions: Codable, Hashable, Sendable {
    public var layout: ComparisonReviewLayout
    public var showWhitespace: Bool
    public var contextLines: Int
    public var extensions: [String: JSONValue]

    public init(
        layout: ComparisonReviewLayout = .inline,
        showWhitespace: Bool = false,
        contextLines: Int = 3,
        extensions: [String: JSONValue] = [:]
    ) {
        self.layout = layout
        self.showWhitespace = showWhitespace
        self.contextLines = min(max(0, contextLines), 1_000)
        self.extensions = extensions
    }
}

public struct ComparisonReview: Codable, Hashable, Sendable {
    public static let schema = "urn:margin:comparison-review:v1"
    public static let version = 1

    public let id: String
    public private(set) var revision: Int
    public let created: String
    public private(set) var modified: String
    public private(set) var snapshots: ComparisonSnapshotPair
    public var display: ComparisonReviewDisplayOptions
    public var threads: [ComparisonReviewThread]
    public var extensions: [String: JSONValue]
    public var unknownFields: [String: JSONValue]

    public init(
        id: String,
        created: String,
        modified: String,
        snapshots: ComparisonSnapshotPair,
        display: ComparisonReviewDisplayOptions = ComparisonReviewDisplayOptions(),
        threads: [ComparisonReviewThread] = [],
        extensions: [String: JSONValue] = [:]
    ) throws {
        self.id = id
        revision = 0
        self.created = created
        self.modified = modified
        self.snapshots = snapshots
        self.display = display
        self.threads = threads
        self.extensions = extensions
        unknownFields = [:]
        try validate()
    }

    @discardableResult
    public mutating func addThread(_ thread: ComparisonReviewThread) throws -> Bool {
        if let existing = threads.first(where: { $0.id == thread.id }) {
            guard existing == thread else { throw ComparisonError.idConflict(thread.id) }
            return false
        }
        let existingCommentIDs = Set(threads.flatMap(\.comments).map(\.id))
        guard existingCommentIDs.isDisjoint(with: thread.comments.map(\.id)) else {
            throw ComparisonError.idConflict(thread.id)
        }
        threads.append(thread)
        do {
            try validate()
        } catch {
            threads.removeLast()
            throw error
        }
        return true
    }

    @discardableResult
    public mutating func addComment(
        _ comment: ComparisonReviewComment,
        to threadID: String
    ) throws -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw ComparisonError.invalidArtifact("Comparison thread '\(threadID)' was not found.")
        }
        if let existing = threads.flatMap(\.comments).first(where: { $0.id == comment.id }) {
            guard existing == comment,
                  threads[index].comments.contains(existing) else {
                throw ComparisonError.idConflict(comment.id)
            }
            return false
        }
        var candidate = self
        let changed = try candidate.threads[index].add(comment)
        try candidate.validate()
        self = candidate
        return changed
    }

    @discardableResult
    public mutating func setThreadStatus(
        _ status: MarginCommentStatus,
        threadID: String,
        modified: String,
        actor: MarginActor
    ) throws -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw ComparisonError.invalidArtifact("Comparison thread '\(threadID)' was not found.")
        }
        var candidate = self
        let changed = try candidate.threads[index].setStatus(
            status,
            modified: modified,
            actor: actor
        )
        try candidate.validate()
        self = candidate
        return changed
    }

    /// Explicitly advances snapshot generation and re-resolves open quotes.
    /// Ambiguous/orphaned anchors retain their old digest and words rather than
    /// silently attaching to different text.
    public mutating func refreshSnapshots(
        _ newSnapshots: ComparisonSnapshotPair,
        modified: String,
        cancellation: ComparisonCancellationToken? = nil,
        maximumScalarComparisons: Int = ComparisonHardLimits.anchorRefreshScalarComparisons
    ) throws {
        let (expectedGeneration, overflow) = snapshots.generation.addingReportingOverflow(1)
        guard !overflow, newSnapshots.generation == expectedGeneration else {
            throw ComparisonError.invalidArtifact(
                "A refresh must advance snapshot generation by exactly one."
            )
        }
        var candidate = self
        let old = candidate.snapshots
        let work = ComparisonReviewRefreshWork(
            limit: min(
                max(0, maximumScalarComparisons),
                ComparisonHardLimits.anchorRefreshScalarComparisons
            ),
            cancellation: cancellation
        )
        let leftResolver = ComparisonReviewPreparedResolver(
            projection: ComparisonReviewTextProjection(
                snapshot: newSnapshots.left,
                preparesSelectionTargets: true
            )
        )
        let rightResolver = ComparisonReviewPreparedResolver(
            projection: ComparisonReviewTextProjection(
                snapshot: newSnapshots.right,
                preparesSelectionTargets: true
            )
        )
        for index in candidate.threads.indices {
            try work.checkCancellation()
            try candidate.threads[index].target.refresh(
                from: old,
                to: newSnapshots,
                isOpen: candidate.threads[index].status == .open,
                leftResolver: leftResolver,
                rightResolver: rightResolver,
                work: work
            )
        }
        candidate.snapshots = newSnapshots
        candidate.modified = modified
        try candidate.validate()
        self = candidate
    }

    public func validate(limits: ComparisonLimits = .default) throws {
        _ = try validationMetrics(limits: limits)
    }

    /// Internal deterministic accounting for adversarial validation tests.
    /// Counts describe bounded projection and exact-position work, not time.
    func validationMetrics(
        limits: ComparisonLimits = .default
    ) throws -> ComparisonReviewValidationMetrics {
        var metrics = ComparisonReviewValidationMetrics()
        try ComparisonValidation.validateIdentifier(id, name: "Comparison review ID")
        guard revision >= 0,
              ComparisonValidation.isTimestamp(created),
              ComparisonValidation.isTimestamp(modified) else {
            throw ComparisonError.invalidArtifact("Review revision or timestamps are invalid.")
        }
        guard threads.count <= limits.maxThreads else {
            throw ComparisonError.resourceLimit(
                name: "review threads",
                limit: limits.maxThreads,
                actual: threads.count
            )
        }
        try snapshots.left.validate(limits: limits)
        try snapshots.right.validate(limits: limits)
        let needsLeftProjection = threads.contains {
            $0.target.left?.snapshotSHA256 == snapshots.left.sha256
        }
        let needsRightProjection = threads.contains {
            $0.target.right?.snapshotSHA256 == snapshots.right.sha256
        }
        let leftProjection = needsLeftProjection
            ? ComparisonReviewTextProjection(snapshot: snapshots.left)
            : nil
        let rightProjection = needsRightProjection
            ? ComparisonReviewTextProjection(snapshot: snapshots.right)
            : nil
        metrics.snapshotProjectionsBuilt = (leftProjection == nil ? 0 : 1)
            + (rightProjection == nil ? 0 : 1)
        metrics.snapshotScalarsMaterialized = (leftProjection?.scalars.count ?? 0)
            + (rightProjection?.scalars.count ?? 0)
        let commentCount = threads.reduce(0) { $0 + $1.comments.count }
        guard commentCount <= limits.maxTotalComments else {
            throw ComparisonError.resourceLimit(
                name: "review comments",
                limit: limits.maxTotalComments,
                actual: commentCount
            )
        }
        let threadIDs = threads.map(\.id)
        guard Set(threadIDs).count == threadIDs.count else {
            throw ComparisonError.invalidArtifact("Comparison review contains duplicate thread IDs.")
        }
        let allCommentIDs = threads.flatMap(\.comments).map(\.id)
        guard Set(allCommentIDs).count == allCommentIDs.count else {
            throw ComparisonError.invalidArtifact("Comparison review contains duplicate comment IDs.")
        }
        for thread in threads {
            try thread.validateGraph(limits: limits)
            try thread.target.validated(
                leftProjection: leftProjection,
                rightProjection: rightProjection,
                metrics: &metrics
            )
        }
        guard display.contextLines >= 0, display.contextLines <= 1_000 else {
            throw ComparisonError.invalidArtifact("Display context-line count is invalid.")
        }
        try ComparisonValidation.validateExtensionBytes(
            display.extensions,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
        try validateAggregateExtensions(limits: limits)
        return metrics
    }

    mutating func preparePersistenceRevision(_ revision: Int, modified: String) throws {
        guard revision >= 0 else {
            throw ComparisonError.invalidArtifact("Review revision cannot be negative.")
        }
        self.revision = revision
        self.modified = modified
        try validate()
    }

    private func validateAggregateExtensions(limits: ComparisonLimits) throws {
        let values: [[String: JSONValue]] = [
            extensions,
            unknownFields,
            snapshots.extensions,
            snapshots.left.extensions,
            snapshots.left.unknownFields,
            snapshots.right.extensions,
            snapshots.right.unknownFields,
            display.extensions,
        ] + threads.flatMap { thread in
            [thread.extensions, thread.target.extensions]
                + [thread.target.left, thread.target.right].compactMap { $0 }.map {
                    $0.extensions
                }
                + thread.comments.map(\.extensions)
        }
        let nonempty = values.filter { !$0.isEmpty }
        let data = try JSONEncoder().encode(nonempty)
        guard data.count <= limits.maxExtensionJSONBytes else {
            throw ComparisonError.resourceLimit(
                name: "aggregate extension JSON bytes",
                limit: limits.maxExtensionJSONBytes,
                actual: data.count
            )
        }
        var combined: [String: JSONValue] = [:]
        for (index, value) in nonempty.enumerated() {
            for (name, nested) in value {
                combined["\(index):\(name)"] = nested
            }
        }
        try ComparisonValidation.validateExtensionBytes(
            combined,
            maximum: limits.maxExtensionJSONBytes,
            maximumKeys: limits.maxExtensionKeys,
            maximumDepth: limits.maxExtensionNestingDepth
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, version, id, revision, created, modified, snapshots, display, threads, extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        let schema = try container.decode(String.self, forKey: key("schema"))
        guard schema == Self.schema else { throw ComparisonError.unsupportedSchema(schema) }
        let version = try container.decode(Int.self, forKey: key("version"))
        guard version == Self.version else {
            throw ComparisonError.unsupportedSchema("\(schema)#version=\(version)")
        }
        id = try container.decode(String.self, forKey: key("id"))
        revision = try container.decode(Int.self, forKey: key("revision"))
        created = try container.decode(String.self, forKey: key("created"))
        modified = try container.decode(String.self, forKey: key("modified"))
        snapshots = try container.decode(ComparisonSnapshotPair.self, forKey: key("snapshots"))
        display = try container.decode(ComparisonReviewDisplayOptions.self, forKey: key("display"))
        threads = try container.decode([ComparisonReviewThread].self, forKey: key("threads"))
        extensions = try container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: key("extensions")
        ) ?? [:]
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var unknown: [String: JSONValue] = [:]
        for codingKey in container.allKeys where !known.contains(codingKey.stringValue) {
            unknown[codingKey.stringValue] = try container.decode(JSONValue.self, forKey: codingKey)
        }
        unknownFields = unknown
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        if encoder.userInfo[.comparisonReviewPrevalidated] as? Bool != true {
            try validate()
        }
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ value: String) -> DynamicCodingKey { DynamicCodingKey(stringValue: value)! }
        try container.encode(Self.schema, forKey: key("schema"))
        try container.encode(Self.version, forKey: key("version"))
        try container.encode(id, forKey: key("id"))
        try container.encode(revision, forKey: key("revision"))
        try container.encode(created, forKey: key("created"))
        try container.encode(modified, forKey: key("modified"))
        try container.encode(snapshots, forKey: key("snapshots"))
        try container.encode(display, forKey: key("display"))
        try container.encode(threads, forKey: key("threads"))
        if !extensions.isEmpty { try container.encode(extensions, forKey: key("extensions")) }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for (name, value) in unknownFields where !known.contains(name) {
            try container.encode(value, forKey: key(name))
        }
    }
}

public enum ComparisonReviewCodec {
    public static func encode(
        _ review: ComparisonReview,
        limits: ComparisonLimits = .default
    ) throws -> Data {
        try review.validate(limits: limits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[.comparisonReviewPrevalidated] = true
        let data: Data
        do {
            data = try encoder.encode(review)
        } catch let error as ComparisonError {
            throw error
        } catch {
            throw ComparisonError.invalidArtifact(error.localizedDescription)
        }
        guard data.count <= limits.maxArtifactBytes else {
            throw ComparisonError.resourceLimit(
                name: "comparison review artifact bytes",
                limit: limits.maxArtifactBytes,
                actual: data.count
            )
        }
        return data
    }

    public static func decode(
        _ data: Data,
        limits: ComparisonLimits = .default
    ) throws -> ComparisonReview {
        try ComparisonJSONPreflight.validate(data, maximumBytes: limits.maxArtifactBytes)
        do {
            let review = try JSONDecoder().decode(ComparisonReview.self, from: data)
            // `ComparisonReview.init(from:)` already performs default-limit
            // validation. Re-run only for a caller's stricter policy.
            if limits != .default { try review.validate(limits: limits) }
            return review
        } catch let error as ComparisonError {
            throw error
        } catch {
            throw ComparisonError.invalidArtifact(error.localizedDescription)
        }
    }
}
