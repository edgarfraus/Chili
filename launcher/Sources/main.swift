import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit lifecycle (rather than SwiftUI's App) so that opening a .vv file or a
/// spice:// link can hand it straight to the viewer without showing any window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var openedDocumentsAtLaunch = false
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.mainMenu = MainMenu.build(target: self)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        NotificationCenter.default.addObserver(forName: .viewerFailed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.showMainWindow()
                self?.model.present(note.object as? Error)
            }
        }
        NotificationCenter.default.addObserver(forName: .viewerExited, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitIfIdle() }
        }
        if !openedDocumentsAtLaunch { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Documents and URLs

    func application(_ application: NSApplication, open urls: [URL]) {
        if !finishedLaunching { openedDocumentsAtLaunch = true }
        for url in urls { open(url) }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if !finishedLaunching { openedDocumentsAtLaunch = true }
        open(url)
    }

    private func open(_ url: URL) {
        do {
            if url.isFileURL {
                try ViewerLauncher.shared.launch(arguments: [url.path])
            } else if ["spice", "spice+tls", "spice+unix"].contains(url.scheme?.lowercased() ?? "") {
                try ViewerLauncher.shared.launch(arguments: [url.absoluteString])
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            showMainWindow()
            model.present(error)
        }
    }

    /// When the app was only started to open a .vv file, leave once the viewer closes.
    private func quitIfIdle() {
        guard openedDocumentsAtLaunch, UserDefaults.standard.bool(forKey: Prefs.quitAfterLaunch),
              !ViewerLauncher.shared.hasRunningViewers, mainWindow?.isVisible != true else { return }
        NSApp.terminate(nil)
    }

    // MARK: Windows

    @objc func showMainWindow() {
        openedDocumentsAtLaunch = false
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "SPICE Client"
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(model).environmentObject(model.profiles))
            window.setFrameAutosaveName("MainWindow")
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = NSLocalizedString("Settings", comment: "")
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vv") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a .vv connection file (for example one downloaded from Proxmox)", comment: "")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @objc func newServer(_ sender: Any?) {
        showMainWindow()
        model.editingProfile = ServerProfile()
    }

    @objc func quickConnect(_ sender: Any?) {
        showMainWindow()
        model.selection = .quickConnect
    }

    @objc func openGuide(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.guideURL)
    }

    @objc func openLogs(_ sender: Any?) {
        NSWorkspace.shared.open(ViewerLauncher.shared.logDir)
    }
}

enum AppInfo {
    static var guideURL: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "SCProjectURL") as? String ?? "https://github.com"
        return URL(string: s)!
    }
}

enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let name = "SPICE Client"
        func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  _ t: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = t
            return i
        }

        let app = NSMenu(title: name)
        app.addItem(item(String(format: L("About %@"), name), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item(L("Settings…"), #selector(AppDelegate.showSettings), ",", .command, target))
        app.addItem(.separator())
        app.addItem(item(String(format: L("Hide %@"), name), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(String(format: L("Quit %@"), name), #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: L("File"))
        file.addItem(item(L("New Proxmox Server…"), #selector(AppDelegate.newServer(_:)), "n", .command, target))
        file.addItem(item(L("Quick Connect…"), #selector(AppDelegate.quickConnect(_:)), "k", .command, target))
        file.addItem(item(L("Open Connection File…"), #selector(AppDelegate.openDocument(_:)), "o", .command, target))
        file.addItem(.separator())
        file.addItem(item(L("Close Window"), #selector(NSWindow.performClose(_:)), "w"))

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(item(L("Undo"), Selector(("undo:")), "z"))
        edit.addItem(item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(L("Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(L("Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(L("Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(L("Select All"), #selector(NSText.selectAll(_:)), "a"))

        let window = NSMenu(title: L("Window"))
        window.addItem(item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L("Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(L("Connections"), #selector(AppDelegate.showMainWindow), "0", .command, target))
        NSApp.windowsMenu = window

        let help = NSMenu(title: L("Help"))
        help.addItem(item(L("SPICE Client Guide"), #selector(AppDelegate.openGuide(_:)), "?", .command, target))
        help.addItem(item(L("Show Viewer Logs"), #selector(AppDelegate.openLogs(_:)), "", .command, target))
        NSApp.helpMenu = help

        for menu in [app, file, edit, window, help] {
            let holder = NSMenuItem()
            holder.submenu = menu
            main.addItem(holder)
        }
        return main
    }
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
