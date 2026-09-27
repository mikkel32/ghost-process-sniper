import SwiftUI

/// A container whose reported size never depends on its content.
///
/// SwiftUI hosts each `NavigationSplitView` column in its own hosting view,
/// and AppKit asks that view for its minimum size on every update. A
/// scrolling page answers that question by measuring every row at zero
/// width: on the Overview this was about half of the console's main-thread
/// time while the window was on screen. This layout answers from the
/// proposal alone, and lays the content out once, at the size it gets.
struct SizeIndependentLayout: Layout {
    var minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(minimum.width, proposal.width ?? minimum.width),
            height: max(minimum.height, proposal.height ?? minimum.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension View {
    /// Fills the offered space without letting size queries measure this
    /// view's content. Use it for a split-view column's root.
    func sizedIndependentlyOfContent(minimum: CGSize) -> some View {
        SizeIndependentLayout(minimum: minimum) { self }
    }
}
