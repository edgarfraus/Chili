import AppKit
import SwiftUI
import WebKit

/// One open console: either the native SPICE display or Proxmox' own web
/// console (noVNC for VMs, xterm.js for containers and node shells). It lives
/// in the main window (sidebar → "Consoles") or in its own window; its view
/// moves between the two.
@MainActor
final class ConsoleSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    /// The view shown for this console (CSDisplayView or WKWebView).
    let displayView: NSView
    let spiceView: CSDisplayView?
    private let webView: WKWebView?
    var isWeb: Bool { webView != nil }

    /// SPICE: fetches fresh connection options (Proxmox tickets are single-use).
    private let reconnectOptions: (() async throws -> ViewerConfig)?
    /// SPICE: extra detail for the "Disconnected" message (the SPICE tunnel's last error).
    private let diagnostic: (() -> String?)?
    /// Web: fresh login cookie + URL, since Proxmox tickets expire.
    private let webReload: (() async throws -> (URL, HTTPCookie?))?
    /// Web: certificate pinned by the user for this server.
    private let trustedHost: (host: String, port: Int)?
    /// Web: with headers for the Proxmox host (a Cloudflare Access service token) the page goes through
    /// this proxy, which adds them to every request. WKWebView could only add them to navigations, not
    /// to the console's WebSocket, and Access sets no cookie for a service token.
    private let webProxy: WebConsoleProxy?

    @Published private(set) var connection: CSConnection?
    @Published private(set) var state: CSConnectionState = .connecting
    @Published private(set) var errorMessage: String?
    @Published private(set) var pointerCaptured = false
    @Published private(set) var mouseMode: CSMouseMode = .server
    @Published private(set) var agentConnected = false
    @Published var window: ConsoleWindowController?

    init(config: ViewerConfig, title: String, reconnect: (() async throws -> ViewerConfig)? = nil,
         diagnostic: (() -> String?)? = nil) {
        self.title = title
        self.diagnostic = diagnostic
        let view = CSDisplayView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        spiceView = view
        displayView = view
        webView = nil
        reconnectOptions = reconnect
        webReload = nil
        trustedHost = nil
        webProxy = nil
        super.init()
        view.captureChanged = { [weak self] captured in self?.pointerCaptured = captured }
        attach(Self.makeConnection(config))
    }

    init(webTitle: String, host: String, port: Int, headers: [String: String] = [:],
         load: @escaping () async throws -> (URL, HTTPCookie?)) {
        title = webTitle
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView = web
        displayView = web
        spiceView = nil
        reconnectOptions = nil
        diagnostic = nil
        webReload = load
        trustedHost = (host, port)
        webProxy = headers.isEmpty ? nil
            : WebConsoleProxy(host: host, port: port, headers: headers, accepts: ConsoleSession.certificateCheck(host: host, port: port))
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        loadWeb()
    }

    private static func makeConnection(_ config: ViewerConfig) -> CSConnection {
        var options: [String: String] = [:]
        for (k, v) in config.entries { options[k] = v }
        return CSConnection(options: options)
    }

    private var observer: NSObjectProtocol?

    private func attach(_ c: CSConnection) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        connection = c
        observer = NotificationCenter.default.addObserver(forName: .CSConnectionDidChange, object: c, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        applyPreferences()
        spiceView?.connection = c
        c.connect()
        refresh()
    }

    private func refresh() {
        guard let connection else { return }
        state = connection.state
        errorMessage = connection.errorMessage
        if state == .disconnected, let extra = diagnostic?() {
            errorMessage = [errorMessage, extra].compactMap { $0 }.joined(separator: "\n")
        }
        mouseMode = connection.mouseMode
        agentConnected = connection.agentConnected
    }

    func applyPreferences() {
        let d = UserDefaults.standard
        spiceView?.resizeGuestToFit = d.bool(forKey: Prefs.resizeGuest)
        spiceView?.useRetinaResolution = d.bool(forKey: Prefs.retinaResolution)
        connection?.shareClipboard = d.bool(forKey: Prefs.shareClipboard)
    }

    func reconnect() {
        guard state == .disconnected else { return }
        if isWeb { return loadWeb() }
        state = .connecting
        errorMessage = nil
        Task {
            do {
                let config: ViewerConfig
                if let reconnectOptions {
                    config = try await reconnectOptions()
                } else {
                    config = ViewerConfig(options: connection?.options ?? [:])
                }
                attach(Self.makeConnection(config))
            } catch {
                state = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect() {
        spiceView?.releasePointer()
        connection?.disconnect()
        webView?.loadHTMLString("", baseURL: nil)
        webProxy?.stop()
    }

    func sendCtrlAltDel() {
        guard let spiceView else { return }
        connection?.sendCtrlAltDel()
        spiceView.window?.makeFirstResponder(spiceView)
    }

    // MARK: Web console

    private func loadWeb() {
        guard let webView, let webReload else { return }
        state = .connecting
        errorMessage = nil
        Task {
            do {
                var (url, cookie) = try await webReload()
                if let webProxy {
                    let port = try await webProxy.start()
                    url = WebConsoleProxy.local(url, port: port)
                    cookie = cookie.flatMap {
                        HTTPCookie(properties: [.name: $0.name, .value: $0.value, .domain: "127.0.0.1", .path: "/"])
                    }
                }
                if let cookie {
                    await webView.configuration.websiteDataStore.httpCookieStore.setCookieAsync(cookie)
                }
                webView.load(URLRequest(url: url))
            } catch {
                state = .disconnected
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Proxmox' certificate for the console proxy, as for the API: valid, or the one the user pinned.
    /// Runs on the proxy's queue.
    private nonisolated static func certificateCheck(host: String, port: Int) -> (SecTrust) -> Bool {
        { trust in
            if SecTrustEvaluateWithError(trust, nil) { return true }
            guard let fp = ProxmoxClient.fingerprint(of: trust) else { return false }
            return TrustStore.isTrusted(fp, host: host, port: port)
        }
    }
}

extension ConsoleSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state = .connected
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webFailed(error)
    }

    private func webFailed(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled { return }
        state = .disconnected
        errorMessage = error.localizedDescription
    }

    /// Proxmox' self-signed certificate: accept it only if the user pinned it.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        if let pinned = trustedHost, let fp = ProxmoxClient.fingerprint(of: trust),
           TrustStore.isTrusted(fp, host: pinned.host, port: pinned.port) {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// The console page opens nothing else; links (e.g. docs) go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }
}

private extension WKHTTPCookieStore {
    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { cont in setCookie(cookie) { cont.resume() } }
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

    /// A container with no size of its own, so SwiftUI sizes it to the pane
    /// (otherwise the display could inflate the whole window's content).
    final class FlexibleContainer: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }

    func makeNSView(context: Context) -> NSView {
        let container = FlexibleContainer()
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            container.setContentHuggingPriority(.init(1), for: orientation)
            container.setContentCompressionResistancePriority(.init(1), for: orientation)
        }
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.displayView.superview !== container { adopt(into: container) }
    }

    private func adopt(into container: NSView) {
        let v = session.displayView
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
                if !session.isWeb {
                    Button { session.sendCtrlAltDel() } label: { Label("Ctrl+Alt+Del", systemImage: "command.square") }
                        .help("Send Ctrl+Alt+Del")
                        .disabled(session.state != .connected)
                }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            } else if session.mouseMode == .server && !session.isWeb {
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
        let size = session.connection?.displaySize ?? .zero
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
        session.spiceView?.releasePointer()
    }
}
