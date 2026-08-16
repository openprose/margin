import Foundation
import MarginCore

/// A small, UI-independent projection of the embedded annotation graph. It is
/// built only when the inspector renders comments, keeping the empty-document
/// and launch paths free of thread-tree work.
struct CommentInspectorIndex {
    struct Reply: Hashable {
        let comment: MarginComment
        let parentID: String
        let parentAuthor: String
        let depth: Int
        let hasReplies: Bool

        var visualDepth: Int { min(max(depth, 1), 2) }
        var needsLineageLabel: Bool { depth > 2 }
    }

    struct Thread {
        struct ReplyVisibility: Equatable {
            let visibleIndices: [Int]
            let hiddenRanges: [Range<Int>]
            let canCollapse: Bool

            var hiddenCount: Int {
                hiddenRanges.reduce(0) { $0 + $1.count }
            }
        }

        let root: MarginComment
        let replies: [Reply]

        var commentIDs: Set<String> {
            Set([root.id] + replies.map { $0.comment.id })
        }

        func unreadIDs(in unreadCommentIDs: Set<String>) -> Set<String> {
            commentIDs.intersection(unreadCommentIDs)
        }

        func visibility(
            isActive: Bool,
            isExpanded: Bool,
            selectedCommentID: String?,
            unreadCommentIDs: Set<String> = [],
            maximumVisibleReplies: Int = 6
        ) -> ReplyVisibility {
            guard isActive, !replies.isEmpty else {
                return ReplyVisibility(
                    visibleIndices: [],
                    hiddenRanges: replies.isEmpty ? [] : [0..<replies.count],
                    canCollapse: false
                )
            }

            let resolved = root.status == .resolved
            if isExpanded || (!resolved && replies.count <= maximumVisibleReplies) {
                return ReplyVisibility(
                    visibleIndices: Array(replies.indices),
                    hiddenRanges: [],
                    canCollapse: resolved || replies.count > maximumVisibleReplies
                )
            }

            if resolved {
                return ReplyVisibility(
                    visibleIndices: [],
                    hiddenRanges: [0..<replies.count],
                    canCollapse: false
                )
            }

            var visible = Set<Int>()
            func include(_ index: Int) {
                guard replies.indices.contains(index) else { return }
                visible.insert(index)
            }
            func includeContext(around index: Int) {
                include(index - 1)
                include(index)
                include(index + 1)
            }

            include(0)
            include(1)
            include(replies.count - 2)
            include(replies.count - 1)

            if let selectedCommentID,
               let selectedIndex = replies.firstIndex(where: { $0.comment.id == selectedCommentID }) {
                includeContext(around: selectedIndex)
            }
            for index in replies.indices
                where unreadCommentIDs.contains(replies[index].comment.id) {
                includeContext(around: index)
            }

            // Fill any remaining budget chronologically. Selected and unread
            // context may deliberately exceed the soft limit rather than hide
            // review-relevant content.
            if visible.count < maximumVisibleReplies {
                for index in replies.indices where visible.count < maximumVisibleReplies {
                    include(index)
                }
            }

            let visibleIndices = visible.sorted()
            return ReplyVisibility(
                visibleIndices: visibleIndices,
                hiddenRanges: Self.hiddenRanges(
                    count: replies.count,
                    visibleIndices: visibleIndices
                ),
                canCollapse: false
            )
        }

        private static func hiddenRanges(
            count: Int,
            visibleIndices: [Int]
        ) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var cursor = 0
            for index in visibleIndices where index >= cursor {
                if index > cursor { ranges.append(cursor..<index) }
                cursor = index + 1
            }
            if cursor < count { ranges.append(cursor..<count) }
            return ranges
        }
    }

    let roots: [MarginComment]
    let threadsByRootID: [String: Thread]
    let rootIDByCommentID: [String: String]

    init(comments: [MarginComment]) {
        let roots = comments.filter { $0.motivation == "commenting" }
        let replies = comments.filter { $0.motivation == "replying" }
        let commentsByID = Dictionary(
            comments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let repliesByParent = Dictionary(grouping: replies) { comment -> String in
            if case .resource(let parentID) = comment.target { return parentID }
            return ""
        }

        var builtThreads: [String: Thread] = [:]
        var rootLookup: [String: String] = [:]
        for root in roots {
            var flattened: [Reply] = []
            var visited = Set<String>([root.id])

            func appendChildren(parentID: String, depth: Int) {
                let children = (repliesByParent[parentID] ?? []).sorted {
                    if $0.created != $1.created { return $0.created < $1.created }
                    return $0.id < $1.id
                }
                for child in children where visited.insert(child.id).inserted {
                    let parentAuthor = commentsByID[parentID]?.creator.name ?? root.creator.name
                    flattened.append(
                        Reply(
                            comment: child,
                            parentID: parentID,
                            parentAuthor: parentAuthor,
                            depth: depth,
                            hasReplies: !(repliesByParent[child.id] ?? []).isEmpty
                        )
                    )
                    rootLookup[child.id] = root.id
                    appendChildren(parentID: child.id, depth: depth + 1)
                }
            }

            appendChildren(parentID: root.id, depth: 1)
            rootLookup[root.id] = root.id
            builtThreads[root.id] = Thread(root: root, replies: flattened)
        }

        self.roots = roots
        threadsByRootID = builtThreads
        rootIDByCommentID = rootLookup
    }

    func rootID(containing commentID: String?) -> String? {
        guard let commentID else { return nil }
        return rootIDByCommentID[commentID]
    }
}
