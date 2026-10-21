#if DEBUG
import AppKit

@MainActor
enum SettingsSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "settingsSnapshot").map { URL(filePath: $0) }

    static func capture(to output: URL, openSettings: () -> Void) async {
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        openSettings()
        let window = await settingsWindow()
        window.setFrameOrigin(NSPoint(x: -4000, y: 0))
        try? await Task.sleep(for: .seconds(1.5))
        guard let image = image(of: window) else { exit(1) }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
        exit(0)
    }

    // cacheDisplay skips Liquid Glass; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }

    private static func settingsWindow() async -> NSWindow {
        while true {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) { return window }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
