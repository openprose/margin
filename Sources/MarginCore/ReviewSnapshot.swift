import Foundation

/// Hard ceilings for the machine-facing projection. `ReviewLimits` can make a
/// response smaller, but never larger than these values. String limits count
/// UTF-8 bytes and truncation always stops on a Unicode-scalar boundary.
enum ReviewProjectionBounds {
    static let maximumHeadings = 96
    static let maximumThreads = 48
    static let maximumCommentsPerThread = 8
    static let maximumBodyUnicodeScalars = 512
    static let maximumExcerptUnicodeScalars = 512
    static let maximumContextUnicodeScalars = 96
    static let maximumHeadingTitleUnicodeScalars = 256

    static let pathUTF8Bytes = 4_096
    static let identifierUTF8Bytes = 512
    static let actorNameUTF8Bytes = 512
    static let timestampUTF8Bytes = 128
    static let headingTitleUTF8Bytes = 1_024
    static let bodyUTF8Bytes = 2_048
    static let excerptUTF8Bytes = 2_048
}

public struct ReviewLimits: Codable, Hashable, Sendable {
    public var maxHeadings: Int
    public var maxThreads: Int
    public var maxCommentsPerThread: Int
    public var maxBodyUnicodeScalars: Int
    public var maxExcerptUnicodeScalars: Int
    public var contextUnicodeScalars: Int
    public var maxHeadingTitleUnicodeScalars: Int

    public init(
        maxHeadings: Int = 96,
        maxThreads: Int = 48,
        maxCommentsPerThread: Int = 8,
        maxBodyUnicodeScalars: Int = 512,
        maxExcerptUnicodeScalars: Int = 512,
        contextUnicodeScalars: Int = 96,
        maxHeadingTitleUnicodeScalars: Int = 256
    ) {
        self.maxHeadings = min(max(0, maxHeadings), ReviewProjectionBounds.maximumHeadings)
        self.maxThreads = min(max(0, maxThreads), ReviewProjectionBounds.maximumThreads)
        self.maxCommentsPerThread = min(
            max(1, maxCommentsPerThread),
            ReviewProjectionBounds.maximumCommentsPerThread
        )
        self.maxBodyUnicodeScalars = min(
            max(0, maxBodyUnicodeScalars),
            ReviewProjectionBounds.maximumBodyUnicodeScalars
        )
        self.maxExcerptUnicodeScalars = min(
            max(1, maxExcerptUnicodeScalars),
            ReviewProjectionBounds.maximumExcerptUnicodeScalars
        )
        self.contextUnicodeScalars = min(
            max(0, contextUnicodeScalars),
            ReviewProjectionBounds.maximumContextUnicodeScalars,
            max(1, maxExcerptUnicodeScalars) / 2
        )
        self.maxHeadingTitleUnicodeScalars = min(
            max(0, maxHeadingTitleUnicodeScalars),
            ReviewProjectionBounds.maximumHeadingTitleUnicodeScalars
        )
    }

    public static let `default` = ReviewLimits()
}

public enum ReviewChange: String, Codable, Sendable {
    case snapshot
    case advanced
    case reset
    case notModified
}

public struct ReviewCollection<Element: Codable & Sendable>: Codable, Sendable {
    public var items: [Element]
    public var total: Int
    public var included: Int
    public var omitted: Int
    public var truncated: Bool

    public init(items: [Element], total: Int) {
        self.items = items
        self.total = max(0, total)
        included = items.count
        omitted = max(0, total - items.count)
        truncated = omitted > 0
    }
}

public struct ReviewDocumentSummary: Codable, Sendable {
    public var path: String
    public var id: String?
    public var protocolVersion: Int?
    public var revision: Int
    public var contentSha256: String
    public var contentBytes: Int
    public var unicodeScalars: Int
    public var lines: Int

    public init(
        path: String,
        id: String?,
        protocolVersion: Int?,
        revision: Int,
        contentSha256: String,
        contentBytes: Int,
        unicodeScalars: Int,
        lines: Int
    ) {
        self.path = path
        self.id = id
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.contentSha256 = contentSha256
        self.contentBytes = contentBytes
        self.unicodeScalars = unicodeScalars
        self.lines = lines
    }
}

public struct ReviewHeading: Codable, Sendable {
    public var id: String
    public var title: String
    public var titleUnicodeScalars: Int
    public var titleTruncated: Bool
    public var level: Int
    public var line: Int
    public var sectionEndLine: Int
}

public struct ReviewCommentSummary: Codable, Sendable {
    public var id: String
    public var parentID: String?
    public var depth: Int
    public var creator: MarginActor
    public var created: String
    public var modified: String
    public var body: String
    public var bodyUnicodeScalars: Int
    public var bodyTruncated: Bool
}

public struct ReviewExcerpt: Codable, Sendable {
    public var text: String
    public var range: UnicodeScalarRange
    public var selectionInExcerpt: UnicodeScalarRange
    public var prefixTruncated: Bool
    public var selectionTruncated: Bool
    public var suffixTruncated: Bool
}

public struct ReviewAnchorSummary: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case document
        case selection
    }

    public var kind: Kind
    public var state: AnchorResolutionState?
    public var range: UnicodeScalarRange?
    public var candidateCount: Int
    public var excerpt: ReviewExcerpt?
}

public struct ReviewThread: Codable, Sendable {
    public var id: String
    public var status: MarginCommentStatus
    public var anchor: ReviewAnchorSummary
    public var comments: ReviewCollection<ReviewCommentSummary>
}

public struct ReviewThreadGroups: Codable, Sendable {
    public var total: Int
    public var statusOpenTotal: Int
    public var statusResolvedTotal: Int
    public var needsAttentionTotal: Int
    public var open: ReviewCollection<ReviewThread>
    public var resolved: ReviewCollection<ReviewThread>
    public var needsAttention: ReviewCollection<ReviewThread>
}

public struct ReviewTruncation: Codable, Sendable {
    public var isTruncated: Bool
    public var detailsOmittedBecauseNotModified: Bool
    public var limits: ReviewLimits
    public var headingsOmitted: Int
    public var threadsOmitted: Int
    public var commentsOmitted: Int
    public var bodiesTruncated: Int
    public var excerptsTruncated: Int
}

public struct ReviewSnapshot: Codable, Sendable {
    public var change: ReviewChange
    public var sinceRevision: Int?
    public var document: ReviewDocumentSummary
    public var outline: ReviewCollection<ReviewHeading>
    public var threads: ReviewThreadGroups
    public var truncation: ReviewTruncation
}

public struct ReviewService: Sendable {
    public var codec: EmbeddedCommentCodec
    public var commentService: CommentService
    public var store: AtomicDocumentStore
    public var limits: ReviewLimits

    public init(
        codec: EmbeddedCommentCodec = EmbeddedCommentCodec(),
        commentService: CommentService = CommentService(),
        store: AtomicDocumentStore = AtomicDocumentStore(),
        limits: ReviewLimits = .default
    ) {
        self.codec = codec
        self.commentService = commentService
        self.store = store
        self.limits = limits
    }

    public func review(at url: URL, sinceRevision: Int? = nil) throws -> ReviewSnapshot {
        let decoded = try codec.decode(store.read(at: url))
        let comments = try commentService.snapshot(from: decoded)
        let originalPath = url.standardizedFileURL.path
        let projectedPath = Self.boundedText(
            originalPath,
            maxUTF8Bytes: ReviewProjectionBounds.pathUTF8Bytes
        )
        let projectedDocumentID = comments.documentID.map(Self.boundedIdentifier)
        let documentMetadataWasTruncated = projectedPath != originalPath
            || projectedDocumentID != comments.documentID
        let document = ReviewDocumentSummary(
            path: projectedPath,
            id: projectedDocumentID,
            protocolVersion: comments.version,
            revision: comments.revision,
            contentSha256: Self.boundedIdentifier(comments.contentSha256),
            contentBytes: decoded.bodyData.count,
            unicodeScalars: decoded.body.unicodeScalars.count,
            lines: TextCoordinates.lineCount(in: decoded.body)
        )
        let change = change(sinceRevision: sinceRevision, currentRevision: comments.revision)
        if change == .notModified {
            let openTotal = Set(comments.comments.filter { $0.threadStatus == .open }.map(\.rootID)).count
            let resolvedTotal = Set(comments.comments.filter { $0.threadStatus == .resolved }.map(\.rootID)).count
            let roots = comments.comments.filter { $0.depth == 0 }
            let attentionTotal = roots.filter(Self.needsAttention).count
            let emptyThreads = ReviewThreadGroups(
                total: roots.count,
                statusOpenTotal: openTotal,
                statusResolvedTotal: resolvedTotal,
                needsAttentionTotal: attentionTotal,
                open: ReviewCollection(items: [], total: openTotal - roots.filter(Self.needsAttention).filter { $0.threadStatus == .open }.count),
                resolved: ReviewCollection(items: [], total: resolvedTotal - roots.filter(Self.needsAttention).filter { $0.threadStatus == .resolved }.count),
                needsAttention: ReviewCollection(items: [], total: attentionTotal)
            )
            return ReviewSnapshot(
                change: change,
                sinceRevision: sinceRevision,
                document: document,
                outline: ReviewCollection(items: [], total: 0),
                threads: emptyThreads,
                truncation: ReviewTruncation(
                    isTruncated: documentMetadataWasTruncated,
                    detailsOmittedBecauseNotModified: true,
                    limits: limits,
                    headingsOmitted: 0,
                    threadsOmitted: roots.count,
                    commentsOmitted: comments.comments.count,
                    bodiesTruncated: 0,
                    excerptsTruncated: 0
                )
            )
        }

        let markdownOutline = MarkdownOutline(markdown: decoded.body)
        var projectedStringWasTruncated = documentMetadataWasTruncated
        let includedHeadings = markdownOutline.headings.prefix(limits.maxHeadings).map { heading in
            let shortened = Self.prefix(
                heading.title,
                maxScalars: limits.maxHeadingTitleUnicodeScalars,
                maxUTF8Bytes: ReviewProjectionBounds.headingTitleUTF8Bytes
            )
            let projectedID = Self.boundedIdentifier(heading.id)
            projectedStringWasTruncated = projectedStringWasTruncated
                || shortened.truncated
                || projectedID != heading.id
            return ReviewHeading(
                id: projectedID,
                title: shortened.value,
                titleUnicodeScalars: shortened.originalCount,
                titleTruncated: shortened.truncated,
                level: heading.level,
                line: heading.line,
                sectionEndLine: heading.sectionEndLine
            )
        }
        let outline = ReviewCollection(items: Array(includedHeadings), total: markdownOutline.headings.count)

        let roots = comments.comments
            .filter { $0.depth == 0 }
            .sorted(by: Self.commentOrder)
        let byRoot = Dictionary(grouping: comments.comments, by: \.rootID)
        let includedRootIDs = Set(roots.prefix(limits.maxThreads).map(\.rootID))
        var open: [ReviewThread] = []
        var resolved: [ReviewThread] = []
        var attention: [ReviewThread] = []
        var commentsOmitted = comments.comments.filter { !includedRootIDs.contains($0.rootID) }.count
        var bodiesTruncated = 0
        var excerptsTruncated = 0

        for root in roots where includedRootIDs.contains(root.rootID) {
            let values = (byRoot[root.rootID] ?? []).sorted(by: Self.commentOrder)
            let included = values.prefix(limits.maxCommentsPerThread).map { listed -> ReviewCommentSummary in
                let shortened = Self.prefix(
                    listed.annotation.body.value,
                    maxScalars: limits.maxBodyUnicodeScalars,
                    maxUTF8Bytes: ReviewProjectionBounds.bodyUTF8Bytes
                )
                if shortened.truncated { bodiesTruncated += 1 }
                let projectedID = Self.boundedIdentifier(listed.annotation.id)
                let projectedParentID = listed.parentID.map(Self.boundedIdentifier)
                let projectedActor = Self.boundedActor(listed.annotation.creator)
                let projectedCreated = Self.boundedText(
                    listed.annotation.created,
                    maxUTF8Bytes: ReviewProjectionBounds.timestampUTF8Bytes
                )
                let projectedModified = Self.boundedText(
                    listed.annotation.modified,
                    maxUTF8Bytes: ReviewProjectionBounds.timestampUTF8Bytes
                )
                projectedStringWasTruncated = projectedStringWasTruncated
                    || projectedID != listed.annotation.id
                    || projectedParentID != listed.parentID
                    || projectedActor != listed.annotation.creator
                    || projectedCreated != listed.annotation.created
                    || projectedModified != listed.annotation.modified
                return ReviewCommentSummary(
                    id: projectedID,
                    parentID: projectedParentID,
                    depth: listed.depth,
                    creator: projectedActor,
                    created: projectedCreated,
                    modified: projectedModified,
                    body: shortened.value,
                    bodyUnicodeScalars: shortened.originalCount,
                    bodyTruncated: shortened.truncated
                )
            }
            commentsOmitted += max(0, values.count - included.count)
            let anchor = makeAnchor(root, body: decoded.body)
            if let excerpt = anchor.excerpt,
               excerpt.prefixTruncated || excerpt.selectionTruncated || excerpt.suffixTruncated {
                excerptsTruncated += 1
            }
            let projectedThreadID = Self.boundedIdentifier(root.rootID)
            projectedStringWasTruncated = projectedStringWasTruncated
                || projectedThreadID != root.rootID
            let thread = ReviewThread(
                id: projectedThreadID,
                status: root.threadStatus,
                anchor: anchor,
                comments: ReviewCollection(items: included, total: values.count)
            )
            if Self.needsAttention(root) {
                attention.append(thread)
            } else if root.threadStatus == .open {
                open.append(thread)
            } else {
                resolved.append(thread)
            }
        }

        let attentionTotal = roots.filter(Self.needsAttention).count
        let healthyOpenTotal = roots.filter { !Self.needsAttention($0) && $0.threadStatus == .open }.count
        let healthyResolvedTotal = roots.filter { !Self.needsAttention($0) && $0.threadStatus == .resolved }.count
        let statusOpenTotal = roots.filter { $0.threadStatus == .open }.count
        let statusResolvedTotal = roots.filter { $0.threadStatus == .resolved }.count
        let threadGroups = ReviewThreadGroups(
            total: roots.count,
            statusOpenTotal: statusOpenTotal,
            statusResolvedTotal: statusResolvedTotal,
            needsAttentionTotal: attentionTotal,
            open: ReviewCollection(items: open, total: healthyOpenTotal),
            resolved: ReviewCollection(items: resolved, total: healthyResolvedTotal),
            needsAttention: ReviewCollection(items: attention, total: attentionTotal)
        )
        let headingsOmitted = outline.omitted
        let threadsOmitted = max(0, roots.count - includedRootIDs.count)
        let isTruncated = headingsOmitted > 0 || threadsOmitted > 0 || commentsOmitted > 0 ||
            bodiesTruncated > 0 || excerptsTruncated > 0 || projectedStringWasTruncated
        return ReviewSnapshot(
            change: change,
            sinceRevision: sinceRevision,
            document: document,
            outline: outline,
            threads: threadGroups,
            truncation: ReviewTruncation(
                isTruncated: isTruncated,
                detailsOmittedBecauseNotModified: false,
                limits: limits,
                headingsOmitted: headingsOmitted,
                threadsOmitted: threadsOmitted,
                commentsOmitted: commentsOmitted,
                bodiesTruncated: bodiesTruncated,
                excerptsTruncated: excerptsTruncated
            )
        )
    }

    private func change(sinceRevision: Int?, currentRevision: Int) -> ReviewChange {
        guard let sinceRevision else { return .snapshot }
        if sinceRevision == currentRevision { return .notModified }
        return sinceRevision < currentRevision ? .advanced : .reset
    }

    private func makeAnchor(_ root: ListedComment, body: String) -> ReviewAnchorSummary {
        guard case .selection = root.annotation.target else {
            return ReviewAnchorSummary(kind: .document, state: nil, range: nil, candidateCount: 0, excerpt: nil)
        }
        let resolution = root.anchor
        let excerpt = resolution?.range.flatMap { makeExcerpt(range: $0, body: body) }
        return ReviewAnchorSummary(
            kind: .selection,
            state: resolution?.state,
            range: resolution?.range,
            candidateCount: resolution?.candidates.count ?? 0,
            excerpt: excerpt
        )
    }

    private func makeExcerpt(range: UnicodeScalarRange, body: String) -> ReviewExcerpt? {
        let projection = AnchorResolver.normalizedProjection(body)
        let scalars = Array(projection.unicodeScalars)
        guard range.start >= 0, range.end > range.start, range.end <= scalars.count else { return nil }
        let windowStart = max(0, range.start - limits.contextUnicodeScalars)
        let scalarLimitEnd = min(scalars.count, windowStart + limits.maxExcerptUnicodeScalars)
        var windowEnd = windowStart
        var excerptBytes = 0
        while windowEnd < scalarLimitEnd {
            let width = Self.utf8Width(of: scalars[windowEnd])
            guard excerptBytes + width <= ReviewProjectionBounds.excerptUTF8Bytes else { break }
            excerptBytes += width
            windowEnd += 1
        }
        guard windowEnd > windowStart else { return nil }
        return ReviewExcerpt(
            text: Self.string(scalars[windowStart..<windowEnd]),
            range: UnicodeScalarRange(start: windowStart, end: windowEnd),
            selectionInExcerpt: UnicodeScalarRange(
                start: range.start - windowStart,
                end: min(range.end, windowEnd) - windowStart
            ),
            prefixTruncated: windowStart > 0,
            selectionTruncated: windowEnd < range.end,
            suffixTruncated: windowEnd < scalars.count
        )
    }

    private static func needsAttention(_ root: ListedComment) -> Bool {
        guard let state = root.anchor?.state else { return false }
        return state != .anchored
    }

    private static func commentOrder(_ lhs: ListedComment, _ rhs: ListedComment) -> Bool {
        if lhs.annotation.created != rhs.annotation.created {
            return lhs.annotation.created < rhs.annotation.created
        }
        return lhs.annotation.id < rhs.annotation.id
    }

    private static func prefix(
        _ value: String,
        maxScalars: Int,
        maxUTF8Bytes: Int
    ) -> (value: String, originalCount: Int, truncated: Bool) {
        let originalCount = value.unicodeScalars.count
        guard maxScalars > 0, maxUTF8Bytes > 0 else {
            return ("", originalCount, !value.isEmpty)
        }

        var result = String.UnicodeScalarView()
        result.reserveCapacity(min(originalCount, maxScalars))
        var included = 0
        var bytes = 0
        for scalar in value.unicodeScalars {
            guard included < maxScalars else { break }
            let width = utf8Width(of: scalar)
            guard bytes + width <= maxUTF8Bytes else { break }
            result.append(scalar)
            included += 1
            bytes += width
        }
        if included == originalCount { return (value, originalCount, false) }
        return (String(result), originalCount, true)
    }

    private static func boundedActor(_ actor: MarginActor) -> MarginActor {
        MarginActor(
            id: boundedIdentifier(actor.id),
            type: actor.type,
            name: boundedText(
                actor.name,
                maxUTF8Bytes: ReviewProjectionBounds.actorNameUTF8Bytes
            )
        )
    }

    /// Keeps ordinary protocol identifiers byte-for-byte. Oversized values get
    /// a digest suffix, retaining a useful prefix without letting two long IDs
    /// collapse to the same projected value.
    private static func boundedIdentifier(_ value: String) -> String {
        let limit = ReviewProjectionBounds.identifierUTF8Bytes
        guard value.utf8.count > limit else { return value }
        let digest = MarginSHA256.hexDigest(of: Data(value.utf8))
        let suffix = "…#sha256:\(digest)"
        let prefixBytes = max(0, limit - suffix.utf8.count)
        return utf8Prefix(value, maxBytes: prefixBytes) + suffix
    }

    private static func boundedText(_ value: String, maxUTF8Bytes: Int) -> String {
        guard value.utf8.count > maxUTF8Bytes else { return value }
        let marker = "…"
        let prefixBytes = max(0, maxUTF8Bytes - marker.utf8.count)
        return utf8Prefix(value, maxBytes: prefixBytes) + marker
    }

    private static func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars {
            let width = utf8Width(of: scalar)
            guard bytes + width <= maxBytes else { break }
            result.append(scalar)
            bytes += width
        }
        return String(result)
    }

    private static func utf8Width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F: return 1
        case 0x80...0x7FF: return 2
        case 0x800...0xFFFF: return 3
        default: return 4
        }
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
