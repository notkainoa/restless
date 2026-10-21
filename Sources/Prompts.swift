import AppKit

enum HelperSetupChoice {
    case setUpHelper
    case justThisTime
    case cancel
}

enum Prompts {
    @MainActor
    static func offerHelperSetup() -> HelperSetupChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Keep the Mac awake with the lid closed?"
        alert.informativeText = """
        This needs a small background helper that runs with elevated rights. \
        macOS will ask you to approve “Amped” once under Login Items & \
        Extensions — after that the lid toggle never asks for a password.

        Prefer not to? “Just This Time” keeps the Mac awake now with a single \
        password prompt instead.
        """
        alert.addButton(withTitle: "Set Up Helper…")
        alert.addButton(withTitle: "Just This Time")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .setUpHelper
        case .alertSecondButtonReturn: return .justThisTime
        default: return .cancel
        }
    }

    @MainActor
    static func explainHelperApproval() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Approve Amped’s background helper"
        alert.informativeText = """
        In the window that just opened (Login Items & Extensions), turn on \
        “Amped”. Then turn on Lid Closed Keep Awake again; it won't ask for a password after that.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
