import Foundation
import MarginCore
import Darwin

enum ComparisonSide: String, Sendable {
    case left
    case right
}

struct WorkspaceComparisonSource: Sendable {
    let markdown: String
    let label: String
    let sourceURL: URL?

    var pathHint: String? { sourceURL?.lastPathComponent }
}

struct WorkspaceComparisonSourceMetadata: Sendable, Equatable {
    let label: String
    let sourceURL: URL?
}

protocol WorkspaceComparisonSourceProviding: AnyObject {
    var comparisonSourceMetadata: WorkspaceComparisonSourceMetadata? { get }
    func comparisonSource() -> WorkspaceComparisonSource?
}

protocol WorkspaceComparisonApplying: AnyObject {
    func applyComparisonPlan(_ plan: ComparisonApplyPlan) throws
    func flushComparisonApply() -> Bool
}

extension WorkspaceComparisonApplying {
    func flushComparisonApply() -> Bool { true }
}

enum AppComparisonRequest: Sendable {
    case files(left: URL, right: URL)
    case sources(left: WorkspaceComparisonSource, right: WorkspaceComparisonSource)
    case snapshots(ComparisonSnapshotPair)
    case openRequest(URL)
    case review(URL)

    var supportsRefresh: Bool {
        switch self {
        case .files, .review:
            return true
        case .sources, .snapshots, .openRequest:
            return false
        }
    }
}

enum ComparisonURLKind: Equatable {
    case document
    case openRequest
    case review
}

enum ComparisonURLClassifier {
    static func classify(_ url: URL) -> ComparisonURLKind {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".margincompare-request") { return .openRequest }
        if name.hasSuffix(".marginreview") || name.hasSuffix(".margin-review.json") {
            return .review
        }
        return .document
    }
}

struct ComparisonSelectionRequest: Sendable, Equatable {
    let side: ComparisonSide
    let pairID: String
    let snapshotSHA256: String
    let blockID: String?
    let unicodeScalarRange: UnicodeScalarRange
    let quote: String
}

enum ComparisonPresentationLayout: Int, Sendable {
    case inline
    case sideBySide

    static let sideBySideMinimumWidth: CGFloat = 840

    static func effective(
        preferred: ComparisonPresentationLayout,
        width: CGFloat
    ) -> ComparisonPresentationLayout {
        preferred == .sideBySide && width < sideBySideMinimumWidth ? .inline : preferred
    }
}

struct ComparisonPresentedSide: Sendable, Equatable {
    let text: String
    let lineNumber: Int
    let unicodeScalarStart: Int
    let unicodeScalarLength: Int
    let wordEmphasis: [UnicodeScalarRange]
    let isDisplayTruncated: Bool
}

enum ComparisonPresentedRowKind: Sendable, Equatable {
    case content(ComparisonBlockKind)
    case collapsed(omittedLineCount: Int)
}

struct ComparisonPresentedRow: Sendable, Equatable {
    let id: String
    let blockID: String?
    let kind: ComparisonPresentedRowKind
    let left: ComparisonPresentedSide?
    let right: ComparisonPresentedSide?
    let isFirstRowForChange: Bool

    var isChanged: Bool {
        guard case .content(let kind) = kind else { return false }
        return kind != .unchanged
    }
}

struct ComparisonPresentation: Sendable {
    let pair: ComparisonSnapshotPair
    let result: ComparisonDiffResult
    let rows: [ComparisonPresentedRow]
    let collapsedRows: [String: [ComparisonPresentedRow]]
    let review: ComparisonReview?
    let reviewURL: URL?
    let leftSourceURL: URL?
    let rightSourceURL: URL?

    var isIdentical: Bool { result.changedBlocks.isEmpty }
}

protocol ComparisonLoading: Sendable {
    func load(
        _ request: AppComparisonRequest,
        cancellation: ComparisonCancellationToken
    ) throws -> ComparisonPresentation
}

struct CoreComparisonLoader: ComparisonLoading {
    let limits: ComparisonLimits
    let now: @Sendable () -> Date

    init(
        limits: ComparisonLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limits = limits
        self.now = now
    }

    func load(
        _ request: AppComparisonRequest,
        cancellation: ComparisonCancellationToken
    ) throws -> ComparisonPresentation {
        let pair: ComparisonSnapshotPair
        var review: ComparisonReview?
        var loadedReviewURL: URL?
        var leftSourceURL: URL?
        var rightSourceURL: URL?
        switch request {
        case .files(let leftURL, let rightURL):
            leftSourceURL = leftURL.standardizedFileURL
            rightSourceURL = rightURL.standardizedFileURL
            let left = try ComparisonSnapshot.readMarkdownFile(
                at: leftURL,
                pathHint: leftURL.lastPathComponent,
                limits: limits
            )
            guard !cancellation.isCancelled else { throw ComparisonError.cancelled }
            let right = try ComparisonSnapshot.readMarkdownFile(
                at: rightURL,
                pathHint: rightURL.lastPathComponent,
                limits: limits
            )
            pair = try ComparisonSnapshotPair(left: left, right: right)

        case .sources(let leftSource, let rightSource):
            leftSourceURL = leftSource.sourceURL?.standardizedFileURL
            rightSourceURL = rightSource.sourceURL?.standardizedFileURL
            let left = try ComparisonSnapshot(
                markdownBody: leftSource.markdown,
                label: leftSource.label,
                pathHint: leftSource.pathHint,
                includeApplyPrecondition: leftSource.sourceURL != nil,
                limits: limits
            )
            guard !cancellation.isCancelled else { throw ComparisonError.cancelled }
            let right = try ComparisonSnapshot(
                markdownBody: rightSource.markdown,
                label: rightSource.label,
                pathHint: rightSource.pathHint,
                includeApplyPrecondition: rightSource.sourceURL != nil,
                limits: limits
            )
            pair = try ComparisonSnapshotPair(left: left, right: right)

        case .snapshots(let suppliedPair):
            pair = suppliedPair

        case .openRequest(let requestURL):
            let launchRequest = try ComparisonOpenRequestReader.consume(
                requestURL,
                now: now(),
                limits: limits
            )
            pair = try launchRequest.snapshotPair()

        case .review(let artifactURL):
            let loadedReview = try ComparisonReviewStore(limits: limits).load(at: artifactURL)
            review = loadedReview
            // Source hints inside a portable review are display-only and
            // never become write authority. Only the explicitly opened
            // artifact URL is retained.
            loadedReviewURL = artifactURL.standardizedFileURL
            pair = loadedReview.snapshots
        }

        guard !cancellation.isCancelled else { throw ComparisonError.cancelled }
        let result = try ComparisonEngine(limits: limits).compare(
            pair,
            cancellation: cancellation
        )
        return try ComparisonPresentationBuilder.build(
            pair: pair,
            result: result,
            cancellation: cancellation,
            review: review,
            reviewURL: loadedReviewURL,
            leftSourceURL: leftSourceURL,
            rightSourceURL: rightSourceURL
        )
    }
}

enum ComparisonOpenRequestReader {
    static let maximumAge: TimeInterval = 10 * 60

    static func consume(
        _ url: URL,
        now: Date = Date(),
        limits: ComparisonLimits = .default
    ) throws -> ComparisonOpenRequest {
        guard ComparisonURLClassifier.classify(url) == .openRequest else {
            throw ComparisonError.invalidArtifact("Not a Margin comparison launch request.")
        }

        let maximumBytes = min(limits.maxArtifactBytes, ComparisonHardLimits.artifactBytes)
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ComparisonError.io("Margin could not securely open the comparison request.")
        }
        defer { Darwin.close(descriptor) }

        var original = stat()
        guard fstat(descriptor, &original) == 0,
              (original.st_mode & S_IFMT) == S_IFREG else {
            throw ComparisonError.notRegularFile(url.path)
        }
        guard original.st_uid == geteuid(), (original.st_mode & 0o077) == 0 else {
            throw ComparisonError.invalidArtifact(
                "Comparison request must be owned by the current user and mode 0600."
            )
        }
        guard original.st_size >= 0, original.st_size <= maximumBytes else {
            throw ComparisonError.resourceLimit(
                name: "comparison launch request bytes",
                limit: maximumBytes,
                actual: max(0, Int(original.st_size))
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw ComparisonError.resourceLimit(
                name: "comparison launch request bytes",
                limit: maximumBytes,
                actual: data.count
            )
        }

        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              sameOpenFile(original, afterRead) else {
            throw ComparisonError.concurrentModification
        }

        let request = try ComparisonOpenRequestCodec.decode(
            data,
            maximumBytes: maximumBytes
        )
        try request.validateAge(relativeTo: now, maximumAge: maximumAge)

        var beforeUnlink = stat()
        guard fstat(descriptor, &beforeUnlink) == 0,
              sameOpenFile(original, beforeUnlink) else {
            throw ComparisonError.concurrentModification
        }

        var current = stat()
        let unchanged = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path, lstat(path, &current) == 0 else { return false }
            return (current.st_mode & S_IFMT) == S_IFREG
                && current.st_dev == original.st_dev
                && current.st_ino == original.st_ino
        }
        guard unchanged else { throw ComparisonError.concurrentModification }
        let removed: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        guard removed == 0 else {
            throw ComparisonError.io(
                "The comparison request was decoded but could not be consumed safely."
            )
        }
        return request
    }

    private static func sameOpenFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

private enum ComparisonPresentationBuilder {
    private static let unchangedContextLines = 3
    private static let collapseThreshold = 10
    private static let maximumVisibleScalarsPerLine = 2_000

    static func build(
        pair: ComparisonSnapshotPair,
        result: ComparisonDiffResult,
        cancellation: ComparisonCancellationToken,
        review: ComparisonReview?,
        reviewURL: URL?,
        leftSourceURL: URL?,
        rightSourceURL: URL?
    ) throws -> ComparisonPresentation {
        let leftLines = parseLines(pair.left.content)
        let rightLines = parseLines(pair.right.content)
        var rows: [ComparisonPresentedRow] = []
        var collapsedRows: [String: [ComparisonPresentedRow]] = [:]

        for (blockIndex, block) in result.blocks.enumerated() {
            if cancellation.isCancelled { throw ComparisonError.cancelled }
            let count = max(block.left.lineCount, block.right.lineCount)
            guard count > 0 else { continue }
            let blockRows = makeRows(
                block: block,
                blockIndex: blockIndex,
                offsets: 0..<count,
                leftLines: leftLines,
                rightLines: rightLines
            )
            if block.kind == .unchanged, count >= collapseThreshold {
                let leadingCount = min(unchangedContextLines, count)
                let trailingStart = max(leadingCount, count - unchangedContextLines)
                rows.append(contentsOf: blockRows.prefix(leadingCount))
                if trailingStart > leadingCount {
                    let markerID = "collapsed-\(blockIndex)"
                    let hidden = Array(blockRows[leadingCount..<trailingStart])
                    collapsedRows[markerID] = hidden
                    rows.append(ComparisonPresentedRow(
                        id: markerID,
                        blockID: nil,
                        kind: .collapsed(omittedLineCount: hidden.count),
                        left: nil,
                        right: nil,
                        isFirstRowForChange: false
                    ))
                }
                rows.append(contentsOf: blockRows.suffix(count - trailingStart))
            } else {
                rows.append(contentsOf: blockRows)
            }
        }
        return ComparisonPresentation(
            pair: pair,
            result: result,
            rows: rows,
            collapsedRows: collapsedRows,
            review: review,
            reviewURL: reviewURL,
            leftSourceURL: leftSourceURL,
            rightSourceURL: rightSourceURL
        )
    }

    private static func makeRows(
        block: ComparisonBlock,
        blockIndex: Int,
        offsets: Range<Int>,
        leftLines: [PresentedLine],
        rightLines: [PresentedLine]
    ) -> [ComparisonPresentedRow] {
        // Replacement blocks can contain thousands of lines. Index the optional
        // word-level detail once so row construction remains linear instead of
        // rescanning every word diff for every presented line.
        let wordDiffByLeftLine = Dictionary(
            block.wordDiffs.map { ($0.leftLine, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let wordDiffByRightLine = Dictionary(
            block.wordDiffs.map { ($0.rightLine, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return offsets.map { offset in
            let leftIndex = block.left.lineStart + offset
            let rightIndex = block.right.lineStart + offset
            let left = offset < block.left.lineCount && leftLines.indices.contains(leftIndex)
                ? side(
                    line: leftLines[leftIndex],
                    lineIndex: leftIndex,
                    wordDiff: wordDiffByLeftLine[leftIndex],
                    side: .left
                )
                : nil
            let right = offset < block.right.lineCount && rightLines.indices.contains(rightIndex)
                ? side(
                    line: rightLines[rightIndex],
                    lineIndex: rightIndex,
                    wordDiff: wordDiffByRightLine[rightIndex],
                    side: .right
                )
                : nil
            return ComparisonPresentedRow(
                id: "block-\(blockIndex)-row-\(offset)",
                blockID: block.id,
                kind: .content(block.kind),
                left: left,
                right: right,
                isFirstRowForChange: block.kind != .unchanged && offset == 0
            )
        }
    }

    private static func side(
        line: PresentedLine,
        lineIndex: Int,
        wordDiff: ComparisonWordDiff?,
        side: ComparisonSide
    ) -> ComparisonPresentedSide {
        let scalars = line.text.unicodeScalars
        let visibleCount = min(scalars.count, maximumVisibleScalarsPerLine)
        var visibleText = String(scalars.prefix(visibleCount))
        let truncated = visibleCount < scalars.count
        if truncated { visibleText += " …" }

        let ranges = wordDiff?.segments.compactMap { segment -> UnicodeScalarRange? in
            let range = side == .left
                ? segment.leftUnicodeScalars
                : segment.rightUnicodeScalars
            guard let range,
                  range.start >= line.scalarStart,
                  range.end <= line.scalarStart + visibleCount,
                  segment.kind != .unchanged else { return nil }
            return UnicodeScalarRange(
                start: range.start - line.scalarStart,
                end: range.end - line.scalarStart
            )
        } ?? []
        return ComparisonPresentedSide(
            text: visibleText,
            lineNumber: lineIndex + 1,
            unicodeScalarStart: line.scalarStart,
            unicodeScalarLength: visibleCount,
            wordEmphasis: ranges,
            isDisplayTruncated: truncated
        )
    }

    private struct PresentedLine {
        let text: String
        let scalarStart: Int
    }

    private static func parseLines(_ source: String) -> [PresentedLine] {
        let bytes = Array(source.utf8)
        var lines: [PresentedLine] = []
        var byteStart = 0
        var scalarStart = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x0a || byte == 0x0d else {
                index += 1
                continue
            }
            let terminatorLength = byte == 0x0d
                && index + 1 < bytes.count
                && bytes[index + 1] == 0x0a ? 2 : 1
            let text = String(decoding: bytes[byteStart..<index], as: UTF8.self)
            lines.append(PresentedLine(text: text, scalarStart: scalarStart))
            scalarStart += text.unicodeScalars.count + terminatorLength
            index += terminatorLength
            byteStart = index
        }
        if byteStart < bytes.count {
            let text = String(decoding: bytes[byteStart..<bytes.count], as: UTF8.self)
            lines.append(PresentedLine(text: text, scalarStart: scalarStart))
        }
        return lines
    }
}
