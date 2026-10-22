import SwiftUI

struct AboutSettings: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Restless")
                .font(.title.bold())
            Text("Version \(version) (\(build))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Keeps your Mac awake, even with the lid closed.")
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }
}
