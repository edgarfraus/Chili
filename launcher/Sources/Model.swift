import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case quickConnect
    case server(UUID)
    case console(UUID)
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    let profiles = ProfileStore()
    let updater = Updater()
    @Published var selection: SidebarItem? = .quickConnect
    @Published var editingProfile: ServerProfile?
    @Published var alert: AlertInfo?
    @Published private(set) var consoles: [ConsoleSession] = []

    private var sessions: [UUID: ServerSession] = [:]
    /// Called when the main window must be shown (a console was added to it).
    var showMainWindow: (() -> Void)?

    init() {
        if let first = profiles.profiles.first { selection = .server(first.id) }
    }

    func session(for profile: ServerProfile) -> ServerSession {
        if let s = sessions[profile.id], s.profile == profile { return s }
        let s = ServerSession(profile: profile, app: self)
        sessions[profile.id] = s
        return s
    }

    /// - Parameter accessSecret: new Cloudflare Access client secret, or nil to keep the stored one.
    func save(_ profile: ServerProfile, secret: String?, accessSecret: String? = nil) {
        // The service token is needed to reach the server at all: always kept (not tied to rememberSecret).
        if profile.accessClientId.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.delete(account: profile.accessAccount)
        } else if let accessSecret, !accessSecret.isEmpty {
            Keychain.save(accessSecret, account: profile.accessAccount)
        }
        profiles.upsert(profile)
        if let secret, !secret.isEmpty, profile.rememberSecret {
            Keychain.save(secret, account: profile.id.uuidString)
        } else if !profile.rememberSecret {
            Keychain.delete(account: profile.id.uuidString)
        }
        sessions[profile.id] = nil
        selection = .server(profile.id)
    }

    func delete(_ profile: ServerProfile) {
        profiles.delete(profile)
        sessions[profile.id] = nil
        if selection == .server(profile.id) { selection = .quickConnect }
    }

    // MARK: Consoles

    enum Placement { case mainWindow, window, standalone }

    /// Opens a SPICE console. `.standalone` is for .vv files: a bare window, no main window.
    func openConsole(config: ViewerConfig, title: String, placement: Placement? = nil,
                     reconnect: (() async throws -> ViewerConfig)? = nil,
                     diagnostic: (() -> String?)? = nil) {
        if UserDefaults.standard.bool(forKey: Prefs.useClassicViewer) {
            do { try ViewerLauncher.shared.launch(config: config, title: title) } catch { present(error) }
            return
        }
        let session = ConsoleSession(config: config, title: config["title"] ?? title, reconnect: reconnect,
                                     diagnostic: diagnostic)
        consoles.append(session)
        let wantsFullScreen = config["fullscreen"] == "1" || UserDefaults.standard.bool(forKey: Prefs.fullscreen)
        let where_ = placement ?? (UserDefaults.standard.string(forKey: Prefs.consolePlacement) == "window"
                                   ? .window : .mainWindow)
        switch where_ {
        case .mainWindow where !wantsFullScreen:
            selection = .console(session.id)
            showMainWindow?()
        default:
            detach(session, fullScreen: wantsFullScreen)
        }
    }

    /// Opens Proxmox' own web console (noVNC / xterm.js) inside Chili.
    func openWebConsole(title: String, host: String, port: Int, headers: [String: String] = [:],
                        placement: Placement? = nil, load: @escaping () async throws -> (URL, HTTPCookie?)) {
        let session = ConsoleSession(webTitle: title, host: host, port: port, headers: headers, load: load)
        consoles.append(session)
        let where_ = placement ?? (UserDefaults.standard.string(forKey: Prefs.consolePlacement) == "window"
                                   ? .window : .mainWindow)
        if where_ == .mainWindow {
            selection = .console(session.id)
            showMainWindow?()
        } else {
            detach(session)
        }
    }

    func detach(_ session: ConsoleSession, fullScreen: Bool = false) {
        if session.window == nil {
            session.window = ConsoleWindowController(session: session, model: self)
        }
        session.window?.showWindow(nil)
        if fullScreen, let w = session.window?.window, !w.styleMask.contains(.fullScreen) {
            DispatchQueue.main.async { w.toggleFullScreen(nil) }
        }
        if selection == .console(session.id) { selection = consoles.last(where: { $0.window == nil }).map { .console($0.id) } ?? .quickConnect }
    }

    func attachToMainWindow(_ session: ConsoleSession) {
        guard let controller = session.window else { return }
        session.window = nil
        controller.window?.delegate = nil
        controller.close()
        selection = .console(session.id)
        showMainWindow?()
    }

    func close(_ session: ConsoleSession) {
        session.disconnect()
        if let controller = session.window {
            session.window = nil
            controller.window?.delegate = nil
            controller.close()
        }
        // Move the selection away first and drop the console on the next turn:
        // changing both in one update left NavigationView with an empty detail pane.
        if selection == .console(session.id) {
            selection = consoles.last(where: { $0 !== session }).map { .console($0.id) } ?? .quickConnect
        }
        DispatchQueue.main.async {
            self.consoles.removeAll { $0 === session }
            NotificationCenter.default.post(name: .consolesChanged, object: nil)
        }
    }

    func consoleWindowClosed(_ controller: ConsoleWindowController) {
        // Closing a console window closes that console.
        controller.session.window = nil
        close(controller.session)
    }

    func disconnectAll() {
        for c in consoles { c.disconnect() }
    }

    func present(_ error: Error?) {
        guard let error else { return }
        if ProcessInfo.processInfo.environment["CHILI_DEBUG_ACTION"] != nil {
            DebugActions.log("alert: \(error.localizedDescription)")
        }
        alert = AlertInfo(title: NSLocalizedString("Something went wrong", comment: ""),
                          message: error.localizedDescription)
    }
}

/// One point of a VM's resource history.
struct UsageSample {
    let date: Date
    let cpu: Double          // 0…1 of the VM's vCPUs
    let memory: Double       // 0…1 of its RAM
    let netIn: Double        // bytes/s
    let netOut: Double
}

/// Login state and VM list of one Proxmox server.
@MainActor
final class ServerSession: ObservableObject {
    enum State: Equatable {
        case loggedOut
        case needsOTP
        case working
        case ready
    }

    let profile: ServerProfile
    private weak var app: AppModel?
    private let client: ProxmoxClient

    @Published var state = State.loggedOut
    @Published var vms: [ProxmoxVM] = []
    @Published var busyVM: String?
    @Published var lastError: String?
    @Published var pendingCertificate: String?
    @Published var lastRefresh: Date?
    /// Recent usage per VM id, newest last (about 5 minutes).
    @Published var history: [String: [UsageSample]] = [:]
    private var lastNetCounters: [String: (date: Date, netIn: Int64, netOut: Int64)] = [:]
    static let refreshInterval: TimeInterval = 5
    private static let historyLength = 60

    private var password = ""
    private var refreshTimer: Timer?

    /// - Parameter accessSecret: debug only — a Cloudflare Access secret used instead of the Keychain's.
    init(profile: ServerProfile, app: AppModel, accessSecret: String? = nil) {
        self.profile = profile
        self.app = app
        accessSecretOverride = accessSecret
        client = ProxmoxClient(host: profile.host, port: profile.port)
        client.extraHeaders = Self.accessHeaders(profile, secret: accessSecret)
        if Demo.isOn {
            vms = Demo.vms
            state = .ready
            for vm in vms where vm.isRunning {
                let rate = Double(vm.vmid % 7 + 1) * 37_000
                history[vm.id] = [UsageSample(date: Date(), cpu: vm.cpu ?? 0,
                                              memory: Double(vm.mem ?? 0) / Double(vm.maxmem ?? 1),
                                              netIn: rate * 3.1, netOut: rate)]
            }
        }
    }

    var storedSecret: String? { Keychain.load(account: profile.id.uuidString) }
    /// For the VM wizard and VM actions.
    var api: ProxmoxClient { client }

    func connectWithStoredSecret() {
        if Demo.isOn { return }
        // Dev aid: UI tests without touching the Keychain or the server.
        if ProcessInfo.processInfo.environment["CHILI_DEBUG_NO_LOGIN"] != nil { return }
        guard state == .loggedOut, let secret = storedSecret else { return }
        login(secret: secret)
    }

    func login(secret: String, otp: String? = nil) {
        if !secret.isEmpty { password = secret }
        state = .working
        lastError = nil
        Task {
            do {
                switch profile.authMethod {
                case .password:
                    try await client.login(username: profile.fullUsername, password: password, otp: otp)
                case .token:
                    try await client.useToken(id: profile.tokenID, secret: password)
                }
                if profile.rememberSecret { Keychain.save(password, account: profile.id.uuidString) }
                try await reload()
                state = .ready
                startAutoRefresh()
            } catch ProxmoxError.needsTOTP {
                state = .needsOTP
            } catch ProxmoxError.untrustedCertificate(_, let fp) {
                pendingCertificate = fp
                state = .loggedOut
            } catch {
                lastError = error.localizedDescription
                state = otp == nil ? .loggedOut : .needsOTP
            }
        }
    }

    func trustPendingCertificate() {
        guard let fp = pendingCertificate else { return }
        TrustStore.trust(fp, host: profile.host, port: profile.port)
        pendingCertificate = nil
        login(secret: password.isEmpty ? (storedSecret ?? "") : password)
    }

    func logout() {
        refreshTimer?.invalidate()
        spiceTunnel?.stop()
        spiceTunnel = nil
        state = .loggedOut
        vms = []
        password = ""
    }

    deinit { spiceTunnel?.stop() }

    private var spiceTunnel: TcpOverWebSocket?
    private let accessSecretOverride: String?

    /// The local end of the Cloudflare Tunnel to spiceproxy, if this server uses one.
    var tunnel: TcpOverWebSocket? {
        let host = profile.spiceTunnelHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        if spiceTunnel == nil { spiceTunnel = TcpOverWebSocket(host: host, headers: Self.accessHeaders(profile, spice: true, secret: accessSecretOverride)) }
        return spiceTunnel
    }

    /// Cloudflare Access service token headers for the Proxmox hostname, or (spice) for the SPICE
    /// tunnel hostname when the user chose to send the token there too.
    static func accessHeaders(_ profile: ServerProfile, spice: Bool = false, secret override: String? = nil) -> [String: String] {
        if spice && !profile.spiceTunnelUsesAccess { return [:] }
        let id = profile.accessClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !Demo.isOn, let secret = override ?? Keychain.load(account: profile.accessAccount), !secret.isEmpty
        else { return [:] }
        return ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
    }

    /// A SPICE ticket for the VM, routed through the Cloudflare Tunnel when configured.
    func spiceConfig(for vm: ProxmoxVM) async throws -> ViewerConfig {
        var config = try await client.spiceConfig(for: vm)
        if let tunnel {
            let port = try await tunnel.start()
            config["proxy"] = "http://127.0.0.1:\(port)"
        }
        return config
    }

    /// The tunnel's last error, for the console's "Disconnected" message.
    var tunnelDiagnostic: (() -> String?)? {
        guard let tunnel else { return nil }
        let host = profile.spiceTunnelHost
        return {
            tunnel.lastError.map { String(format: NSLocalizedString("Cloudflare Tunnel (%@): %@", comment: ""), host, $0) }
        }
    }

    func reload() async throws {
        if Demo.isOn { return }
        vms = try await client.virtualMachines()
        lastRefresh = Date()
        recordUsage()
    }

    private func recordUsage() {
        let now = Date()
        for vm in vms {
            guard vm.isRunning else {
                history[vm.id] = nil
                lastNetCounters[vm.id] = nil
                continue
            }
            var netIn = 0.0, netOut = 0.0
            if let inBytes = vm.netin, let outBytes = vm.netout {
                if let last = lastNetCounters[vm.id], now.timeIntervalSince(last.date) > 0.5,
                   inBytes >= last.netIn, outBytes >= last.netOut {
                    let dt = now.timeIntervalSince(last.date)
                    netIn = Double(inBytes - last.netIn) / dt
                    netOut = Double(outBytes - last.netOut) / dt
                }
                lastNetCounters[vm.id] = (now, inBytes, outBytes)
            }
            let memory = (vm.maxmem ?? 0) > 0 ? Double(vm.mem ?? 0) / Double(vm.maxmem!) : 0
            let sample = UsageSample(date: now, cpu: min(max(vm.cpu ?? 0, 0), 1), memory: min(memory, 1),
                                     netIn: netIn, netOut: netOut)
            history[vm.id, default: []].append(sample)
            if history[vm.id]!.count > Self.historyLength { history[vm.id]!.removeFirst() }
        }
    }

    func refresh() {
        Task {
            do { try await reload() } catch { lastError = error.localizedDescription }
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in try? await self?.reload() }
        }
    }

    /// Opens the VM's console, starting the VM first if needed.
    func connect(_ vm: ProxmoxVM, placement: AppModel.Placement? = nil) {
        busyVM = vm.id
        Task {
            defer { busyVM = nil }
            do {
                if !vm.isRunning {
                    try await startAndWait(vm)
                }
                if vm.isContainer {
                    openWebConsole(.vm(vm), placement: placement)
                    return
                }
                let config: ViewerConfig
                do {
                    config = try await spiceConfig(for: vm)
                } catch ProxmoxError.noSpice {
                    // No SPICE display: fall back to Proxmox' noVNC console.
                    openWebConsole(.vm(vm), placement: placement)
                    return
                }
                app?.openConsole(config: config, title: "\(vm.displayName) (\(vm.vmid))", placement: placement,
                                 reconnect: { [self] in try await spiceConfig(for: vm) },
                                 diagnostic: tunnelDiagnostic)
            } catch {
                app?.present(error)
            }
        }
    }

    /// noVNC for VMs, xterm.js for containers and node shells, served by Proxmox.
    func openWebConsole(_ kind: ProxmoxClient.WebConsoleKind, placement: AppModel.Placement? = nil) {
        guard client.usesTicket else {
            app?.present(ProxmoxError.http(0, NSLocalizedString(
                "The noVNC and shell consoles need a password login: Proxmox' web pages can't use API tokens.",
                comment: "")))
            return
        }
        let title: String
        switch kind {
        case .vm(let vm): title = "\(vm.displayName) (\(vm.vmid))"
        case .nodeShell(let node): title = String(format: NSLocalizedString("Shell – %@", comment: ""), node)
        }
        let client = self.client
        let username = profile.fullUsername
        app?.openWebConsole(title: title, host: client.host, port: client.port, headers: client.extraHeaders,
                            placement: placement) {
            try? await client.renewTicket(username: username)
            return (try client.webConsoleURL(kind), client.authCookie())
        }
    }

    func loadNodes() async -> [String] {
        (try? await client.nodes()) ?? Array(Set(vms.map(\.node))).sorted()
    }

    /// Shutdown, reboot, stop… then refresh the list.
    func power(_ vm: ProxmoxVM, _ action: ProxmoxClient.PowerAction) {
        busyVM = vm.id
        Task {
            defer { busyVM = nil }
            do {
                let upid = try await client.power(vm, action)
                try await client.waitForTask(node: vm.node, upid: upid, timeout: 180)
                try await reload()
            } catch {
                app?.present(error)
            }
        }
    }

    /// Deletes a VM or container with its disks (it must be stopped).
    func delete(_ vm: ProxmoxVM) {
        busyVM = vm.id
        Task {
            defer { busyVM = nil }
            do {
                if vm.isRunning {
                    let stop = try await client.power(vm, .stop)
                    try await client.waitForTask(node: vm.node, upid: stop, timeout: 120)
                }
                let upid = try await client.delete(vm)
                try await client.waitForTask(node: vm.node, upid: upid)
                try await reload()
            } catch {
                app?.present(error)
            }
        }
    }

    func start(_ vm: ProxmoxVM) {
        busyVM = vm.id
        Task {
            defer { busyVM = nil }
            do {
                try await startAndWait(vm)
            } catch {
                app?.present(error)
            }
        }
    }

    /// Starts the VM and waits for Proxmox' start task, so its real error (if any) is shown.
    private func startAndWait(_ vm: ProxmoxVM) async throws {
        let upid = try await client.power(vm, .start)
        try await client.waitForTask(node: vm.node, upid: upid, timeout: 120)
        try await waitUntilRunning(vm)
    }

    private func waitUntilRunning(_ vm: ProxmoxVM) async throws {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await reload()
            if vms.first(where: { $0.id == vm.id })?.isRunning == true {
                // Give QEMU a moment to open the SPICE port.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return
            }
        }
        throw ProxmoxError.http(0, NSLocalizedString("The VM did not start within 30 seconds.", comment: ""))
    }
}

extension Notification.Name {
    static let consolesChanged = Notification.Name("ChiliConsolesChanged")
}
