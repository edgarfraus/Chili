import AppKit
import SwiftUI

/// About Chili: version, updates (check now, automatic checks), links, the bundled components and their
/// versions, and the folders Chili uses. Same content as the Windows Info page.
struct InfoView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true

    private static let project = "https://github.com/\(Updates.repository)"
    private var version: String { Updates.format(Updater.current) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                UpdatesCard(updater: model.updater, checkForUpdates: $checkForUpdates)
                card("Links") {
                    link("Project page", Self.project)
                    link("What's new in this version", "\(Self.project)/releases/tag/v\(version)")
                    link("All releases", "\(Self.project)/releases")
                    link("Report a problem", "\(Self.project)/issues")
                    link("Source code", Self.project)
                }
                card("Components") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.components, id: \.0) { name, value in
                            HStack(alignment: .firstTextBaseline, spacing: 24) {
                                Text(verbatim: name).frame(width: 200, alignment: .leading)
                                Text(verbatim: value).foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    caption("Chili is free software under the GNU GPL, version 2 or later. Each release ships the source of every bundled component.")
                }
                card("Folders") {
                    HStack(spacing: 8) {
                        Button("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings() }
                        Button("Logs") { NSWorkspace.shared.open(ViewerLauncher.shared.logDir) }
                            .help(ViewerLauncher.shared.logDir.path)
                        Button("Program") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            .help(Bundle.main.bundleURL.path)
                    }
                    caption("Passwords and tokens are kept in your login Keychain.")
                }
            }
            .padding(EdgeInsets(top: 24, leading: 32, bottom: 32, trailing: 32))
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Info")
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Chili").font(.title.bold())
                Text(String(format: NSLocalizedString("Version %@ (%@)", comment: ""), version, Updates.arch))
                    .foregroundColor(.secondary).textSelection(.enabled)
                Text("An unofficial SPICE client and Proxmox VE companion").foregroundColor(.secondary)
            }
        }
    }

    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
        Link(title, destination: URL(string: url)!)
    }

    /// Versions of what Chili is made of: the SPICE stack (COMPONENTS.txt, written by bundle-app.sh) and macOS.
    static let components: [(String, String)] = {
        var list: [(String, String)] = []
        if let url = Bundle.main.url(forResource: "COMPONENTS", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let p = line.split(separator: "\t", maxSplits: 1)
                if p.count == 2 { list.append((String(p[0]), String(p[1]))) }
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        list.append(("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        return list
    }()
}

private struct UpdatesCard: View {
    @ObservedObject var updater: Updater
    @EnvironmentObject var model: AppModel
    @Binding var checkForUpdates: Bool

    var body: some View {
        card("Updates") {
            Text(verbatim: status)
                .foregroundColor(updater.lastError != nil && updater.pending == nil ? .red : .primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Check for Updates") { Task { await updater.checkNow() } }
                    .disabled(Demo.isOn || updater.isChecking || isBusy)
                if updater.pending != nil {
                    Button("What's New") { updater.openReleaseNotes() }
                    Button("Update Now") { updater.updateNow(model: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }
                if updater.isChecking { ProgressView().controlSize(.small) }
            }
            Toggle("Check for updates automatically", isOn: $checkForUpdates)
            if !Updater.canInstall {
                caption("This is a development build: updates are downloaded and verified, not installed.")
            }
        }
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .installing: return updater.pending != nil
        default: return false
        }
    }

    private var status: String {
        if Demo.isOn { return NSLocalizedString("Updates are not checked in this mode.", comment: "") }
        if updater.isChecking { return NSLocalizedString("Checking…", comment: "") }
        if let release = updater.pending {
            switch updater.phase {
            case .downloading: return NSLocalizedString("Downloading the update…", comment: "")
            case .installing: return NSLocalizedString("Installing…", comment: "")
            case .done(let s), .failed(let s): return s
            case .available:
                return String(format: NSLocalizedString("Chili %@ is available", comment: ""), release.versionString)
            }
        }
        if let error = updater.lastError {
            return String(format: NSLocalizedString("Couldn't check for updates: %@", comment: ""), error)
        }
        if let when = updater.lastChecked {
            let time = DateFormatter.localizedString(from: when, dateStyle: .none, timeStyle: .short)
            return String(format: NSLocalizedString("Chili is up to date (checked at %@).", comment: ""), time)
        }
        return NSLocalizedString("Not checked yet.", comment: "")
    }
}

/// A titled box, like the Windows cards.
private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }
}

private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
}
