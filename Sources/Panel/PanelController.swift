// The menu bar panel, adapted from OpenUsage (MIT, Copyright (c) 2026 Robin Ebers):
// StatusItemController, PanelHeightController and PanelOutsideClickMonitor. See THIRD_PARTY_NOTICES.md.
import AppKit
import Combine
import Observation
import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 320
    static let cornerRadius: CGFloat = 13
    static let topBarHeight: CGFloat = 44
    static let outerPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
}

enum PanelScreen: Hashable {
    case dashboard
    case settings

    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .settings: 1
        }
    }

    var hasTopBar: Bool { self != .dashboard }
}

@MainActor
@Observable
final class PanelNavigation {
    var screen = PanelScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // Recorded synchronously: an onChange would paint the destination one frame early.
            screenSlideFrom = oldValue
            screenSlideID += 1
        }
    }
    private(set) var screenSlideFrom = PanelScreen.dashboard
    private(set) var screenSlideID = 0
    /// Flipped by the controller at the exact show and hide moments.
    var isShown = false
}

/// A borderless, non-activating panel that can still become key: it takes keyboard input the moment
/// it opens without activating the app, which NSPopover and MenuBarExtra can't do for a menu bar app.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the status item and the panel that shows Restless's controls.
@MainActor
final class PanelController: NSObject {
    private let controller: SleepController
    private let navigation = PanelNavigation()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuBarPanel
    private let hostingController: NSHostingController<AnyView>
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private var cancellables: Set<AnyCancellable> = []
    private var visibilityObservation: NSKeyValueObservation?

    init(controller: SleepController) {
        self.controller = controller
        hostingController = NSHostingController(
            rootView: AnyView(
                PanelRootView()
                    .reduceAnimationsWhenRequested()
                    .environmentObject(controller)
                    .environment(navigation)
            )
        )
        // The panel's height comes from the content measurements, not the hosting view's own sizing.
        hostingController.sizingOptions = []
        panel = MenuBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelHeightController.defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let navigation = navigation
        heightController = PanelHeightController(panel: panel) { navigation.screen }
        super.init()

        configurePanel()
        configureStatusItem()
        MenuBarPopover.dismissHandler = { [weak self] in self?.hidePanel() }
        heightController.installBridge()
    }

    // MARK: Panel

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No open or close animation: it appears and disappears like a system menu.
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView()
        let backdrop = NSBox()
        backdrop.boxType = .custom
        backdrop.borderWidth = 0
        backdrop.cornerRadius = PanelMetrics.cornerRadius
        backdrop.fillColor = Theme.trayNSColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // Redraw on every step of a height change instead of stretching the cached layer.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = PanelMetrics.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(backdrop)
        container.addSubview(host, positioned: .above, relativeTo: backdrop)
        for view in [backdrop, host] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        let rootViewController = NSViewController()
        rootViewController.view = container
        rootViewController.addChild(hostingController)
        panel.contentViewController = rootViewController
    }

    func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    /// Opens the panel on Settings, already sized for it.
    func showSettings() {
        navigation.screen = .settings
        if !panel.isVisible { showPanel() }
    }

    var canShowPanel: Bool { statusItem.isVisible && statusItem.button?.window != nil }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        controller.refreshStatus()
        // The display must be known before SwiftUI sees the panel as shown, since that asks for the clamp.
        heightController.prepareForOpening(below: buttonRect)
        navigation.isShown = true
        // Lay out first so the panel opens at the right size, with no first-frame flash.
        hostingController.view.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
        clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        // The SwiftUI tree survives orderOut, so nothing hovered gets an exit event; clear it here.
        HoverTooltips.dismissAll()
        clearStrayFocus()
        heightController.saveBeforeClosing()
        navigation.isShown = false
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
    }

    /// Becoming key would otherwise put a focus ring on the first control when Keyboard Navigation is on.
    private func clearStrayFocus() {
        guard !(panel.firstResponder is NSText) else { return }
        panel.makeFirstResponder(nil)
    }

    // MARK: Status item

    private func configureStatusItem() {
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = Self.showsMenuBarItem
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        visibilityObservation = statusItem.observe(\.isVisible) { item, _ in
            let visible = item.isVisible
            Task { @MainActor in
                if Self.showsMenuBarItem != visible { SettingsView.store.set(visible, forKey: SettingsView.showMenuBarItemKey) }
            }
        }
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
        updateIcon()
    }

    private static var showsMenuBarItem: Bool {
        SettingsView.store.object(forKey: SettingsView.showMenuBarItemKey) as? Bool ?? true
    }

    private func syncVisibility() {
        let visible = Self.showsMenuBarItem
        guard statusItem.isVisible != visible else { return }
        if !visible { hidePanel() }
        statusItem.isVisible = visible
    }

    private var iconKey = ""

    /// Only reassigned when it changes; every assignment costs a menu bar redraw.
    private func updateIcon() {
        let key = "\(controller.menuBarSymbolName)-\(controller.menuBarSymbolDimmed)"
        guard key != iconKey else { return }
        iconKey = key
        var image = NSImage(systemSymbolName: controller.menuBarSymbolName, accessibilityDescription: "Restless")
        if controller.menuBarSymbolDimmed {
            image = image?.withSymbolConfiguration(.preferringHierarchical())
        }
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    /// Right-click shows a native menu; assigning the menu for one click anchors it under the item.
    private func showContextMenu() {
        hidePanel()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.showSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Restless", systemSymbol: "power", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

#if DEBUG
    /// Opens the panel off-screen without taking keyboard focus and writes it to a PNG.
    func snapshot(to output: URL, screen: PanelScreen) {
        if UserDefaults.standard.bool(forKey: "menuSnapshotLight") { NSApp.appearance = NSAppearance(named: .aqua) }
        PanelGeometry.debugOffset = -6000
        switch UserDefaults.standard.string(forKey: "panelSnapshotState") {
        case "awake": controller.debugShowState(keepAwake: true, lidClosed: false)
        case "lid": controller.debugShowState(keepAwake: false, lidClosed: true)
        default: break
        }
        navigation.screen = screen
        heightController.prepareForOpening(below: NSRect(x: 600, y: 900, width: 30, height: 24))
        navigation.isShown = true
        hostingController.view.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        let tooltip = HoverTooltips.debugWindow(for: UserDefaults.standard.string(forKey: "panelSnapshotTooltip") ?? HelpText.lidClosed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let image = SettingsSnapshot.image(of: self.panel) {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
            }
            if let image = SettingsSnapshot.image(of: tooltip) {
                let url = output.deletingPathExtension().appendingPathExtension("tooltip.png")
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
            exit(0)
        }
    }
#endif
}

// MARK: - Placement and height

/// Owns the panel's placement and its content-driven height.
@MainActor
final class PanelHeightController {
    static let defaultHeight: CGFloat = 560

    private let panel: MenuBarPanel
    private let currentScreen: () -> PanelScreen
    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false

    init(panel: MenuBarPanel, currentScreen: @escaping () -> PanelScreen) {
        self.panel = panel
        self.currentScreen = currentScreen
    }

    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in self?.applyMorphHeight(height) }
        MenuBarPopover.clampHeight = { [weak self] height in self?.clampedHeight(height) ?? height }
    }

    /// Opens at the height remembered for this screen, so the first frame is already close.
    func prepareForOpening(below buttonRect: NSRect) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        anchorScreen = screen
        let topLeft = PanelGeometry.clampedTopLeft(below: buttonRect, width: PanelMetrics.width, visibleFrame: screen?.visibleFrame)
        anchorTopLeft = topLeft
        let remembered = loadHeight(for: currentScreen()) ?? Self.defaultHeight
        panel.setFrame(PanelGeometry.frame(topLeft: topLeft, width: PanelMetrics.width, height: clampedHeight(remembered)), display: false)
        panel.invalidateShadow()
    }

    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(panel.frame.height, for: currentScreen())
    }

    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible, let anchorTopLeft else { return }
        let height = clampedHeight(rawHeight)
        guard abs(panel.frame.height - height) > 1 else { return }
        // The top-left stays put, so the panel grows and shrinks downward.
        panel.setFrame(PanelGeometry.frame(topLeft: anchorTopLeft, width: PanelMetrics.width, height: height), display: false)
        isMorphing = true
        scheduleMorphSettle()
    }

    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            // Rebuilding the shadow on every frame competes with the animation; once at the end is enough.
            self.panel.invalidateShadow()
            self.saveHeight(self.panel.frame.height, for: self.currentScreen())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        PanelGeometry.clampedHeight(rawHeight, maximum: maximumHeight())
    }

    private func maximumHeight() -> CGFloat {
        guard let anchorTopLeft, let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultHeight
        }
        return PanelGeometry.maximumHeight(topLeft: anchorTopLeft, visibleFrame: visibleFrame)
    }

    private func loadHeight(for screen: PanelScreen) -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: Self.heightKey(for: screen))
        return value > 0 ? CGFloat(value) : nil
    }

    private func saveHeight(_ height: CGFloat, for screen: PanelScreen) {
        UserDefaults.standard.set(Double(height), forKey: Self.heightKey(for: screen))
    }

    private static func heightKey(for screen: PanelScreen) -> String {
        switch screen {
        case .dashboard: "panelHeight.dashboard"
        case .settings: "panelHeight.settings"
        }
    }
}

enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8
    static let minimumHeight: CGFloat = 200
#if DEBUG
    static var debugOffset: CGFloat = 0
#endif

    /// Left-aligned to the status item, not centered, and kept off the screen edges.
    static func clampedTopLeft(below buttonRect: NSRect, width: CGFloat, visibleFrame: NSRect?) -> NSPoint {
        var x = buttonRect.minX
        if let visibleFrame {
            x = min(max(x, visibleFrame.minX + screenMargin), visibleFrame.maxX - width - screenMargin)
        }
        return NSPoint(x: x, y: buttonRect.minY - topGap)
    }

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        return max(1, min(roomBelowAnchor, floor(visibleFrame.height * 0.85)))
    }

    static func clampedHeight(_ rawHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(rawHeight, minimumHeight), maximum)
    }

    /// Whole points only: a half-point anchor plus fractional morph heights would make the top edge shake.
    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let top = topLeft.y.rounded(.down)
        let height = height.rounded()
        var x = topLeft.x
#if DEBUG
        x += debugOffset
#endif
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

// MARK: - Outside clicks

/// Closes the panel on a mouse-down anywhere else, except the status button, menus and alerts.
@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItem: NSStatusItem
    private let isMorphing: () -> Bool
    private let onInsidePanelClick: () -> Void
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(
        panel: MenuBarPanel,
        statusItem: NSStatusItem,
        isMorphing: @escaping () -> Bool,
        onInsidePanelClick: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.statusItem = statusItem
        self.isMorphing = isMorphing
        self.onInsidePanelClick = onInsidePanelClick
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                self?.handleClick(windowID: windowID, windowTypeName: windowTypeName, screenPoint: NSEvent.mouseLocation)
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, windowTypeName: nil, screenPoint: screenPoint)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handleClick(windowID: ObjectIdentifier?, windowTypeName: String?, screenPoint: NSPoint) {
        let isInsidePanel = panel.frame.contains(screenPoint)
        let buttonWindowID = statusItem.button?.window.map(ObjectIdentifier.init)
        let keepOpen = isMorphing()
            || panel.attachedSheet != nil
            || isOnStatusButton(screenPoint)
            || isInsidePanel
            || (windowID != nil && windowID == ObjectIdentifier(panel))
            || (windowID != nil && windowID == buttonWindowID)
            || windowTypeName?.localizedCaseInsensitiveContains("menu") == true
            || windowTypeName?.localizedCaseInsensitiveContains("popover") == true
        if keepOpen {
            if isInsidePanel { onInsidePanelClick() }
            return
        }
        onDismiss()
    }

    /// The hit zone runs up to the top of the screen with inclusive edges: a click with the cursor
    /// pinned to the top edge lands on the button, and must not also count as an outside click.
    private func isOnStatusButton(_ point: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard !frame.isEmpty else { return false }
        let top = max(frame.maxY, buttonWindow.screen?.frame.maxY ?? frame.maxY)
        return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= top
    }
}
