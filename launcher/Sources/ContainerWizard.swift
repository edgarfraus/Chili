import SwiftUI

/// Everything needed to create an LXC container.
struct ContainerDraft {
    enum IPv4: String, CaseIterable, Identifiable { case dhcp, staticIP; var id: String { rawValue } }
    enum IPv6: String, CaseIterable, Identifiable { case auto, dhcp, none; var id: String { rawValue } }

    var node = ""
    var vmid = 100
    var hostname = ""
    /// A template volid, or "download:<template>" for one from Proxmox' catalogue.
    var template = ""
    var downloadStorage = ""
    var password = ""
    var passwordConfirm = ""
    var sshKey = ""
    var unprivileged = true
    var nesting = true
    var cores = 1
    var memoryMiB = 1024
    var swapMiB = 512
    var rootStorage = ""
    var rootSizeGB = 8
    var bridge = ""
    var vlanTag = 0       // 0 = untagged
    var ipv4 = IPv4.dhcp
    var address = ""      // CIDR, e.g. 192.168.1.50/24
    var gateway = ""
    var ipv6 = IPv6.auto
    var firewall = true
    var startAtBoot = false
    var startAfterCreate = true

    static let downloadPrefix = "download:"
    var wantsDownload: Bool { template.hasPrefix(Self.downloadPrefix) }
    var downloadName: String { String(template.dropFirst(Self.downloadPrefix.count)) }

    func parameters(ostemplate: String) -> [String: String] {
        var p: [String: String] = [
            "vmid": String(vmid),
            "ostemplate": ostemplate,
            "unprivileged": unprivileged ? "1" : "0",
            "cores": String(cores),
            "memory": String(memoryMiB),
            "swap": String(swapMiB),
            "rootfs": "\(rootStorage):\(rootSizeGB)",
        ]
        let name = hostname.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { p["hostname"] = name }
        if !password.isEmpty { p["password"] = password }
        let key = sshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { p["ssh-public-keys"] = key }
        // Nesting keeps systemd-based distributions happy inside unprivileged containers.
        if nesting { p["features"] = "nesting=1" }
        if startAtBoot { p["onboot"] = "1" }

        var net = "name=eth0,bridge=\(bridge)"
        if vlanTag > 0 { net += ",tag=\(vlanTag)" }
        switch ipv4 {
        case .dhcp: net += ",ip=dhcp"
        case .staticIP:
            net += ",ip=\(address.trimmingCharacters(in: .whitespaces))"
            let gw = gateway.trimmingCharacters(in: .whitespaces)
            if !gw.isEmpty { net += ",gw=\(gw)" }
        }
        switch ipv6 {
        case .auto: net += ",ip6=auto"
        case .dhcp: net += ",ip6=dhcp"
        case .none: break
        }
        if firewall { net += ",firewall=1" }
        p["net0"] = net
        return p
    }

    var problems: [String] {
        var list: [String] = []
        if node.isEmpty { list.append(NSLocalizedString("Choose a node.", comment: "")) }
        if template.isEmpty { list.append(NSLocalizedString("Choose a template.", comment: "")) }
        if rootStorage.isEmpty { list.append(NSLocalizedString("Choose a storage for the disk.", comment: "")) }
        if bridge.isEmpty { list.append(NSLocalizedString("Choose a network bridge.", comment: "")) }
        if password.isEmpty && sshKey.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(NSLocalizedString("Set a root password or an SSH key.", comment: ""))
        }
        if !password.isEmpty && password.count < 5 {
            list.append(NSLocalizedString("The password must be at least 5 characters.", comment: ""))
        }
        if password != passwordConfirm { list.append(NSLocalizedString("The passwords don't match.", comment: "")) }
        if ipv4 == .staticIP && !address.contains("/") {
            list.append(NSLocalizedString("Write the IPv4 address with its prefix, e.g. 192.168.1.50/24.", comment: ""))
        }
        let n = hostname.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n.range(of: "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) == nil {
            list.append(NSLocalizedString("The name may only contain letters, digits, dots and dashes.", comment: ""))
        }
        return list
    }
}

@MainActor
final class ContainerWizardModel: ObservableObject {
    let session: ServerSession
    private var api: ProxmoxClient { session.api }

    @Published var draft = ContainerDraft()
    @Published var nodes: [String] = []
    @Published var rootStorages: [ProxmoxClient.Storage] = []
    @Published var templateStorages: [ProxmoxClient.Storage] = []
    @Published var templates: [ProxmoxClient.StorageItem] = []
    @Published var appliances: [ProxmoxClient.Appliance] = []
    @Published var bridges: [ProxmoxClient.NetworkInterface] = []
    @Published var maxCores = 16
    @Published var maxMemoryMiB = 32768
    @Published var loading = true
    @Published var creating = false
    @Published var progress: String?
    @Published var error: String?

    init(session: ServerSession) {
        self.session = session
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            nodes = try await api.nodes()
            if draft.node.isEmpty || !nodes.contains(draft.node) { draft.node = nodes.first ?? "" }
            await loadNode()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNode() async {
        let node = draft.node
        guard !node.isEmpty else { return }
        do {
            async let id = api.nextVMID()
            async let roots = api.storages(node: node, content: "rootdir")
            async let tmplStores = api.storages(node: node, content: "vztmpl")
            async let nets = api.bridges(node: node)
            async let status = api.nodeStatus(node: node)
            draft.vmid = try await id
            rootStorages = try await roots
            templateStorages = try await tmplStores
            bridges = try await nets
            var found: [ProxmoxClient.StorageItem] = []
            for store in templateStorages {
                found += (try? await api.containerTemplates(node: node, storage: store.storage)) ?? []
            }
            templates = found
            appliances = (try? await api.appliances(node: node)) ?? []
            if let st = try? await status {
                maxCores = max(1, st.cpuinfo?.cpus ?? 16)
                maxMemoryMiB = max(512, Int((st.memory?.total ?? 32 << 30) >> 20))
            }
            if !rootStorages.contains(where: { $0.storage == draft.rootStorage }) {
                draft.rootStorage = (rootStorages.first { ["local-lvm", "local-zfs"].contains($0.storage) }
                                     ?? rootStorages.max { ($0.avail ?? 0) < ($1.avail ?? 0) })?.storage ?? ""
            }
            if !templateStorages.contains(where: { $0.storage == draft.downloadStorage }) {
                draft.downloadStorage = (templateStorages.first { $0.storage == "local" } ?? templateStorages.first)?.storage ?? ""
            }
            if !bridges.contains(where: { $0.iface == draft.bridge }) {
                draft.bridge = (bridges.first { $0.iface == "vmbr0" } ?? bridges.first)?.iface ?? ""
            }
            if draft.template.isEmpty {
                // Prefer a template that is already there, else the newest Debian from the catalogue.
                draft.template = templates.last?.volid
                    ?? appliances.last { $0.template.hasPrefix("debian-") }.map { ContainerDraft.downloadPrefix + $0.template }
                    ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Catalogue entries not already downloaded.
    var downloadable: [ProxmoxClient.Appliance] {
        let present = Set(templates.map(\.fileName))
        return appliances.filter { !present.contains($0.template) }
    }

    func create() async -> Bool {
        let d = draft
        creating = true
        error = nil
        defer { creating = false; progress = nil }
        do {
            var ostemplate = d.template
            if d.wantsDownload {
                progress = String(format: NSLocalizedString("Downloading %@…", comment: ""), d.downloadName)
                let upid = try await api.downloadTemplate(node: d.node, storage: d.downloadStorage, template: d.downloadName)
                try await api.waitForTask(node: d.node, upid: upid, timeout: 1800)
                ostemplate = "\(d.downloadStorage):vztmpl/\(d.downloadName)"
            }
            progress = NSLocalizedString("Creating the container…", comment: "")
            let upid = try await api.createContainer(node: d.node, parameters: d.parameters(ostemplate: ostemplate))
            try await api.waitForTask(node: d.node, upid: upid, timeout: 900)
            try await session.reload()
            if d.startAfterCreate, let ct = session.vms.first(where: { $0.vmid == d.vmid }) {
                progress = NSLocalizedString("Starting the container…", comment: "")
                session.connect(ct)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct ContainerWizardView: View {
    @StateObject private var model: ContainerWizardModel
    @Environment(\.presentationMode) private var presentation
    @State private var showAdvanced = false

    init(session: ServerSession) {
        _model = StateObject(wrappedValue: ContainerWizardModel(session: session))
    }

    init(model: ContainerWizardModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Container").font(.title2.bold())
                Text("An LXC container shares the node's Linux kernel: it starts in seconds and uses little memory. Chili creates it unprivileged, with nesting enabled, and opens its console when it's ready.")
                    .font(.callout).foregroundColor(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                Group {
                    if model.loading {
                        ProgressView("Loading the server's storages and networks…").padding(40)
                    } else {
                        form
                    }
                }
                .padding(20)
                .frame(width: 600, alignment: .leading)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 680)
        .task { if model.nodes.isEmpty { await model.load() } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.nodes.count > 1 {
                Row("Node") {
                    Picker("", selection: $model.draft.node) {
                        ForEach(model.nodes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.draft.node) { _ in Task { await model.loadNode() } }
                }
            }
            Row("Hostname") {
                TextField("", text: $model.draft.hostname, prompt: Text(verbatim: "web01"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Row("Template") {
                Picker("", selection: $model.draft.template) {
                    if !model.templates.isEmpty {
                        Section(header: Text("On the server")) {
                            ForEach(model.templates) { Text(verbatim: $0.fileName).tag($0.volid) }
                        }
                    }
                    if !model.downloadable.isEmpty {
                        Section(header: Text("Download from Proxmox")) {
                            ForEach(model.downloadable) { a in
                                Text(verbatim: a.template).tag(ContainerDraft.downloadPrefix + a.template)
                            }
                        }
                    }
                }
                .labelsHidden()
            }
            if model.draft.wantsDownload && model.templateStorages.count > 1 {
                StoragePicker(title: "Save template to", storages: model.templateStorages,
                              selection: $model.draft.downloadStorage)
            }
            Row("Root password") {
                SecureField("", text: $model.draft.password).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Row("Confirm password") {
                SecureField("", text: $model.draft.passwordConfirm).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Row("SSH public key") {
                TextField("", text: $model.draft.sshKey, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
            }
            Divider().padding(.vertical, 4)
            NumberField(title: "CPU cores", value: $model.draft.cores, range: 1...model.maxCores)
            NumberField(title: "Memory", value: $model.draft.memoryMiB, range: 128...model.maxMemoryMiB, step: 256, unit: "MiB")
            NumberField(title: "Disk size", value: $model.draft.rootSizeGB, range: 1...65536, unit: "GB")
            StoragePicker(title: "Disk storage", storages: model.rootStorages, selection: $model.draft.rootStorage)
            BridgePicker(bridges: model.bridges, selection: $model.draft.bridge)
            NumberField(title: "VLAN tag (0 = none)", value: $model.draft.vlanTag, range: 0...4094)
            Row("IPv4") {
                Picker("", selection: $model.draft.ipv4) {
                    Text("DHCP").tag(ContainerDraft.IPv4.dhcp)
                    Text("Static").tag(ContainerDraft.IPv4.staticIP)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if model.draft.ipv4 == .staticIP {
                Row("Address") {
                    TextField("", text: $model.draft.address, prompt: Text(verbatim: "192.168.1.50/24"))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                Row("Gateway") {
                    TextField("", text: $model.draft.gateway, prompt: Text(verbatim: "192.168.1.1"))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
            }
            Divider().padding(.vertical, 4)
            CheckRow(title: "Start the container and open its console", isOn: $model.draft.startAfterCreate)
            Row(nil) {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        NumberField(title: "Container ID", value: $model.draft.vmid, range: 100...999_999_999)
                        NumberField(title: "Swap", value: $model.draft.swapMiB, range: 0...65536, step: 256, unit: "MiB")
                        Row("IPv6") {
                            Picker("", selection: $model.draft.ipv6) {
                                Text("SLAAC").tag(ContainerDraft.IPv6.auto)
                                Text("DHCP").tag(ContainerDraft.IPv6.dhcp)
                                Text("None").tag(ContainerDraft.IPv6.none)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        CheckRow(title: "Unprivileged container", isOn: $model.draft.unprivileged)
                        CheckRow(title: "Nesting (needed by systemd and Docker)", isOn: $model.draft.nesting)
                        CheckRow(title: "Firewall", isOn: $model.draft.firewall)
                        CheckRow(title: "Start at boot", isOn: $model.draft.startAtBoot)
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Text(verbatim: error).foregroundColor(.red).lineLimit(6)
            } else if let first = model.draft.problems.first, !model.loading {
                Text(verbatim: first).foregroundColor(.secondary)
            }
            HStack {
                if let progress = model.progress {
                    ProgressView().controlSize(.small)
                    Text(verbatim: progress).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.creating)
                Button("Create") {
                    Task { if await model.create() { presentation.wrappedValue.dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.creating || !model.draft.problems.isEmpty)
            }
        }
    }
}
