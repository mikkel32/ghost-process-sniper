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
struct AdaptivePairLayout: Layout {
    var breakpoint: CGFloat = 720
    var spacing: CGFloat = 14
    var secondaryWidth: CGFloat? = nil

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? breakpoint
        guard subviews.count >= 2 else {
            return subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }

        if width >= breakpoint {
            let secondWidth = min(secondaryWidth ?? (width - spacing) / 2, width * 0.44)
            let firstWidth = max(0, width - spacing - secondWidth)
            let first = subviews[0].sizeThatFits(ProposedViewSize(width: firstWidth, height: proposal.height))
            let second = subviews[1].sizeThatFits(ProposedViewSize(width: secondWidth, height: proposal.height))
            return CGSize(width: width, height: max(first.height, second.height))
        }

        let sizes = subviews.prefix(2).map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return CGSize(width: width, height: sizes.reduce(0) { $0 + $1.height } + spacing)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        guard subviews.count >= 2 else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }

        if bounds.width >= breakpoint {
            let secondWidth = min(secondaryWidth ?? (bounds.width - spacing) / 2, bounds.width * 0.44)
            let firstWidth = max(0, bounds.width - spacing - secondWidth)
            subviews[0].place(
                at: bounds.origin,
                proposal: ProposedViewSize(width: firstWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + firstWidth + spacing, y: bounds.minY),
                proposal: ProposedViewSize(width: secondWidth, height: bounds.height)
            )
            return
        }

        let first = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
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
