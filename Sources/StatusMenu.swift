import AppKit
import Combine

// MenuBarExtra's menu style only has checkmark items, and clicking one closes the menu. Here the Keep Awake rows are
// switches and the other settings are checkmark rows drawn as views, which toggle in place and leave the menu open.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: SleepController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let infoPanel = InfoPanel()
    private var cancellables: Set<AnyCancellable> = []
    private var visibilityObservation: NSKeyValueObservation?

    private let lidOpenKeepAwake = SwitchRow(title: "Keep Awake")
    private let lidClosedKeepAwake = SwitchRow(title: "Keep Awake")
    private let lidSleepDisplay = CheckRow(title: "Sleep Display")
    private let lidLockScreen = CheckRow(title: "Lock Screen")
    private let autoOff = CheckRow(title: "Auto-off at 20% Battery")
    private let launchAtLogin = CheckRow(title: "Launch at Login")
    private let checksForUpdates = CheckRow(title: "Check for Updates Automatically")
    private let statusLine = NSMenuItem()

    init(controller: SleepController) {
        self.controller = controller
        super.init()
        buildMenu()
        statusItem.menu = menu
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = Self.showsMenuBarItem
        visibilityObservation = statusItem.observe(\.isVisible) { item, _ in
            let visible = item.isVisible
            Task { @MainActor in
                if Self.showsMenuBarItem != visible { SettingsView.store.set(visible, forKey: SettingsView.showMenuBarItemKey) }
            }
        }
        // The main queue also drains while a menu is tracking; RunLoop.main would hold updates until it closes.
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    private static var showsMenuBarItem: Bool {
        SettingsView.store.object(forKey: SettingsView.showMenuBarItemKey) as? Bool ?? true
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(SectionHeader.item(topic: .lidOpen, panel: infoPanel))
        menu.addItem(lidOpenKeepAwake.item)
        menu.addItem(.separator())
        menu.addItem(SectionHeader.item(topic: .lidClosed, panel: infoPanel))
        menu.addItem(lidClosedKeepAwake.item)
        menu.addItem(lidSleepDisplay.item)
        menu.addItem(lidLockScreen.item)
        menu.addItem(.separator())
        menu.addItem(autoOff.item)
        menu.addItem(launchAtLogin.item)
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let version = NSMenuItem(title: Self.versionLine, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(checksForUpdates.item)
        menu.addItem(actionItem("Check for Updates…", action: #selector(checkForUpdates)))
        // macOS 26 adds a gear to items whose action is named like openSettings, indenting the whole group.
        menu.addItem(actionItem("Settings…", key: ",", action: #selector(showAmpedWindow)))
        menu.addItem(actionItem("Quit Amped", key: "q", action: #selector(quit)))

        lidOpenKeepAwake.onChange = { [weak self] in self?.controller.setKeepAwake($0) }
        lidClosedKeepAwake.onChange = { [weak self] on in
            guard let self, !controller.setLidClosedQuietly(on) else { return }
            // Without the helper this shows an alert or a password prompt, which can't run inside an open menu.
            menu.cancelTracking()
            DispatchQueue.main.async { self.controller.setLidClosed(on) }
        }
        lidSleepDisplay.onChange = { [weak self] in self?.controller.setLidSleepDisplay($0) }
        lidLockScreen.onChange = { [weak self] in self?.controller.setLidLockScreen($0) }
        autoOff.onChange = { [weak self] in self?.controller.setAutoOff($0) }
        launchAtLogin.onChange = { [weak self] in self?.controller.setLaunchAtLogin($0) }
        checksForUpdates.onChange = { UserDefaults.standard.set($0, forKey: AppUpdater.checksAutomaticallyKey) }
    }

    private func actionItem(_ title: String, key: String = "", action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refresh() {
        statusItem.isVisible = Self.showsMenuBarItem
        updateIcon()
        lidOpenKeepAwake.isOn = controller.keepAwake
        lidClosedKeepAwake.isOn = controller.lidClosed
        lidSleepDisplay.isOn = controller.lidSleepDisplay
        lidLockScreen.isOn = controller.lidLockScreen
        autoOff.isOn = controller.autoOff
        launchAtLogin.isOn = controller.launchAtLogin
        checksForUpdates.isOn = UserDefaults.standard.bool(forKey: AppUpdater.checksAutomaticallyKey)
        statusLine.title = controller.statusText
    }

    private func updateIcon() {
        let configuration = controller.menuBarSymbolDimmed ? NSImage.SymbolConfiguration.preferringHierarchical() : nil
        var image = NSImage(systemSymbolName: controller.menuBarSymbolName, accessibilityDescription: "Amped")
        if let configuration { image = image?.withSymbolConfiguration(configuration) }
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refreshStatus()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        infoPanel.hide(animated: false)
    }

    @objc private func checkForUpdates() { AppUpdater.check(manual: true) }
    @objc private func showAmpedWindow() { AppDelegate.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return version.hasSuffix("-local") ? "Amped \(version) — LOCAL BUILD" : "Amped \(version)"
    }

#if DEBUG
    // Pops the real menu up mid-screen, optionally highlighting a row, and writes its window to a PNG.
    // This grabs the mouse and keyboard while the menu is open, so it's only for when the user has agreed to it.
    func snapshot(to output: URL) {
        guard let screen = NSScreen.main else { return }
        let highlight = UserDefaults.standard.integer(forKey: "menuSnapshotHighlight")
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                if highlight > 0, highlight < self.menu.items.count {
                    self.menu.perform(NSSelectorFromString("highlightItem:"), with: self.menu.items[highlight])
                }
                if UserDefaults.standard.bool(forKey: "menuSnapshotPanel"), let header = self.menu.items[3].view {
                    self.infoPanel.show(.lidClosed, from: header.subviews.last ?? header, pinned: true)
                }
            }
        }
        let capture = Timer(timeInterval: 2.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                let windows = NSApp.windows.filter { $0.isVisible && $0.frame.height > 100 }
                for (index, window) in windows.enumerated() {
                    guard let image = SettingsSnapshot.image(of: window) else { continue }
                    let url = index == 0 ? output : output.deletingPathExtension().appendingPathExtension("\(index).png")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    if UserDefaults.standard.bool(forKey: "menuSnapshotDump"), let view = window.contentView { Self.dump(view, depth: 0) }
                }
                exit(0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(capture, forMode: .common)
        if UserDefaults.standard.bool(forKey: "menuSnapshotLight") { NSApp.appearance = NSAppearance(named: .aqua) }
        menuWillOpen(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY + 300), in: nil)
    }

    private static func dump(_ view: NSView, depth: Int) {
        let frame = view.window == nil ? "" : NSStringFromRect(view.convert(view.bounds, to: nil))
        print(String(repeating: "  ", count: depth) + "\(type(of: view)) \(frame) hidden=\(view.isHidden)")
        for subview in view.subviews { dump(subview, depth: depth + 1) }
    }

    // Lays the custom rows and the info panel out in windows parked off-screen and writes them to PNGs.
    // Nothing appears on screen and no input is taken, so it's safe while other work is going on.
    func previewSnapshot(to output: URL) {
        if UserDefaults.standard.bool(forKey: "menuSnapshotLight") { NSApp.appearance = NSAppearance(named: .aqua) }
        let rows: [NSView] = [
            SectionHeader.item(topic: .lidClosed, panel: infoPanel).view!,
            SwitchRow(title: "Keep Awake", on: true).item.view!,
            { let row = CheckRow(title: "Sleep Display", on: true); row.debugHighlight(); return row.item.view! }(),
            CheckRow(title: "Lock Screen", on: false).item.view!,
            CheckRow(title: "Launch at Login", on: true).item.view!,
        ]
        let height = rows.reduce(CGFloat(12)) { $0 + $1.frame.height }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 400, width: Metrics.width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        window.contentView = background
        var y = height - 6
        for (index, row) in rows.enumerated() {
            y -= row.frame.height
            row.frame = NSRect(x: 0, y: y, width: Metrics.width, height: row.frame.height)
            if index == 2 {
                // Stand-in for the selection macOS paints behind a highlighted item.
                let selection = NSView(frame: row.frame.insetBy(dx: 5, dy: 0))
                selection.wantsLayer = true
                selection.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                selection.layer?.cornerRadius = 7
                background.addSubview(selection)
            }
            background.addSubview(row)
        }
        window.orderFrontRegardless()
        if let button = rows[0].subviews.compactMap({ $0 as? HelpButton }).first {
            button.debugHover()
            infoPanel.show(.lidClosed, from: button, pinned: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for (window, url) in [(window, output), (self.infoPanel.window, output.deletingPathExtension().appendingPathExtension("panel.png"))] {
                if let image = SettingsSnapshot.image(of: window) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
            exit(0)
        }
    }
#endif
}

private enum Metrics {
    static let leading: CGFloat = 24
    static let trailing: CGFloat = 16
    // Where macOS 26 puts the checkmark of a standard item, and its row height.
    static let checkCenterX: CGFloat = 14.5
    static let checkRowHeight: CGFloat = 24
    static let rowHeight: CGFloat = 26
    static let headerHeight: CGFloat = 24
    static let width: CGFloat = 300
}

// Hover and press handling for menu rows. AppKit only hands clicks to a custom view while its item is
// highlighted, and macOS 26 paints the selection behind every highlighted item, custom or not. Rows that
// shouldn't light up (switches, section headers) are disabled items, so they notice presses by watching
// the mouse button while the pointer is over them.
private class PressableView: NSView {
    var onPress: (() -> Void)?
    private(set) var isHovering = false
    private var pollTimer: Timer?
    private var buttonIsDown = false

    func hoverDidChange() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovering else { return }
        isHovering = true
        buttonIsDown = Self.buttonIsDown
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Menus track in their own run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        hoverDidChange()
    }

    override func mouseExited(with event: NSEvent) { endHover() }

    // Highlighted items get the event directly; the button state keeps it from counting twice.
    override func mouseDown(with event: NSEvent) {
        if pollTimer != nil {
            guard !buttonIsDown else { return }
            buttonIsDown = true
        }
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {}

    private func poll() {
        // A closing menu doesn't always send mouseExited.
        guard let window, window.isVisible,
              bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
        else { return endHover() }
        let down = Self.buttonIsDown
        if down, !buttonIsDown { onPress?() }
        buttonIsDown = down
    }

    private func endHover() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isHovering else { return }
        isHovering = false
        hoverDidChange()
    }

    private static var buttonIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

#if DEBUG
    func debugHover() {
        isHovering = true
        hoverDidChange()
    }
#endif
}

@MainActor
private final class SwitchRow: NSObject {
    let item = NSMenuItem()
    var onChange: ((Bool) -> Void)?

    private let toggle: MenuSwitch

    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }

    init(title: String, on: Bool = false) {
        toggle = MenuSwitch(title: title)
        super.init()
        toggle.isOn = on
        toggle.onToggle = { [weak self] in self?.onChange?($0) }

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let view = PressableView(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.rowHeight))
        view.onPress = { [weak self] in self?.toggle.performToggle() }
        view.autoresizingMask = [.width]
        for subview in [label, toggle] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.leading),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.trailing),
            toggle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        item.view = view
        // The switch is the affordance; a selection highlight behind it would swallow its accent color.
        item.isEnabled = false
    }
}

// A checkmark item drawn as a view, so it toggles without closing the menu. macOS paints the selection
// behind it like any other item; the row draws the standard checkmark and turns its text white on top.
@MainActor
private final class CheckRow: NSObject {
    let item = NSMenuItem()
    var onChange: ((Bool) -> Void)?

    private let view: CheckRowView

    var isOn: Bool {
        get { view.isOn }
        set { view.setOn(newValue, animated: false) }
    }

    init(title: String, on: Bool = false) {
        view = CheckRowView(title: title)
        super.init()
        view.setOn(on, animated: false)
        view.onPress = { [weak self] in
            guard let self else { return }
            view.setOn(!view.isOn, animated: true)
            onChange?(view.isOn)
        }
        item.view = view
    }

#if DEBUG
    func debugHighlight() { view.forcesHighlight = true }
#endif
}

private final class CheckRowView: PressableView {
    private(set) var isOn = false
    var forcesHighlight = false { didSet { restyle() } }

    private let label: NSTextField
    private let check = NSImageView()

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.checkRowHeight))
        autoresizingMask = [.width]
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        // The same symbol and configuration macOS 26 uses for a standard item's checkmark.
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold, scale: .small))
        check.wantsLayer = true
        check.isHidden = true

        for subview in [check, label] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.checkCenterX),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.leading),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn || check.isHidden == on else { return }
        isOn = on
        check.isHidden = !on
        guard animated, on, let layer = check.layer else { return }
        // The checkmark pops in from its own center.
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, 0.4, 0.4, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let scale = CASpringAnimation(keyPath: "transform")
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        scale.damping = 14
        scale.stiffness = 300
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        layer.add(scale, forKey: "pop")
        layer.add(fade, forKey: "fade")
    }

    override func accessibilityValue() -> Any? { isOn }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func hoverDidChange() { restyle() }

    // Keyboard highlighting redraws the item without any hover.
    override func viewWillDraw() {
        super.viewWillDraw()
        restyle()
    }

    private func restyle() {
        let lit = forcesHighlight || isHovering || enclosingMenuItem?.isHighlighted == true
        let color: NSColor = lit ? .selectedMenuItemTextColor : .labelColor
        if label.textColor != color { label.textColor = color }
        if check.contentTintColor != color { check.contentTintColor = color }
    }
}

// Menu windows never become key, so NSSwitch always draws its on state gray inside a menu.
// This draws the active small switch, with the accent color and the same slide.
private final class MenuSwitch: NSView {
    var onToggle: ((Bool) -> Void)?

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            updateLayers(animated: window?.isVisible == true)
        }
    }

    private static let size: NSSize = {
        let reference = NSSwitch()
        reference.controlSize = .small
        return reference.fittingSize
    }()

    private let track = CALayer()
    private let knob = CALayer()

    init(title: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.shadowOpacity = 0.3
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(title)
        updateLayers(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }

    // Clicks fall through to the row, which toggles.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func performToggle() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func accessibilityValue() -> Any? { isOn }

    override func accessibilityPerformPress() -> Bool {
        performToggle()
        return true
    }

    override func layout() {
        super.layout()
        updateLayers(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers(animated: false)
    }

    private func updateLayers(animated: Bool) {
        let bounds = self.bounds
        let inset: CGFloat = 2
        let knobHeight = bounds.height - inset * 2
        let knobWidth = (bounds.width * 0.6).rounded()
        let knobX = isOn ? bounds.width - inset - knobWidth : inset

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        knob.frame = CGRect(x: knobX, y: inset, width: knobWidth, height: knobHeight)
        knob.cornerRadius = knobHeight / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let offTrack = dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.1)
            track.backgroundColor = (isOn ? NSColor.controlAccentColor : offTrack).cgColor
            knob.backgroundColor = NSColor(white: 1, alpha: isOn ? 0.92 : 0.9).cgColor
        }
        CATransaction.commit()
    }
}

@MainActor
private enum SectionHeader {
    static func item(topic: HelpTopic, panel: InfoPanel) -> NSMenuItem {
        let label = NSTextField(labelWithString: topic.title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let button = HelpButton(topic: topic, panel: panel)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.headerHeight))
        view.autoresizingMask = [.width]
        for subview in [label, button] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.leading),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),
            button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
            button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])

        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }
}

// The ? next to a section title. Hovering lights it up and opens the explanation after a moment;
// pressing opens it straight away and keeps it open until the next press or the menu closes.
private final class HelpButton: PressableView {
    private static let size = NSSize(width: 18, height: 18)
    private static let hoverDelay: TimeInterval = 0.3

    private let topic: HelpTopic
    private unowned let panel: InfoPanel
    private let icon = NSImageView()
    private var hoverTimer: Timer?

    init(topic: HelpTopic, panel: InfoPanel) {
        self.topic = topic
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        onPress = { [weak self] in self?.toggle() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("About \(topic.title) settings")
        setAccessibilityHelp(topic.plainText)
        panel.addObserver { [weak self] in self?.updateLook() }
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }

    private var isOpen: Bool { panel.isShowing(topic) }

    private func updateLook() {
        let lit = isHovering || isOpen
        icon.image = NSImage(systemSymbolName: lit ? "questionmark.circle.fill" : "questionmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = isOpen && panel.isPinned ? .controlAccentColor : lit ? .labelColor : .secondaryLabelColor
    }

    override func hoverDidChange() {
        updateLook()
        hoverTimer?.invalidate()
        if isHovering {
            let timer = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isHovering, !self.isOpen else { return }
                    self.panel.show(self.topic, from: self, pinned: false)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else if isOpen, !panel.isPinned {
            panel.hide()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        hoverTimer?.invalidate()
        if isOpen, panel.isPinned {
            panel.hide()
        } else {
            panel.show(topic, from: self, pinned: true)
        }
    }
}

// The explanation beside the menu, placed like a submenu: to the right, or to the left when there's no room.
@MainActor
private final class InfoPanel {
    let window: NSPanel
    private(set) var isPinned = false
    private var shownTitle: String?
    private var observers: [() -> Void] = []
    private var contents: [String: (view: NSView, size: NSSize)] = [:]

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
    }

    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }

    func isShowing(_ topic: HelpTopic) -> Bool { shownTitle == topic.title }

    func show(_ topic: HelpTopic, from anchor: NSView, pinned: Bool) {
        defer { observers.forEach { $0() } }
        isPinned = pinned
        guard !isShowing(topic), let menuWindow = anchor.window else { return }
        let wasShowing = shownTitle != nil
        shownTitle = topic.title

        let content = contents[topic.title] ?? Self.makeContent(for: topic)
        contents[topic.title] = content
        window.appearance = anchor.effectiveAppearance
        window.contentView = content.view
        let (frame, opensLeft) = Self.frame(for: content.size, beside: anchor, in: menuWindow)
        window.setFrame(frame, display: true)
        window.level = NSWindow.Level(rawValue: menuWindow.level.rawValue + 1)
        window.orderFront(nil)

        guard !wasShowing, let layer = content.view.layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = CATransform3DMakeTranslation(opensLeft ? 6 : -6, 0, 0)
        slide.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "show")
    }

    func hide(animated: Bool = true) {
        guard shownTitle != nil else { return }
        shownTitle = nil
        isPinned = false
        observers.forEach { $0() }
        guard animated, let layer = window.contentView?.layer else {
            window.orderOut(nil)
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownTitle == nil else { return }
                self.window.orderOut(nil)
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.12
        layer.opacity = 0
        layer.add(fade, forKey: "hide")
        CATransaction.commit()
    }

    private static func frame(for size: NSSize, beside anchor: NSView, in menuWindow: NSWindow) -> (NSRect, opensLeft: Bool) {
        let gap: CGFloat = 6
        let menuFrame = menuWindow.frame
        let row = anchor.superview ?? anchor
        let rowTop = menuWindow.convertToScreen(row.convert(row.bounds, to: nil)).maxY
        var frame = NSRect(x: menuFrame.maxX + gap, y: rowTop + 6 - size.height, width: size.width, height: size.height)
        var opensLeft = false
        if let visible = menuWindow.screen?.visibleFrame {
            if frame.maxX > visible.maxX - gap {
                frame.origin.x = menuFrame.minX - gap - size.width
                opensLeft = true
            }
            frame.origin.y = min(max(frame.minY, visible.minY + gap), visible.maxY - gap - size.height)
        }
        return (frame, opensLeft)
    }

    private static func makeContent(for topic: HelpTopic) -> (view: NSView, size: NSSize) {
        let width: CGFloat = 264
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.isSelectable = false
            field.preferredMaxLayoutWidth = width
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            return field
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(label(topic.title, size: 13, weight: .semibold, color: .labelColor))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews[0])
        for entry in topic.entries {
            let group = NSStackView(views: [
                label(entry.name, size: 12, weight: .semibold, color: .labelColor),
                label(entry.text, size: 12, color: .secondaryLabelColor),
            ])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            stack.addArrangedSubview(group)
        }
        if let note = topic.note {
            let divider = NSBox()
            divider.boxType = .separator
            divider.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(divider)
            stack.addArrangedSubview(label(note, size: 11, color: .secondaryLabelColor))
        }
        let size = stack.fittingSize

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 16
        glass.contentView = stack
        glass.wantsLayer = true
        return (glass, size)
    }
}

struct HelpTopic {
    let title: String
    let entries: [(name: String, text: String)]
    var note: String?

    var plainText: String {
        (entries.map { "\($0.name): \($0.text)" } + [note].compactMap { $0 }).joined(separator: "\n\n")
    }

    static let lidOpen = HelpTopic(title: "Lid Open", entries: [
        ("Keep Awake", "Stops your Mac and its screen from sleeping while you're away. Use it for long downloads, builds, presentations, or an agent you're watching."),
    ])

    static let lidClosed = HelpTopic(title: "Lid Closed", entries: [
        ("Keep Awake", "Keeps your Mac running with the lid closed, so SSH, downloads, and agents keep going. Needs Amped's helper or your password, and turns off when Amped quits."),
        ("Sleep Display", "Turns the screen off when the lid closes. Turn it off when a computer-use agent needs to see the screen; Amped keeps it on at zero brightness instead."),
        ("Lock Screen", "Locks your Mac when the lid closes. Turn it off only when an agent needs the desktop, since computer use can't get past the lock screen."),
    ], note: "These two only apply while Keep Awake is on and no external display is connected. macOS can still lock when the display sleeps, depending on your Lock Screen settings.")
}
