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

    func save(_ profile: ServerProfile, secret: String?) {
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
                     reconnect: (() async throws -> ViewerConfig)? = nil) {
        if UserDefaults.standard.bool(forKey: Prefs.useClassicViewer) {
            do { try ViewerLauncher.shared.launch(config: config, title: title) } catch { present(error) }
            return
        }
        let session = ConsoleSession(config: config, title: config["title"] ?? title, reconnect: reconnect)
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
        consoles.removeAll { $0 === session }
        if selection == .console(session.id) { selection = consoles.last.map { .console($0.id) } ?? .quickConnect }
        NotificationCenter.default.post(name: .consolesChanged, object: nil)
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
    @Published private(set) var history: [String: [UsageSample]] = [:]
    private var lastNetCounters: [String: (date: Date, netIn: Int64, netOut: Int64)] = [:]
    static let refreshInterval: TimeInterval = 5
    private static let historyLength = 60

    private var password = ""
    private var refreshTimer: Timer?

    init(profile: ServerProfile, app: AppModel) {
        self.profile = profile
        self.app = app
        client = ProxmoxClient(host: profile.host, port: profile.port)
    }

    var storedSecret: String? { Keychain.load(account: profile.id.uuidString) }

    func connectWithStoredSecret() {
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
        state = .loggedOut
        vms = []
        password = ""
    }

    func reload() async throws {
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
                    try await client.start(vm)
                    try await waitUntilRunning(vm)
                }
                let config = try await client.spiceConfig(for: vm)
                let client = self.client
                app?.openConsole(config: config, title: "\(vm.displayName) (\(vm.vmid))", placement: placement,
                                 reconnect: { try await client.spiceConfig(for: vm) })
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
                try await client.start(vm)
                try await waitUntilRunning(vm)
            } catch {
                app?.present(error)
            }
        }
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
