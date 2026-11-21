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
                .id(model.selection)   // rebuild the pane on every selection change
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
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
            if !model.consoles.isEmpty {
                Section(header: Text("Consoles")) {
                    ForEach(model.consoles) { console in
                        ConsoleRow(session: console)
                            .tag(SidebarItem.console(console.id))
                            .contextMenu {
                                Button("Open in Window") { model.detach(console) }
                                Button("Disconnect") { model.close(console) }
                            }
                    }
                }
            }

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

private struct ConsoleRow: View {
    @ObservedObject var session: ConsoleSession

    var body: some View {
        Label {
            Text(verbatim: session.title)
        } icon: {
            Image(systemName: session.window == nil ? "display" : "macwindow")
                .foregroundColor(color)
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting: return .orange
        default: return .secondary
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
        case .console(let id):
            if let session = model.consoles.first(where: { $0.id == id }) {
                ConsoleView(session: session, inMainWindow: true)
                    .id(session.id)
            } else {
                Placeholder()
            }
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
    @State private var showWizard = false

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
                    Button { showWizard = true } label: { Label("New VM", systemImage: "plus.rectangle.on.rectangle") }
                        .help("Create a new virtual machine")
                    NodeShellMenu(session: session)
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
        .sheet(isPresented: $showWizard) { VMWizardView(session: session) }
        .alert(item: Binding(get: { session.pendingCertificate.map { CertPrompt(fingerprint: $0) } },
                             set: { if $0 == nil { session.pendingCertificate = nil } })) { prompt in
            Alert(title: Text("Untrusted certificate"),
                  message: Text("\(session.profile.host) uses a certificate that macOS doesn't trust. This is normal for Proxmox, which generates a self-signed certificate on install.\n\nCompare this SHA-256 fingerprint with the one shown in Proxmox under Node → System → Certificates:\n\n\(prompt.fingerprint)"),
                  primaryButton: .default(Text("Trust and Continue")) { session.trustPendingCertificate() },
                  secondaryButton: .cancel())
        }
    }
}

/// Toolbar menu: open a root shell on one of the cluster's nodes (xterm.js).
private struct NodeShellMenu: View {
    @ObservedObject var session: ServerSession
    @State private var nodes: [String] = []

    var body: some View {
        Menu {
            ForEach(nodes, id: \.self) { node in
                Button(node) { session.openWebConsole(.nodeShell(node)) }
            }
        } label: {
            Label("Shell", systemImage: "terminal")
        }
        .help("Open a shell on a node")
        .task { nodes = await session.loadNodes() }
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
                          session: session)
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
    let session: ServerSession

    private enum Confirm: Identifiable { case stop, delete; var id: Int { self == .stop ? 0 : 1 } }
    @State private var confirm: Confirm?

    private func connect() { session.connect(vm) }
    private func start() { session.start(vm) }

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
                Menu {
                    Button("Open in Separate Window") { session.connect(vm, placement: .window) }
                    if !vm.isContainer {
                        Button("noVNC Console") { session.openWebConsole(.vm(vm), placement: .mainWindow) }
                        Button("noVNC Console in Separate Window") { session.openWebConsole(.vm(vm), placement: .window) }
                    }
                    Divider()
                    if vm.isRunning {
                        Button("Shut Down") { session.power(vm, .shutdown) }
                        Button("Reboot") { session.power(vm, .reboot) }
                        Button("Stop (power off)") { confirm = .stop }
                    } else {
                        Button("Start") { start() }
                    }
                    Divider()
                    Button("Delete…") { confirm = .delete }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More ways to open the console")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !busy { connect() } }
        .alert(item: $confirm) { which in
            switch which {
            case .stop:
                return Alert(title: Text("Stop \(vm.displayName)?"),
                             message: Text("This powers the VM off immediately, like pulling the plug. Unsaved data in the VM is lost."),
                             primaryButton: .destructive(Text("Stop")) { session.power(vm, .stop) },
                             secondaryButton: .cancel())
            case .delete:
                return Alert(title: Text("Delete \(vm.displayName) (\(String(vm.vmid)))?"),
                             message: Text("The VM and all its disks are permanently deleted from Proxmox. This can't be undone."),
                             primaryButton: .destructive(Text("Delete")) { session.delete(vm) },
                             secondaryButton: .cancel())
            }
        }
    }

    private var details: String {
        var parts = [vm.isContainer ? NSLocalizedString("Container", comment: "") + " · " + vm.node : vm.node]
        if let cpu = vm.maxcpu { parts.append(String(format: NSLocalizedString("%d vCPU", comment: ""), Int(cpu))) }
        if let mem = vm.maxmem { parts.append(ByteCountFormatter.string(fromByteCount: mem, countStyle: .memory)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Resource monitor

/// CPU and memory dials plus network rate for one running VM.
private struct UsageView: View {
    let vm: ProxmoxVM
    let samples: [UsageSample]

    private var cpu: Double { samples.last?.cpu ?? vm.cpu ?? 0 }
    private var memory: Double {
        samples.last?.memory ?? ((vm.maxmem ?? 0) > 0 ? Double(vm.mem ?? 0) / Double(vm.maxmem!) : 0)
    }

    var body: some View {
        HStack(spacing: 12) {
            Dial(value: cpu, label: "CPU", color: Self.color(for: cpu))
                .help(Text(verbatim: "CPU \(Int((cpu * 100).rounded()))% · \(Int(vm.maxcpu ?? 0)) vCPU"))
            Dial(value: memory, label: "RAM", color: Self.color(for: memory))
                .help(Text(verbatim: "RAM \(Self.bytes(vm.mem)) / \(Self.bytes(vm.maxmem))"))
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

/// A small tachometer: 240° scale, coloured arc up to the value and a needle.
private struct Dial: View {
    let value: Double          // 0…1
    let label: String
    let color: Color

    private static let sweep = 240.0
    private static let start = 150.0   // degrees, 0 = 3 o'clock, clockwise

    var body: some View {
        let v = min(max(value, 0), 1)
        ZStack {
            Arc(from: 0, to: 1).stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Arc(from: 0, to: v).stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ForEach(0..<5) { i in
                Tick(fraction: Double(i) / 4).stroke(Color.secondary.opacity(0.5), lineWidth: 1)
            }
            Needle(fraction: v).stroke(Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Circle().fill(Color.primary.opacity(0.8)).frame(width: 4, height: 4)
            Text(verbatim: "\(Int((v * 100).rounded()))%")
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .offset(y: 15)
        }
        .frame(width: 42, height: 42)
        .overlay(Text(verbatim: label).font(.system(size: 8)).foregroundColor(.secondary).offset(y: 27))
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.6), value: v)
    }

    static func angle(_ fraction: Double) -> Angle { .degrees(start + sweep * fraction) }

    struct Arc: Shape {
        var from: Double, to: Double
        var animatableData: AnimatablePair<Double, Double> {
            get { AnimatablePair(from, to) }
            set { from = newValue.first; to = newValue.second }
        }
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 3,
                     startAngle: Dial.angle(from), endAngle: Dial.angle(to), clockwise: false)
            return p
        }
    }

    struct Needle: Shape {
        var fraction: Double
        var animatableData: Double { get { fraction } set { fraction = newValue } }
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let a = Dial.angle(fraction).radians, r = rect.width / 2 - 9
            var p = Path()
            p.move(to: c)
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
            return p
        }
    }

    struct Tick: Shape {
        let fraction: Double
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let a = Dial.angle(fraction).radians, r1 = rect.width / 2 - 7, r2 = rect.width / 2 - 9.5
            var p = Path()
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r2, y: c.y + CGFloat(sin(a)) * r2))
            return p
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
                    .lineLimit(3)
            }
            // Explicit rows: a SwiftUI Form here inflated the whole window's content.
            VStack(alignment: .leading, spacing: 10) {
                field("Host") {
                    TextField("", text: $host, prompt: Text(verbatim: "192.168.1.10"))
                        .textFieldStyle(.roundedBorder)
                }
                field("Port") {
                    TextField("", value: $port, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                field(nil) { Toggle("Use TLS (port is the TLS port)", isOn: $tls) }
                field("Password") {
                    SecureField("", text: $password, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
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
                    .lineLimit(4)
                Button("Add Proxmox Server…") { model.editingProfile = ServerProfile() }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Quick Connect")
    }

    private func field<Content: View>(_ label: LocalizedStringKey?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group { if let label { Text(label) } else { Text(verbatim: "") } }
                .frame(width: 80, alignment: .trailing)
            content()
        }
    }

    private func connect() {
        var config = ViewerConfig()
        config["host"] = host.trimmingCharacters(in: .whitespaces)
        config[tls ? "tls-port" : "port"] = String(port)
        if !password.isEmpty { config["password"] = password }
        model.openConsole(config: config, title: "\(config["host"] ?? host):\(port)")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.consolePlacement) private var placement = "main"
    @AppStorage(Prefs.fullscreen) private var fullscreen = false
    @AppStorage(Prefs.resizeGuest) private var resizeGuest = true
    @AppStorage(Prefs.retinaResolution) private var retina = false
    @AppStorage(Prefs.shareClipboard) private var shareClipboard = true
    @AppStorage(Prefs.useClassicViewer) private var classicViewer = false
    @AppStorage(Prefs.quitAfterLaunch) private var quitAfterLaunch = true
    @AppStorage(Prefs.debugLog) private var debugLog = false
    @State private var resetDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Open consoles", selection: $placement) {
                Text("In the main window").tag("main")
                Text("In separate windows").tag("window")
            }
            .pickerStyle(.radioGroup)
            Toggle("Open consoles in full screen", isOn: $fullscreen)
            Toggle("Resize the VM display to the window (needs the SPICE agent)", isOn: $resizeGuest)
            Toggle("Use Retina resolution (sharper, smaller text in the VM)", isOn: $retina)
                .disabled(!resizeGuest)
            Toggle("Share the clipboard with the VM", isOn: $shareClipboard)
            Divider()
            Toggle("Quit after the console closes when opened from a .vv file", isOn: $quitAfterLaunch)
            Toggle("Use the classic viewer (remote-viewer) instead of the built-in console", isOn: $classicViewer)
            Toggle("Verbose classic viewer logging (for troubleshooting)", isOn: $debugLog)
                .disabled(!classicViewer)
            HStack {
                Button("Show Viewer Logs") { NSWorkspace.shared.open(ViewerLauncher.shared.logDir) }
                Button(resetDone ? LocalizedStringKey("Certificates Forgotten") : LocalizedStringKey("Forget Trusted Certificates")) {
                    UserDefaults.standard.removeObject(forKey: "trustedCertificates")
                    resetDone = true
                }
                .disabled(resetDone)
            }
            Spacer()
            Text("Click inside a console to control the VM. If the mouse gets captured, press Ctrl+Alt to release it. Settings apply to consoles opened afterwards.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 500, height: 400, alignment: .topLeading)
    }
}
