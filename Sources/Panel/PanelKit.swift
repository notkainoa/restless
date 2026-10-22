// Panel building blocks adapted from OpenUsage (MIT, Copyright (c) 2026 Robin Ebers):
// Animations, Theme, LiquidGlassFallbacks, PopoverScrollView, InvisibleOverlayScroller,
// PanelHeightModifier, PanelHeightCoordinator, PopoverDismissReader and ClosureMenuItem.
// See THIRD_PARTY_NOTICES.md.
import AppKit
import Observation
import SwiftUI
import os

// MARK: - Motion

enum Motion {
    /// The one spring for everything that moves: screen slides, panel height, cards appearing.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
    /// Wraps screen changes; the slide itself rides `spring`.
    static let modeSwitch = Animation.easeInOut(duration: 0.18)
    /// Hover affordances fading in and out.
    static let hover = Animation.easeOut(duration: 0.12)
}

private struct ReduceAnimationsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reduceAnimations: Bool {
        get { self[ReduceAnimationsKey.self] }
        set { self[ReduceAnimationsKey.self] = newValue }
    }
}

extension View {
    /// Follows the system Reduce Motion setting by dropping every animation in the subtree.
    func reduceAnimationsWhenRequested() -> some View {
        modifier(ReduceAnimationsModifier())
    }
}

private struct ReduceAnimationsModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.reduceAnimations, reduceMotion)
            .transaction { transaction in
                guard reduceMotion else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

// MARK: - Theme

enum Theme {
    /// The panel's opaque tray: white in light mode, #1E1E1E in dark.
    static let trayNSColor: NSColor = .textBackgroundColor
    static var traySurface: Color { Color(nsColor: trayNSColor) }
    static let cardFill = AnyShapeStyle(.fill.quaternary)
    static let cardCornerRadius: CGFloat = 12
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// The grouped-box look of System Settings: the system's faint fill over the tray, no border.
    func cardSurface() -> some View {
        background {
            Theme.cardShape
                .fill(Theme.traySurface)
                .overlay { Theme.cardShape.fill(Theme.cardFill) }
        }
    }

    /// Pass the row's title as the Toggle's label: it's hidden on screen but stays the switch's VoiceOver name.
    func settingsSwitchStyle() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    /// Liquid Glass goes on the chrome only (bars and their controls), never on content cards.
    func barGlass() -> some View {
        glassEffect(.regular, in: Rectangle())
    }

    func interactiveGlass<S: Shape>(in shape: S) -> some View {
        modifier(InteractiveGlassModifier(shape: shape))
    }
}

private struct InteractiveGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.reduceAnimations) private var reduceAnimations

    func body(content: Content) -> some View {
        content.glassEffect(reduceAnimations ? .regular : .regular.interactive(), in: shape)
    }
}

// MARK: - Scrolling

/// The scroll container every screen uses. It keeps the native scroll edge blur under the bars,
/// hides the scroller, and publishes the content's intrinsic height so the panel can fit it.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .invisibleOverlayScroller()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ScrollContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    /// Hides the scrollbar without losing the scroll edge effect, which needs a vertical scroller to exist.
    func invisibleOverlayScroller() -> some View {
        background(InvisibleOverlayScroller())
    }
}

private struct InvisibleOverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

    func updateNSView(_ nsView: ScrollerView, context: Context) {
        nsView.apply()
    }

    final class ScrollerView: NSView {
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
                self.styleObserver = nil
            }
            guard window != nil else { return }
            apply()
            // `enclosingScrollView` may not be wired up until the current layout pass commits.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        // Replacing the scroller would flip the view to legacy style and add a 17pt gutter, so only fade it.
        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.alphaValue = 0
        }
    }
}

// MARK: - Panel height

/// Lets the panel's window height follow a SwiftUI-animated value, so the window and the screen slide
/// ride one spring instead of two clocks fighting. A height of 0 means "not measured yet" and is skipped.
struct PanelHeightModifier: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

extension View {
    /// Attach at the body root, outside any `.animation(nil, …)`, so the height rides the active spring.
    func drivesPanelHeight(_ height: CGFloat) -> some View {
        modifier(PanelHeightModifier(height: height))
    }
}

/// Hops interpolated heights onto the main queue (setting the frame inside SwiftUI's update pass trips
/// AppKit's layout-recursion check) and coalesces bursts to the newest value. A generation counter
/// drops heights queued before the panel last opened or closed.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (scheduled, shouldSchedule) = state.withLock { state in
            state.pendingHeight = height
            let scheduled = state.generation
            guard !state.isScheduled else { return (scheduled, false) }
            state.isScheduled = true
            return (scheduled, true)
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == scheduled else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
        }
    }
}

/// Sums each screen's measured parts (top bar and scroll content) into the height it wants.
@MainActor
@Observable
final class PanelHeightCoordinator {
    private(set) var measuredIdeal: [PanelScreen: CGFloat] = [:]

    @ObservationIgnored private var measuredScrollContent: [PanelScreen: CGFloat] = [:]

    func setScrollContent(_ height: CGFloat, for screen: PanelScreen) {
        guard measuredScrollContent[screen] != height else { return }
        measuredScrollContent[screen] = height
        recomposeIdeal(for: screen)
    }

    private func recomposeIdeal(for screen: PanelScreen) {
        guard let content = measuredScrollContent[screen], content > 0 else { return }
        let topBar = screen.hasTopBar ? PanelMetrics.topBarHeight : 0
        let ideal = topBar + content
        guard measuredIdeal[screen] != ideal else { return }
        measuredIdeal[screen] = ideal
    }

    func target(for screen: PanelScreen) -> CGFloat? {
        measuredIdeal[screen].map { MenuBarPopover.clampHeight?($0) ?? $0 }
    }
}

// MARK: - Bridge and keys

/// Lets views inside the panel reach the controller that owns it.
@MainActor
enum MenuBarPopover {
    static var dismissHandler: (() -> Void)?
    static var applyHeight: ((CGFloat) -> Void)?
    static var clampHeight: ((CGFloat) -> CGFloat)?

    static func dismiss() {
        dismissHandler?()
    }

    /// Closes the panel first, for actions that show an alert or a password prompt: those open at a
    /// lower window level than the panel and would end up hidden behind it.
    static func dismissThen(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        DispatchQueue.main.async { action() }
    }
}

/// Esc and ⌘, through a local key monitor; SwiftUI's `.keyboardShortcut` is unreliable in this panel.
struct PopoverKeyReader: NSViewRepresentable {
    /// Called first on Esc; returning false lets the panel close.
    var onEscape: @MainActor () -> Bool = { false }
    var onSettings: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onEscape = onEscape
        view.onSettings = onSettings
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onEscape = onEscape
        view.onSettings = onSettings
    }

    final class MonitorView: NSView {
        var onEscape: (@MainActor () -> Bool)?
        var onSettings: (@MainActor () -> Bool)?
        private var monitor: Any?
        private static let escapeKeyCode: UInt16 = 53

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let isEscape = keyCode == Self.escapeKeyCode
                // The character rather than the key position, so ⌘, works on every keyboard layout.
                let isSettings = event.charactersIgnoringModifiers == "," && modifiers == [.command]
                guard isEscape || isSettings else { return event }
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, window.isVisible,
                          eventWindowID == ObjectIdentifier(window),
                          !(window.firstResponder is NSText)
                    else { return false }
                    if isSettings { return self.onSettings?() ?? false }
                    if self.onEscape?() == true { return true }
                    MenuBarPopover.dismiss()
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemSymbol: String? = nil, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        if let systemSymbol {
            image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
