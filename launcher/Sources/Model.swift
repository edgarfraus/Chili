import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case quickConnect
    case server(UUID)
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

    private var sessions: [UUID: ServerSession] = [:]

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

    func present(_ error: Error?) {
        guard let error else { return }
        alert = AlertInfo(title: NSLocalizedString("Something went wrong", comment: ""),
                          message: error.localizedDescription)
    }
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
    }

    func refresh() {
        Task {
            do { try await reload() } catch { lastError = error.localizedDescription }
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in try? await self?.reload() }
        }
    }

    /// Opens the VM's console, starting the VM first if needed.
    func connect(_ vm: ProxmoxVM) {
        busyVM = vm.id
        Task {
            defer { busyVM = nil }
            do {
                if !vm.isRunning {
                    try await client.start(vm)
                    try await waitUntilRunning(vm)
                }
                let config = try await client.spiceConfig(for: vm)
                try ViewerLauncher.shared.launch(config: config, title: "\(vm.displayName) (\(vm.vmid))")
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
