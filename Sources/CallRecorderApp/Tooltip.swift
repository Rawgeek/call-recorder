import SwiftUI

/// A sentence a glyph carries, and where on the surface that glyph sits.
///
/// The system's own tooltip was what drew these sentences until now, through `help`. It did not
/// appear on the settings panes: the glyph carrying the sentence is an 11-point symbol with no
/// view of its own, and a tooltip needs something to hang on. Every information icon in the app
/// silently said nothing, which is how a settings page loses the half of itself that explains
/// what the controls do.
///
/// So the sentence is drawn by the app. The glyph reports itself here while the pointer rests on
/// it, the pane draws the sentence above everything it holds, and the result does not depend on
/// what AppKit decides about a small image.
struct CRTooltipRequest: Equatable {
    var text: String
    /// Where the glyph is, in the coordinates of the surface that draws the sentence.
    var anchor: Anchor<CGRect>
    /// True when a render pinned the sentence open rather than a pointer opening it.
    var isPinned: Bool
}

/// Collects the glyph the pointer is on, for the surface's tooltip layer.
struct CRTooltipPreference: PreferenceKey {
    static let defaultValue: [CRTooltipRequest] = []

    static func reduce(value: inout [CRTooltipRequest], nextValue: () -> [CRTooltipRequest]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Offers a sentence to the tooltip layer of the surface this view sits on.
    ///
    /// The sentence is drawn only while `isOpen` is true, so a pane that carries twenty
    /// information icons publishes one sentence at a time rather than twenty.
    func crTooltip(_ text: String, isOpen: Bool, isPinned: Bool = false) -> some View {
        anchorPreference(key: CRTooltipPreference.self, value: .bounds) { anchor in
            isOpen ? [CRTooltipRequest(text: text, anchor: anchor, isPinned: isPinned)] : []
        }
    }
}

/// The sentence itself.
///
/// It is drawn on the window's own colour rather than on a material. A tooltip sits over
/// whatever the pane holds, and a material would carry that content through the words.
struct CRTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CR.Font.callout)
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.leading)
            // The width is decided by the layer, so the height has to come from the sentence
            // rather than from the space the layer was handed.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CR.Space.item)
            .padding(.vertical, CR.Space.inner)
            .background(
                RoundedRectangle(cornerRadius: CR.Radius.medium, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.24), radius: 9, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CR.Radius.medium, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            // A tooltip that swallowed the pointer would end the hover that opened it, and the
            // sentence would blink on and off under a still hand.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Draws the sentence for the glyph under the pointer.
///
/// It is applied to the surface rather than to the glyph, so the sentence is never clipped by
/// the card or the scroller the glyph sits in. Its corner is placed against the glyph, kept
/// inside the surface, and flipped above the glyph when there is no room under it.
struct CRTooltipLayer: View {
    let requests: [CRTooltipRequest]

    @State private var open: CRTooltipRequest?
    @State private var bubbleHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let open {
                    CRTooltipBubble(text: open.text)
                        .frame(width: width(in: proxy), alignment: .leading)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleHeight = $0.height }
                        .offset(x: leading(open, in: proxy), y: top(open, in: proxy))
                }
            }
        }
        // The layer covers the whole surface, and a view that covers a surface takes its clicks.
        // Nothing here is clickable: the glyphs under it are what answer the pointer, and a
        // tooltip that came between the pointer and a switch would stop the switch working.
        .allowsHitTesting(false)
        .task(id: requests) {
            guard let first = requests.first else {
                open = nil
                return
            }
            guard open != first else { return }
            open = nil
            // A sentence that appears the moment the pointer crosses a glyph flickers while the
            // hand travels down a card, so it waits out a short rest. A render has no hand and
            // no time to wait, so a pinned sentence is drawn at once.
            if !first.isPinned {
                try? await Task.sleep(for: .milliseconds(CR.Tooltip.rest))
                guard !Task.isCancelled else { return }
            }
            open = first
        }
    }

    private func width(in proxy: GeometryProxy) -> CGFloat {
        min(CR.Tooltip.width, max(CR.Tooltip.minimumWidth, proxy.size.width - 2 * CR.Space.snug))
    }

    private func leading(_ request: CRTooltipRequest, in proxy: GeometryProxy) -> CGFloat {
        let glyph = proxy[request.anchor]
        let extent = width(in: proxy)
        let furthest = max(CR.Space.snug, proxy.size.width - extent - CR.Space.snug)
        return min(max(glyph.minX, CR.Space.snug), furthest)
    }

    private func top(_ request: CRTooltipRequest, in proxy: GeometryProxy) -> CGFloat {
        let glyph = proxy[request.anchor]
        let below = glyph.maxY + CR.Tooltip.gap
        let above = glyph.minY - CR.Tooltip.gap - bubbleHeight
        if below + bubbleHeight <= proxy.size.height - CR.Space.snug { return below }
        return above >= CR.Space.snug ? above : below
    }
}

extension EnvironmentValues {
    /// The title of the row whose sentence a render pins open, or nil in the running app.
    ///
    /// A pointer is the one thing an off-screen render does not have, so a picture of a tooltip
    /// cannot be taken by hovering. The render names the row instead, and the row's glyph reports
    /// itself open. Nothing else about the drawing path changes: the picture is of the same
    /// sentence, in the same place, drawn by the same layer.
    @Entry var crPinnedTooltipRow: String?
}

/// The row a render draws its sentence open on.
enum TooltipPreview {
    /// CALL_RECORDER_TOOLTIP names the row whose sentence is pinned open in a render.
    ///
    /// A pointer is the one thing an off-screen render does not have, so this is the only way to
    /// take a picture of a tooltip. The value is a row title, which is what a person would point
    /// at to see the same sentence.
    static var row: String? {
        guard
            let value = ProcessInfo.processInfo.environment["CALL_RECORDER_TOOLTIP"],
            !value.isEmpty
        else { return nil }
        return value
    }
}
