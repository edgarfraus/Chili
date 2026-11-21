import AppKit
import SwiftUI

/// One open SPICE console. It lives either in the main window (sidebar →
/// "Consoles") or in its own window; the display view moves between the two.
@MainActor
final class ConsoleSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let view = CSDisplayView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
    /// Fetches fresh connection options (Proxmox tickets are single-use).
    private let reconnectOptions: (() async throws -> ViewerConfig)?

    @Published private(set) var connection: CSConnection
    @Published private(set) var state: CSConnectionState = .connecting
    @Published private(set) var errorMessage: String?
    @Published private(set) var pointerCaptured = false
    @Published private(set) var mouseMode: CSMouseMode = .server
    @Published private(set) var agentConnected = false
    @Published var window: ConsoleWindowController?

    init(config: ViewerConfig, title: String, reconnect: (() async throws -> ViewerConfig)? = nil) {
        self.title = title
        self.reconnectOptions = reconnect
        connection = Self.makeConnection(config)
        view.captureChanged = { [weak self] captured in self?.pointerCaptured = captured }
        applyPreferences()
        attach(connection)
    }

    private static func makeConnection(_ config: ViewerConfig) -> CSConnection {
        var options: [String: String] = [:]
        for (k, v) in config.entries { options[k] = v }
        return CSConnection(options: options)
    }

    private var observer: NSObjectProtocol?

    private func attach(_ c: CSConnection) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .CSConnectionDidChange, object: c, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        view.connection = c
        c.connect()
        refresh()
    }

    private func refresh() {
        state = connection.state
        errorMessage = connection.errorMessage
        mouseMode = connection.mouseMode
        agentConnected = connection.agentConnected
    }

    func applyPreferences() {
        let d = UserDefaults.standard
        view.resizeGuestToFit = d.bool(forKey: Prefs.resizeGuest)
        view.useRetinaResolution = d.bool(forKey: Prefs.retinaResolution)
        connection.shareClipboard = d.bool(forKey: Prefs.shareClipboard)
    }

    var canReconnect: Bool { state == .disconnected }

    func reconnect() {
        guard state == .disconnected else { return }
        state = .connecting
        errorMessage = nil
        Task {
            do {
                let config: ViewerConfig
                if let reconnectOptions {
                    config = try await reconnectOptions()
                } else {
                    config = ViewerConfig(options: connection.options)
                }
                connection = Self.makeConnection(config)
                applyPreferences()
                attach(connection)
            } catch {
                state = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        view.releasePointer()
        connection.disconnect()
    }

    func sendCtrlAltDel() {
        connection.sendCtrlAltDel()
        view.window?.makeFirstResponder(view)
    }
}

extension ViewerConfig {
    init(options: [String: String]) {
        self.init()
        entries = options.map { ($0.key, $0.value) }
    }
}

// MARK: - SwiftUI

/// Hosts the session's single CSDisplayView instance.
struct DisplayViewHost: NSViewRepresentable {
    let session: ConsoleSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { adopt(into: container) }
    }

    private func adopt(into container: NSView) {
        let v = session.view
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}

struct ConsoleView: View {
    @ObservedObject var session: ConsoleSession
    /// In the main window we offer "open in window"; in a console window, "move to main window".
    var inMainWindow: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if session.window != nil && inMainWindow {
                detachedPlaceholder
            } else {
                DisplayViewHost(session: session)
                overlay
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { session.sendCtrlAltDel() } label: { Label("Ctrl+Alt+Del", systemImage: "command.square") }
                    .help("Send Ctrl+Alt+Del")
                    .disabled(session.state != .connected)
                if inMainWindow {
                    Button { model.detach(session) } label: { Label("Open in Window", systemImage: "macwindow.on.rectangle") }
                        .help("Open this console in a separate window")
                    Button { model.detach(session, fullScreen: true) } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Full screen")
                } else {
                    Button { model.attachToMainWindow(session) } label: {
                        Label("Move to Main Window", systemImage: "rectangle.stack")
                    }
                    .help("Move this console back to the main window")
                }
                Button { model.close(session) } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    .help("Disconnect and close this console")
            }
        }
        .navigationTitle(Text(verbatim: session.title))
    }

    @ViewBuilder private var overlay: some View {
        switch session.state {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Connecting…").foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected:
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundColor(.white.opacity(0.7))
                Text("Disconnected").font(.title3.bold()).foregroundColor(.white)
                if let error = session.errorMessage {
                    Text(verbatim: error).foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                HStack {
                    Button("Reconnect") { session.reconnect() }.keyboardShortcut(.defaultAction)
                    Button("Close") { model.close(session) }
                }
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.75)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if session.pointerCaptured {
                Text("Press Ctrl+Alt to release the mouse")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .foregroundColor(.white)
                    .padding(.top, 10)
                    .transition(.opacity)
            } else if session.mouseMode == .server {
                Text("Click inside to control the mouse")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var detachedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow").font(.system(size: 40)).foregroundColor(.white.opacity(0.6))
            Text("This console is open in a separate window.").foregroundColor(.white)
            HStack {
                Button("Show Window") { session.window?.showWindow(nil) }
                Button("Move Here") { model.attachToMainWindow(session) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Console window

/// A window showing one console: used for "open in window" and for .vv files.
@MainActor
final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    let session: ConsoleSession
    private weak var model: AppModel?

    init(session: ConsoleSession, model: AppModel) {
        self.session = session
        self.model = model
        let size = session.connection.displaySize
        let initial = size.width > 0 ? NSSize(width: size.width, height: size.height) : NSSize(width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.title
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ConsoleView(session: session, inMainWindow: false)
            .environmentObject(model))
        window.setFrameAutosaveName("ConsoleWindow")
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model?.consoleWindowClosed(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        session.view.releasePointer()
    }
}
