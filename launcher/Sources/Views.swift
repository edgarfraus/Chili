import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        // Selection-driven sidebar + a detail view that switches on the selection.
        // NavigationLink(tag:selection:) lost the detail column on macOS when
        // jumping between items, leaving an empty window.
        NavigationView {
            Sidebar()
            DetailView()
        }
        .frame(minWidth: 820, minHeight: 480)
        .sheet(item: $model.editingProfile) { profile in
            ServerEditor(profile: profile)
        }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(verbatim: info.message))
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        List(selection: $model.selection) {
            Label("Quick Connect", systemImage: "bolt.horizontal.circle")
                .tag(SidebarItem.quickConnect)

            Section(header: Text("Proxmox Servers")) {
                ForEach(store.profiles) { profile in
                    Label { Text(verbatim: profile.title) } icon: { Image(systemName: "server.rack") }
                        .tag(SidebarItem.server(profile.id))
                        .contextMenu {
                            Button("Edit…") { model.editingProfile = profile }
                            Button("Remove") { model.delete(profile) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.editingProfile = ServerProfile()
            } label: {
                Label("Add Server…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ProfileStore

    var body: some View {
        switch model.selection {
        case .quickConnect:
            QuickConnectView()
        case .server(let id):
            if let profile = store.profiles.first(where: { $0.id == id }) {
                ServerDetailView(session: model.session(for: profile))
                    .id(profile.id)
            } else {
                Placeholder()
            }
        case nil:
            Placeholder()
        }
    }
}

private struct Placeholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.secondary)
            Text("Pick a server or use Quick Connect")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Proxmox server

struct ServerDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ServerSession

    var body: some View {
        Group {
            switch session.state {
            case .ready:
                VMListView(session: session)
            case .working where session.vms.isEmpty:
                ProgressView("Connecting to \(session.profile.host)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                LoginView(session: session)
            }
        }
        .navigationTitle(Text(verbatim: session.profile.title))
        .toolbar {
            ToolbarItemGroup {
                if session.state == .ready {
                    Button { session.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh the VM list")
                    Button { session.logout() } label: { Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right") }
                        .help("Log out")
                }
                Button { model.editingProfile = session.profile } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    .help("Edit server")
            }
        }
        .onAppear { session.connectWithStoredSecret() }
        .alert(item: Binding(get: { session.pendingCertificate.map { CertPrompt(fingerprint: $0) } },
                             set: { if $0 == nil { session.pendingCertificate = nil } })) { prompt in
            Alert(title: Text("Untrusted certificate"),
                  message: Text("\(session.profile.host) uses a certificate that macOS doesn't trust. This is normal for Proxmox, which generates a self-signed certificate on install.\n\nCompare this SHA-256 fingerprint with the one shown in Proxmox under Node → System → Certificates:\n\n\(prompt.fingerprint)"),
                  primaryButton: .default(Text("Trust and Continue")) { session.trustPendingCertificate() },
                  secondaryButton: .cancel())
        }
    }
}

private struct CertPrompt: Identifiable {
    let fingerprint: String
    var id: String { fingerprint }
}

private struct LoginView: View {
    @ObservedObject var session: ServerSession
    @State private var secret = ""
    @State private var otp = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            Text(verbatim: session.profile.title).font(.title2.bold())
            Text(verbatim: session.profile.authMethod == .token ? session.profile.tokenID : session.profile.fullUsername)
                .foregroundColor(.secondary)

            Group {
                if session.state == .needsOTP {
                    TextField("Two-factor code", text: $otp)
                        .onSubmit(submit)
                    Text("Enter the 6-digit code from your authenticator app, or a recovery key.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    SecureField(session.profile.authMethod == .token ? LocalizedStringKey("Token secret") : LocalizedStringKey("Password"), text: $secret)
                        .onSubmit(submit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
            .focused($focused)

            if let error = session.lastError {
                Text(verbatim: error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(action: submit) {
                if session.state == .working { ProgressView().controlSize(.small) } else { Text("Log In") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.state == .working)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func submit() {
        if session.state == .needsOTP {
            session.login(secret: "", otp: otp)
            otp = ""
        } else {
            session.login(secret: secret.isEmpty ? (session.storedSecret ?? "") : secret)
        }
    }
}

private struct VMListView: View {
    @ObservedObject var session: ServerSession
    @State private var filter = ""
    @AppStorage("showStoppedVMs") private var showStopped = true

    private var shown: [ProxmoxVM] {
        session.vms.filter { vm in
            (showStopped || vm.isRunning) &&
            (filter.isEmpty || vm.displayName.localizedCaseInsensitiveContains(filter) || "\(vm.vmid)".contains(filter))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Toggle("Show stopped VMs", isOn: $showStopped)
                Spacer()
                if let error = session.lastError {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundColor(.orange).lineLimit(1)
                }
            }
            .padding(10)
            Divider()
            if shown.isEmpty {
                Text(session.vms.isEmpty ? LocalizedStringKey("No virtual machines on this server.") : LocalizedStringKey("No VMs match the filter."))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { vm in
                    VMRow(vm: vm, usage: session.history[vm.id] ?? [], busy: session.busyVM == vm.id,
                          connect: { session.connect(vm) }, start: { session.start(vm) })
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

private struct VMRow: View {
    let vm: ProxmoxVM
    let usage: [UsageSample]
    let busy: Bool
    let connect: () -> Void
    let start: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(vm.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .help(vm.status)
            Text(verbatim: "\(vm.vmid)")
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: vm.displayName).fontWeight(.medium)
                Text(verbatim: details).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if vm.isRunning {
                UsageView(vm: vm, samples: usage)
            }
            if busy {
                ProgressView().controlSize(.small)
            } else {
                if !vm.isRunning {
                    Button("Start", action: start)
                }
                Button(vm.isRunning ? LocalizedStringKey("Connect") : LocalizedStringKey("Start & Connect"), action: connect)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !busy { connect() } }
    }

    private var details: String {
        var parts = [vm.node]
        if let cpu = vm.maxcpu { parts.append(String(format: NSLocalizedString("%d vCPU", comment: ""), Int(cpu))) }
        if let mem = vm.maxmem { parts.append(ByteCountFormatter.string(fromByteCount: mem, countStyle: .memory)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Resource monitor

/// CPU sparkline, memory bar and network rate for one running VM.
private struct UsageView: View {
    let vm: ProxmoxVM
    let samples: [UsageSample]

    private var cpu: Double { samples.last?.cpu ?? vm.cpu ?? 0 }
    private var memory: Double {
        samples.last?.memory ?? ((vm.maxmem ?? 0) > 0 ? Double(vm.mem ?? 0) / Double(vm.maxmem!) : 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "CPU \(Int((cpu * 100).rounded()))%")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                Sparkline(values: samples.map(\.cpu))
                    .stroke(Self.color(for: cpu), lineWidth: 1.5)
                    .background(Sparkline(values: samples.map(\.cpu), closed: true)
                        .fill(Self.color(for: cpu).opacity(0.15)))
                    .frame(width: 80, height: 18)
            }
            .help(Text("CPU usage over the last 5 minutes"))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "RAM \(Self.bytes(vm.mem)) / \(Self.bytes(vm.maxmem))")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                Meter(value: memory, color: Self.color(for: memory))
                    .frame(width: 110, height: 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "↓ \(Self.rate(samples.last?.netIn))")
                Text(verbatim: "↑ \(Self.rate(samples.last?.netOut))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
            .frame(width: 78, alignment: .leading)
            .help(Text("Network traffic"))
        }
    }

    static func color(for fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.7 ? .orange : .accentColor
    }

    static func bytes(_ value: Int64?) -> String {
        ByteCountFormatter.string(fromByteCount: value ?? 0, countStyle: .memory)
    }

    static func rate(_ value: Double?) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value ?? 0), countStyle: .binary) + "/s"
    }
}

private struct Sparkline: Shape {
    let values: [Double]
    var closed = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return p
        }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - CGFloat(v) * rect.height)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

private struct Meter: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(geo.size.width * CGFloat(value), value > 0 ? 3 : 0))
            }
        }
    }
}

// MARK: - Server editor

struct ServerEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation
    @State var profile: ServerProfile
    @State private var secret = ""
    @State private var realms: [ProxmoxRealm] = []

    private var isNew: Bool { !model.profiles.profiles.contains { $0.id == profile.id } }
    private var canSave: Bool {
        !ProxmoxClient.normalizedHost(profile.host).isEmpty &&
        (profile.authMethod == .password ? !profile.username.isEmpty : profile.tokenID.contains("!"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? LocalizedStringKey("Add Proxmox Server") : LocalizedStringKey("Edit Proxmox Server")).font(.headline)
            Form {
                TextField("Name", text: $profile.name, prompt: Text("My homelab"))
                TextField("Host", text: $profile.host, prompt: Text("pve.example.com or 192.168.1.10"))
                TextField("Port", value: $profile.port, formatter: NumberFormatter())
                Picker("Log in with", selection: $profile.authMethod) {
                    Text("Password").tag(ServerProfile.AuthMethod.password)
                    Text("API token").tag(ServerProfile.AuthMethod.token)
                }
                .pickerStyle(.segmented)

                if profile.authMethod == .password {
                    TextField("User", text: $profile.username, prompt: Text(verbatim: "root"))
                    Picker("Realm", selection: $profile.realm) {
                        ForEach(realmChoices, id: \.self) { Text(realmLabel($0)).tag($0) }
                    }
                    SecureField("Password", text: $secret, prompt: isNew ? nil : Text("unchanged"))
                } else {
                    TextField("Token ID", text: $profile.tokenID, prompt: Text(verbatim: "user@pam!spice"))
                    SecureField("Secret", text: $secret, prompt: isNew ? nil : Text("unchanged"))
                }
                Toggle("Remember in Keychain", isOn: $profile.rememberSecret)
            }
            if profile.authMethod == .token {
                Text("The token needs the VM.Console and VM.Audit privileges (and VM.PowerMgmt to start VMs).")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !isNew {
                    Button("Remove Server", role: .destructive) {
                        model.delete(profile)
                        presentation.wrappedValue.dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? LocalizedStringKey("Add") : LocalizedStringKey("Save")) {
                    if let p = ProxmoxClient.port(in: profile.host) { profile.port = p }
                    profile.host = ProxmoxClient.normalizedHost(profile.host)
                    model.save(profile, secret: secret.isEmpty ? nil : secret)
                    presentation.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: profile.host) { await loadRealms() }
    }

    private var realmChoices: [String] {
        var names = realms.map(\.realm)
        for r in ["pam", "pve", profile.realm] where !names.contains(r) { names.append(r) }
        return names
    }

    private func realmLabel(_ realm: String) -> String {
        switch realm {
        case "pam": return NSLocalizedString("Linux PAM (pam)", comment: "")
        case "pve": return NSLocalizedString("Proxmox VE (pve)", comment: "")
        default:
            if let c = realms.first(where: { $0.realm == realm })?.comment, !c.isEmpty { return "\(c) (\(realm))" }
            return realm
        }
    }

    private func loadRealms() async {
        let host = ProxmoxClient.normalizedHost(profile.host)
        guard host.count > 3 else { return }
        try? await Task.sleep(nanoseconds: 600_000_000) // debounce typing
        let port = ProxmoxClient.port(in: profile.host) ?? profile.port
        guard let list = try? await ProxmoxClient(host: host, port: port).realms() else { return }
        realms = list
    }
}

// MARK: - Quick connect

struct QuickConnectView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("quick.host") private var host = ""
    @AppStorage("quick.port") private var port = 5900
    @AppStorage("quick.tls") private var tls = false
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Connect").font(.title2.bold())
                Text("Connect directly to a SPICE server, for example a QEMU or libvirt VM started with -spice port=5900.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Host", text: $host, prompt: Text(verbatim: "192.168.1.10"))
                TextField("Port", value: $port, formatter: NumberFormatter())
                Toggle("Use TLS (port is the TLS port)", isOn: $tls)
                SecureField("Password", text: $password, prompt: Text("optional"))
            }
            .frame(maxWidth: 420)
            HStack {
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Open Connection File…") { NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Using Proxmox?").font(.headline)
                Text("Add your server in the sidebar to list its VMs and connect with one click. You can also open the .vv files that Proxmox downloads when you choose Console → SPICE.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add Proxmox Server…") { model.editingProfile = ServerProfile() }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Quick Connect")
    }

    private func connect() {
        var config = ViewerConfig()
        config["host"] = host.trimmingCharacters(in: .whitespaces)
        config[tls ? "tls-port" : "port"] = String(port)
        if !password.isEmpty { config["password"] = password }
        do {
            try ViewerLauncher.shared.launch(config: config, title: host)
        } catch {
            model.present(error)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.fullscreen) private var fullscreen = false
    @AppStorage(Prefs.quitAfterLaunch) private var quitAfterLaunch = true
    @AppStorage(Prefs.debugLog) private var debugLog = false
    @State private var resetDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Open viewer in full screen", isOn: $fullscreen)
            Toggle("Quit after the viewer closes when opened from a .vv file", isOn: $quitAfterLaunch)
            Toggle("Verbose viewer logging (for troubleshooting)", isOn: $debugLog)
            HStack {
                Button("Show Viewer Logs") { NSWorkspace.shared.open(ViewerLauncher.shared.logDir) }
                Button(resetDone ? LocalizedStringKey("Certificates Forgotten") : LocalizedStringKey("Forget Trusted Certificates")) {
                    UserDefaults.standard.removeObject(forKey: "trustedCertificates")
                    resetDone = true
                }
                .disabled(resetDone)
            }
            Spacer()
            Text("Release the mouse and keyboard from the VM with Ctrl+Alt. Toggle full screen with Shift+F11 (Proxmox) or the toolbar button.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460, height: 230, alignment: .topLeading)
    }
}
