import AppKit
import SwiftUI

// The panel's screens. Layout, chrome and navigation follow OpenUsage's dashboard
// (MIT, Copyright (c) 2026 Robin Ebers); see THIRD_PARTY_NOTICES.md.

struct PanelRootView: View {
    @Environment(PanelNavigation.self) private var navigation
    @Environment(\.reduceAnimations) private var reduceAnimations
    /// The height the window follows; 0 until the open screen has been measured.
    @State private var animatedHeight: CGFloat = 0
    @State private var didEstablishHeight = false
    @State private var heights = PanelHeightCoordinator()
    @State private var slideProgress: CGFloat = 1
    @State private var animatedSlideID = 0

    var body: some View {
        pager
            .frame(width: PanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.traySurface)
            .drivesPanelHeight(animatedHeight)
            .background(
                PopoverKeyReader(
                    onEscape: {
                        guard navigation.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { navigation.screen = .dashboard }
                        return true
                    },
                    onSettings: {
                        withAnimation(Motion.modeSwitch) {
                            navigation.screen = navigation.screen == .settings ? .dashboard : .settings
                        }
                        return true
                    }
                )
            )
            .onChange(of: navigation.isShown) { _, shown in
                if shown {
                    // The tree survives a close, so seed the height for the screen being opened.
                    if let target = heights.target(for: navigation.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                } else {
                    animatedHeight = 0
                    didEstablishHeight = false
                    if navigation.screen != .dashboard {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { navigation.screen = .dashboard }
                    }
                }
            }
            .onChange(of: navigation.screenSlideID) { _, id in
                guard id != 0 else { return }
                if reduceAnimations || !navigation.isShown {
                    animatedSlideID = id
                    slideProgress = 1
                    if navigation.isShown, let target = heights.target(for: navigation.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                    return
                }
                // Pin to the outgoing screen for one render, then spring to the new one on the next
                // tick; setting both in one closure collapses to no animation.
                slideProgress = 0
                animatedSlideID = id
                let destination = navigation.screen
                Task { @MainActor in
                    // The height morphs on the same spring as the slide.
                    let target = heights.target(for: destination) ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if target != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let target { animatedHeight = target }
                    } completion: {
                        guard let target = heights.target(for: navigation.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.spring) { animatedHeight = target }
                        }
                    }
                }
            }
            // Content growing or shrinking within a screen re-targets the height on the same spring.
            .onChange(of: heights.measuredIdeal[navigation.screen]) { _, _ in
                guard let target = heights.target(for: navigation.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
    }

    private var isSliding: Bool {
        !reduceAnimations
            && navigation.screenSlideID != 0
            && (navigation.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// Both pages are mounted side by side only while sliding; at rest just the current one is.
    private var pages: [PanelScreen] {
        guard isSliding else { return [navigation.screen] }
        let from = navigation.screenSlideFrom
        let to = navigation.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    /// An offset slide rather than a transition: a fading page is composited into a transparency layer,
    /// which makes the card fills flash.
    private func slideOffset(_ pages: [PanelScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let width = PanelMetrics.width
        let from = -CGFloat(pages.firstIndex(of: navigation.screenSlideFrom) ?? 0) * width
        let to = -CGFloat(pages.firstIndex(of: navigation.screen) ?? 0) * width
        let progress = animatedSlideID == navigation.screenSlideID ? slideProgress : 0
        return from + progress * (to - from)
    }

    private var pager: some View {
        let pages = pages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(pages, id: \.self) { screen in
                screenView(screen)
                    .frame(width: PanelMetrics.width)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: PanelMetrics.width, alignment: .leading)
        .offset(x: slideOffset(pages))
        .animation(nil, value: navigation.screenSlideID)
    }

    /// Each page carries its own bars, so they travel with it during a slide.
    @ViewBuilder
    private func screenView(_ screen: PanelScreen) -> some View {
        Group {
            switch screen {
            case .dashboard: DashboardScreen()
            case .settings: SettingsScreen()
            }
        }
        .onPreferenceChange(ScrollContentHeightKey.self) { height in
            heights.setScrollContent(height, for: screen)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            if screen == .settings {
                PanelTopBar(title: "Settings") {
                    withAnimation(Motion.modeSwitch) { navigation.screen = .dashboard }
                }
            }
        }
    }
}

// MARK: - Dashboard

private struct DashboardScreen: View {
    @EnvironmentObject private var controller: SleepController

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                StatusCard()

                GroupSection(title: "Lid Open", symbol: "sun.max", help: HelpText.lidOpen) {
                    SettingRow("Keep Awake") {
                        Toggle("Keep Awake", isOn: Binding(
                            get: { controller.keepAwake },
                            set: { controller.setKeepAwake($0) }
                        ))
                        .settingsSwitchStyle()
                    }
                }

                GroupSection(
                    title: "Lid Closed",
                    symbol: "moon",
                    subtitle: controller.lidClosed ? "On" : nil,
                    help: HelpText.lidClosed
                ) {
                    SettingRow("Keep Awake") {
                        Toggle("Keep Awake", isOn: Binding(
                            get: { controller.lidClosed },
                            set: { on in
                                Task {
                                    if await controller.setLidClosedQuietly(on) { return }
                                    // An alert or a password prompt would open behind the panel.
                                    MenuBarPopover.dismissThen { Task { await controller.setLidClosed(on) } }
                                }
                            }
                        ))
                        .settingsSwitchStyle()
                    }
                    Divider().padding(.horizontal, 12)
                    // What happens to the screen; still adjustable while lid mode is off, but dimmed.
                    Group {
                        SettingRow("Sleep Display") {
                            Toggle("Sleep Display", isOn: Binding(
                                get: { controller.lidSleepDisplay },
                                set: { controller.setLidSleepDisplay($0) }
                            ))
                            .settingsSwitchStyle()
                        }
                        SettingRow("Lock Screen") {
                            Toggle("Lock Screen", isOn: Binding(
                                get: { controller.lidLockScreen },
                                set: { controller.setLidLockScreen($0) }
                            ))
                            .settingsSwitchStyle()
                        }
                    }
                    .opacity(controller.lidClosed ? 1 : 0.55)
                    .animation(Motion.hover, value: controller.lidClosed)
                }

                GroupSection(title: "Battery", symbol: "battery.75percent", help: HelpText.battery) {
                    SettingRow("Auto-off at 20%") {
                        Toggle("Auto-off at 20%", isOn: Binding(
                            get: { controller.autoOff },
                            set: { controller.setAutoOff($0) }
                        ))
                        .settingsSwitchStyle()
                    }
                }

                HStack {
                    Spacer()
                    OptionsMenu()
                }
            }
            .padding(.horizontal, PanelMetrics.outerPadding)
            .padding(.vertical, 14)
        }
    }
}

/// What Restless is doing right now, at a glance. Its height never changes, so the groups below don't
/// shift when the state does.
private struct StatusCard: View {
    @EnvironmentObject private var controller: SleepController

    private static let iconSize: CGFloat = 34

    private var isAwake: Bool { controller.keepAwake || controller.lidClosed }

    private var symbol: String {
        if controller.lidClosed { return "eye.fill" }
        if controller.keepAwake { return "eye" }
        return "eye.slash"
    }

    private var title: String {
        if controller.lidClosed { return "Awake with the lid closed" }
        if controller.keepAwake { return "Awake" }
        return "Sleep allowed"
    }

    private var subtitle: String {
        if controller.lidClosed {
            let screen = controller.lidSleepDisplay ? "screen off" : "screen on"
            let lock = controller.lidLockScreen ? "locked" : "unlocked"
            return "When shut: \(screen), \(lock)"
        }
        if controller.keepAwake { return "Your Mac and screen stay on" }
        return "Your Mac sleeps as usual"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isAwake ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isAwake ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: Self.iconSize, height: Self.iconSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    if let percent = controller.batteryPercent {
                        battery(percent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .contentTransition(.opacity)
        }
        .frame(height: Self.iconSize)
        .padding(12)
        .cardSurface()
        .animation(Motion.spring, value: symbol)
        .animation(Motion.spring, value: subtitle)
        .animation(Motion.spring, value: controller.batteryPercent)
    }

    private func battery(_ percent: Int) -> some View {
        HStack(spacing: 4) {
            if !controller.onBattery {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text("\(percent)%")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(percent)))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
        .hoverTooltip(controller.onBattery ? "On battery" : "Charging")
    }
}

// MARK: - Settings

private struct SettingsScreen: View {
    @EnvironmentObject private var controller: SleepController
    @Environment(PanelNavigation.self) private var navigation
    @AppStorage(SettingsView.showMenuBarItemKey, store: SettingsView.store) private var showMenuBarItem = true
    @ObservedObject private var updater = Updater.shared

    private var helperFootnote: String {
        if controller.helperEnabled {
            return "Lid Closed Keep Awake turns on and off without asking for your password."
        }
        if controller.helperNeedsApproval {
            return "The helper is off in Login Items & Extensions. Turn Restless on there, and the lid toggle won't ask for your password."
        }
        return "Without the helper, turning Lid Closed Keep Awake on or off asks for your password."
    }

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                SettingsSection("General") {
                    SettingRow("Launch at Login") {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { controller.launchAtLogin },
                            set: { controller.setLaunchAtLogin($0) }
                        ))
                        .settingsSwitchStyle()
                    }
                    SettingRow("Show in Menu Bar") {
                        Toggle("Show in Menu Bar", isOn: $showMenuBarItem).settingsSwitchStyle()
                    }
                    Footnote("When hidden, open Restless again to show its settings.")
                }

                SettingsSection("Lid Closed") {
                    SettingRow("Background Helper") {
                        if controller.helperEnabled {
                            Label("On", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .symbolRenderingMode(.hierarchical)
                        } else {
                            Button(controller.helperNeedsApproval ? "Turn On…" : "Set Up…") {
                                MenuBarPopover.dismissThen { controller.setUpHelper() }
                            }
                            .controlSize(.small)
                        }
                    }
                    Footnote(helperFootnote)
                }

                SettingsSection("Updates") {
                    SettingRow("Version") {
                        HStack(spacing: 6) {
                            if AppVersion.isLocalBuild {
                                Text("Local build")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                            Text(AppVersion.display)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    SettingRow("Check Automatically") {
                        Toggle("Check Automatically", isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.setAutomaticallyChecks($0) }
                        ))
                        .settingsSwitchStyle()
                    }
                    HStack(spacing: 8) {
                        Button {
                            MenuBarPopover.dismissThen { Updater.shared.checkForUpdates() }
                        } label: {
                            Text("Check Now").frame(maxWidth: .infinity)
                        }
                        .hoverTooltip("Looks for a newer version and installs it")
                        Button {
                            MenuBarPopover.dismissThen(AboutPanel.present)
                        } label: {
                            Text("About Restless").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, PanelMetrics.outerPadding)
            .padding(.vertical, 12)
        }
        .onChange(of: navigation.screen) { _, screen in
            if screen == .settings { controller.refreshStatus() }
        }
    }
}

// MARK: - Building blocks

/// A dashboard group: an icon and title over a card, like a provider in OpenUsage.
private struct GroupSection<Content: View>: View {
    let title: String
    let symbol: String
    var subtitle: String?
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 16)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                if let help { HelpButton(text: help) }
            }
            .padding(.leading, 2)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .animation(Motion.spring, value: subtitle)

            VStack(spacing: 0) { content }
                .padding(.vertical, 3)
                .cardSurface()
        }
    }
}

/// A Settings group: a small caption over a card.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) { content }.cardSurface()
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
    }
}

/// The ? beside a group title. Hovering shows the explanation after the usual dwell; clicking shows it
/// straight away.
private struct HelpButton: View {
    let text: String

    var body: some View {
        HelpButtonLabel().hoverTooltip(text)
    }
}

private struct HelpButtonLabel: View {
    @Environment(\.tooltipShowNow) private var showNow
    @State private var isHovering = false

    var body: some View {
        Button {
            showNow?()
        } label: {
            Image(systemName: isHovering ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .accessibilityLabel("About these settings")
    }
}

// MARK: - Chrome

private struct PanelTopBar: View {
    let title: String
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .hoverTooltip("Back")
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, PanelMetrics.outerPadding)
        .frame(height: PanelMetrics.topBarHeight)
        .frame(maxWidth: .infinity)
        .barGlass()
    }
}

/// Settings, updates, About and Quit, in the panel's bottom corner.
private struct OptionsMenu: View {
    @Environment(PanelNavigation.self) private var navigation

    var body: some View {
        // `.glass` renders flat on a Menu, so the glass goes on the container instead.
        Menu {
            Button {
                withAnimation(Motion.modeSwitch) { navigation.screen = .settings }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Button {
                MenuBarPopover.dismissThen { Updater.shared.checkForUpdates() }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                MenuBarPopover.dismissThen(AboutPanel.present)
            } label: {
                Label("About Restless", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Restless", systemImage: "power")
            }
            .keyboardShortcut("q")
        } label: {
            HStack(spacing: 5) {
                Text("Options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .interactiveGlass(in: Capsule())
    }
}

enum AppVersion {
    private static let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let isLocalBuild = raw.hasSuffix("-local")
    static var display: String { isLocalBuild ? String(raw.dropLast("-local".count)) : raw }
}

@MainActor
enum AboutPanel {
    static func present() {
        let credits = NSAttributedString(
            string: "Keeps your Mac awake, even with the lid closed.\nBased on Amped by Gustaf Eriksson; panel adapted from OpenUsage. Both MIT licensed.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
        )
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

// MARK: - Help text

enum HelpText {
    static let lidOpen = """
    **Keep Awake** stops your Mac and its screen from going to sleep while you're away. Turn it on for long downloads, builds, presentations, or an agent you're watching.
    """

    static let lidClosed = """
    **Keep Awake** keeps your Mac running with the lid closed, so SSH, downloads, and agents keep going. It needs the Restless helper or your password, and turns off when you quit Restless.

    **Sleep Display** turns the screen off when the lid closes. Turn it off when a computer-use agent needs to see the screen; Restless keeps it on at zero brightness instead.

    **Lock Screen** locks your Mac when the lid closes. Turn it off only when an agent needs the desktop, since computer use can't get past the lock screen.

    These two apply only while Keep Awake is on and no external display is connected.
    """

    static let battery = """
    **Auto-off at 20%** turns keep-awake off when your Mac is on battery at 20% or less, so it can still sleep before the battery runs out.
    """
}
