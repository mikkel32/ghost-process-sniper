import SwiftUI

/// A left-to-right layout that wraps to new rows instead of clipping —
/// evidence tags stay readable no matter how many there are.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? usedWidth : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A two-item layout that stays horizontal when useful and collapses cleanly
/// when a sidebar or inspector narrows the content column.
///
/// Child sizes are cached per proposal for one layout pass: a stack asks for
/// this layout's size more than once, and placing used to measure the first
/// child again. SwiftUI clears the cache whenever the children change.
struct AdaptivePairLayout: Layout {
    var breakpoint: CGFloat = 720
    var spacing: CGFloat = 14
    var secondaryWidth: CGFloat? = nil

    struct Cache {
        fileprivate var sizes: [MeasureKey: CGSize] = [:]
    }

    fileprivate struct MeasureKey: Hashable {
        let index: Int
        let width: CGFloat?
        let height: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes.removeAll(keepingCapacity: true)
    }

    private func measure(_ index: Int, _ proposal: ProposedViewSize, _ subviews: Subviews, _ cache: inout Cache) -> CGSize {
        let key = MeasureKey(index: index, width: proposal.width, height: proposal.height)
        if let size = cache.sizes[key] {
            return size
        }
        let size = subviews[index].sizeThatFits(proposal)
        cache.sizes[key] = size
        return size
    }

    private func columnWidths(for width: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let secondWidth = min(secondaryWidth ?? (width - spacing) / 2, width * 0.44)
        return (max(0, width - spacing - secondWidth), secondWidth)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? breakpoint
        guard subviews.count >= 2 else {
            return measure(0, ProposedViewSize(width: width, height: proposal.height), subviews, &cache)
        }

        if width >= breakpoint {
            let columns = columnWidths(for: width)
            let first = measure(0, ProposedViewSize(width: columns.first, height: proposal.height), subviews, &cache)
            let second = measure(1, ProposedViewSize(width: columns.second, height: proposal.height), subviews, &cache)
            return CGSize(width: width, height: max(first.height, second.height))
        }

        let first = measure(0, ProposedViewSize(width: width, height: nil), subviews, &cache)
        let second = measure(1, ProposedViewSize(width: width, height: nil), subviews, &cache)
        return CGSize(width: width, height: first.height + second.height + spacing)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard !subviews.isEmpty else { return }
        guard subviews.count >= 2 else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }

        if bounds.width >= breakpoint {
            let columns = columnWidths(for: bounds.width)
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: columns.first, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + columns.first + spacing, y: bounds.minY),
                proposal: ProposedViewSize(width: columns.second, height: bounds.height)
            )
            return
        }

        let first = measure(0, ProposedViewSize(width: bounds.width, height: nil), subviews, &cache)
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: first.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + first.height + spacing),
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

struct FlowTags: View {
    let title: String
    let items: [String]

    var body: some View {
        WrappingHStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(items.prefix(10), id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}
