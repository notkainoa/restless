// Adapted from OpenUsage's HoverTooltip (MIT, Copyright (c) 2026 Robin Ebers). See THIRD_PARTY_NOTICES.md.
// Amped adds Markdown text, left-aligned text, paragraphs placed beside the panel, and showing on click.
import AppKit
import SwiftUI

/// A tooltip that appears after a 400ms dwell instead of the system's 1.5-2s, anchored above the hovered
/// item. It lives in its own click-through panel one level above the menu bar panel, so it can float
/// outside it without stealing the hover or keyboard focus.
extension View {
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

@MainActor
private final class TooltipAnchor {
    weak var view: NSView?
    nonisolated init() {}

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    var windowFrame: NSRect? { view?.window?.frame }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @State private var id = UUID()
    @State private var anchor = TooltipAnchor()
    @State private var isHovering = false

    private var resolved: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    func body(content: Content) -> some View {
        content
            .background { TooltipAnchorView(anchor: anchor) }
            .accessibilityHint(resolved.map { HoverTooltips.plain($0) } ?? "")
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    syncPresenter()
                case .ended:
                    isHovering = false
                    TooltipPresenter.shared.exit(id: id)
                }
            }
            .onChange(of: resolved) { syncPresenter() }
            .onDisappear {
                isHovering = false
                TooltipPresenter.shared.exit(id: id)
            }
            .environment(\.tooltipShowNow, { [id, anchor] in
                guard let resolved else { return }
                TooltipPresenter.shared.showNow(id: id, text: resolved, anchor: anchor)
            })
    }

    private func syncPresenter() {
        guard isHovering else { return }
        if let resolved {
            TooltipPresenter.shared.enter(id: id, text: resolved, anchor: anchor)
        } else {
            TooltipPresenter.shared.exit(id: id)
        }
    }
}

private struct TooltipShowNowKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// Shows the enclosing `hoverTooltip` immediately, skipping the dwell (for an info button's click).
    var tooltipShowNow: (@MainActor () -> Void)? {
        get { self[TooltipShowNowKey.self] }
        set { self[TooltipShowNowKey.self] = newValue }
    }
}

@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private struct Target {
        let text: String
        let anchor: TooltipAnchor
    }

    private var active: [UUID: Target] = [:]
    private var shownID: UUID?
    private var shownText: String?
    private var pendingID: UUID?
    private var revealTask: Task<Void, Never>?

    /// One dwell for every target, with no quick re-show for neighbours: sweeping across labels would
    /// otherwise flash a burst of tooltips.
    private let revealDelay: Duration = .milliseconds(400)
    private let anchorGap: CGFloat = 10
    private let maxTooltipWidth: CGFloat = 280

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    private init() {
        panel.isFloatingPanel = true
        // Strictly above the menu bar panel, or a click that re-fronts it would bury the tooltip.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = host
    }

    func enter(id: UUID, text: String, anchor: TooltipAnchor) {
        active[id] = Target(text: text, anchor: anchor)
        refresh()
    }

    func exit(id: UUID) {
        guard active[id] != nil else { return }
        active[id] = nil
        refresh()
    }

    func showNow(id: UUID, text: String, anchor: TooltipAnchor) {
        let target = Target(text: text, anchor: anchor)
        active[id] = target
        cancelPending()
        present(target)
        shownID = id
        shownText = text
    }

    func dismissAll() {
        active.removeAll()
        cancelPending()
        hide()
    }

    private func refresh() {
        guard let (id, target) = active.first else {
            cancelPending()
            hide()
            return
        }
        if shownID == id {
            if shownText != target.text {
                present(target)
                shownText = target.text
            }
            return
        }
        if shownID != nil { hide() }
        if pendingID == id { return }
        cancelPending()
        pendingID = id
        let delay = revealDelay
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.present(target)
            self.shownID = id
            self.shownText = target.text
            self.pendingID = nil
            self.revealTask = nil
        }
    }

    private func cancelPending() {
        revealTask?.cancel()
        revealTask = nil
        pendingID = nil
    }

    private func hide() {
        shownID = nil
        shownText = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func present(_ target: Target) {
        let size = measuredSize(for: target)
        panel.setContentSize(size)
        let cursor = NSEvent.mouseLocation
        let anchorRect = target.anchor.screenRect ?? NSRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
        let origin = target.text.contains("\n") && target.anchor.windowFrame != nil
            ? sideOrigin(for: size, anchor: anchorRect, beside: target.anchor.windowFrame!)
            : origin(for: size, anchor: anchorRect)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Natural single-line size when it fits; otherwise wrapped at the narrowest width that keeps the
    /// same number of lines, so lines come out even and no word hangs alone on the last one.
    private func measuredSize(for target: Target) -> CGSize {
        func fit(maxTextWidth: CGFloat?) -> CGSize {
            host.rootView = AnyView(TooltipBubble(text: target.text, maxTextWidth: maxTextWidth))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let natural = fit(maxTextWidth: nil)
        guard natural.width > maxTooltipWidth || target.text.contains("\n") else { return natural }
        let maxTextWidth = maxTooltipWidth - 2 * TooltipBubble.horizontalPadding
        // Multi-paragraph explanations always use the full width; they read as a small card.
        if target.text.contains("\n") { return fit(maxTextWidth: maxTextWidth) }
        let wrapped = fit(maxTextWidth: maxTextWidth)
        var tooNarrow: CGFloat = 0
        var fits = maxTextWidth
        while fits - tooNarrow > 1 {
            let mid = (tooNarrow + fits) / 2
            if fit(maxTextWidth: mid).height > wrapped.height {
                tooNarrow = mid
            } else {
                fits = mid
            }
        }
        return fit(maxTextWidth: fits.rounded(.up))
    }

    /// Long explanations sit beside the panel, like a submenu, so they don't cover the settings they
    /// describe: to the right when there's room, otherwise to the left, top-aligned with the anchor.
    private func sideOrigin(for size: CGSize, anchor: NSRect, beside window: NSRect) -> NSPoint {
        let gap: CGFloat = 8
        var x = window.maxX + gap
        var y = anchor.maxY + 6 - size.height
        let screen = NSScreen.screens.first { $0.frame.intersects(window) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if x + size.width > visible.maxX { x = window.minX - gap - size.width }
            y = min(max(y, visible.minY), visible.maxY - size.height)
        }
        return NSPoint(x: x, y: y)
    }

    /// Centered above the anchor; flips below it when it would clip the top of the screen.
    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + anchorGap
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) || $0.frame.contains(anchor.origin) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = max(visible.minX, min(x, visible.maxX - size.width))
            if y + size.height > visible.maxY {
                y = anchor.minY - anchorGap - size.height
            }
            y = max(y, visible.minY)
        }
        return NSPoint(x: x, y: y)
    }
}

@MainActor
enum HoverTooltips {
    static func dismissAll() { TooltipPresenter.shared.dismissAll() }

#if DEBUG
    /// Shows a tooltip in a window parked off-screen, for checking its layout.
    static func debugWindow(for text: String) -> NSWindow {
        let host = NSHostingView(rootView: TooltipBubble(text: text, maxTextWidth: 280 - 2 * TooltipBubble.horizontalPadding))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: 400, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        return window
    }
#endif

    /// The tooltip text without Markdown, for VoiceOver.
    nonisolated static func plain(_ text: String) -> String {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? text
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A solid bubble with a hairline border; the panel is opaque, so the tooltip matches it.
private struct TooltipBubble: View {
    let text: String
    let maxTextWidth: CGFloat?

    static let horizontalPadding: CGFloat = 8

    private var isParagraphs: Bool { text.contains("\n") }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isParagraphs ? 10 : 6, style: .continuous)
        label
            .padding(.horizontal, isParagraphs ? 12 : Self.horizontalPadding)
            .padding(.vertical, isParagraphs ? 10 : 5)
            .background { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private var label: some View {
        let content = Text(attributed)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineSpacing(isParagraphs ? 1.5 : 0)
        if let maxTextWidth {
            content
                .frame(width: maxTextWidth - (isParagraphs ? 8 : 0), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}
