import SwiftUI

/// Loads what the wizard can choose from and runs the creation.
@MainActor
final class VMWizardModel: ObservableObject {
    let session: ServerSession
    private var api: ProxmoxClient { session.api }

    @Published var draft = VMDraft()
    @Published var nodes: [String] = []
    @Published var diskStorages: [ProxmoxClient.Storage] = []
    @Published var isos: [ProxmoxClient.StorageItem] = []
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

    var virtioISOs: [ProxmoxClient.StorageItem] {
        isos.filter { $0.fileName.localizedCaseInsensitiveContains("virtio") }
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
            async let disks = api.storages(node: node, content: "images")
            async let isoStores = api.storages(node: node, content: "iso")
            async let nets = api.bridges(node: node)
            async let status = api.nodeStatus(node: node)

            draft.vmid = try await id
            diskStorages = try await disks
            bridges = try await nets
            var found: [ProxmoxClient.StorageItem] = []
            for store in try await isoStores {
                found += (try? await api.isoImages(node: node, storage: store.storage)) ?? []
            }
            isos = found
            if let st = try? await status {
                let recommended = VMDraft.cpuType(forHostFlags: st.cpuinfo?.flags)
                if draft.cpuType == draft.recommendedCPUType { draft.cpuType = recommended }
                draft.recommendedCPUType = recommended
                maxCores = max(1, st.cpuinfo?.cpus ?? 16)
                maxMemoryMiB = max(1024, Int((st.memory?.total ?? 32 << 30) >> 20))
            }
            if !diskStorages.contains(where: { $0.storage == draft.diskStorage }) {
                // Prefer the usual VM storages, then the one with most free space.
                draft.diskStorage = (diskStorages.first { ["local-lvm", "local-zfs"].contains($0.storage) }
                                     ?? diskStorages.max { ($0.avail ?? 0) < ($1.avail ?? 0) })?.storage ?? ""
            }
            if !diskStorages.contains(where: { $0.storage == draft.efiStorage }) { draft.efiStorage = draft.diskStorage }
            if !bridges.contains(where: { $0.iface == draft.bridge }) {
                draft.bridge = (bridges.first { $0.iface == "vmbr0" } ?? bridges.first)?.iface ?? ""
            }
            if draft.virtioISO == nil { draft.virtioISO = virtioISOs.last?.volid }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sensible sizes when the OS changes (only if the user didn't pick their own).
    func osChanged(from old: VMDraft.OS) {
        let defaults: (cores: Int, mem: Int, disk: Int) = draft.os.isWindows ? (4, 8192, 64) : (2, 4096, 32)
        let previous: (cores: Int, mem: Int, disk: Int) = old.isWindows ? (4, 8192, 64) : (2, 4096, 32)
        if draft.cores == previous.cores { draft.cores = min(defaults.cores, maxCores) }
        if draft.memoryMiB == previous.mem { draft.memoryMiB = min(defaults.mem, maxMemoryMiB) }
        if draft.diskSizeGB == previous.disk { draft.diskSizeGB = defaults.disk }
    }

    func create(recommended: Bool) async -> Bool {
        var d = draft
        if recommended { d.applyChiliPreset() }
        creating = true
        error = nil
        defer { creating = false; progress = nil }
        do {
            progress = NSLocalizedString("Creating the VM…", comment: "")
            let upid = try await api.createVM(node: d.node, parameters: d.parameters)
            try await api.waitForTask(node: d.node, upid: upid)
            try await session.reload()
            if d.startAfterCreate, let vm = session.vms.first(where: { $0.vmid == d.vmid }) {
                progress = NSLocalizedString("Starting the VM…", comment: "")
                session.connect(vm)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct VMWizardView: View {
    @StateObject private var model: VMWizardModel
    @Environment(\.presentationMode) private var presentation
    @State private var recommended = true
    @State private var previousOS = VMDraft.OS.linux

    init(session: ServerSession) {
        _model = StateObject(wrappedValue: VMWizardModel(session: session))
    }

    /// For previews: a model that is already filled in.
    init(model: VMWizardModel, recommended: Bool = true) {
        _model = StateObject(wrappedValue: model)
        _recommended = State(initialValue: recommended)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New Virtual Machine").font(.title2.bold())
                Picker("", selection: $recommended) {
                    Text("Recommended for Chili").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(recommended
                     ? "Pick the essentials; Chili sets up SPICE display and audio, the guest agent, VirtIO devices and, for Windows 11, UEFI with TPM 2.0."
                     : "Every option, as in the Proxmox wizard.")
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            ScrollView {
                Group {
                    if model.loading {
                        ProgressView("Loading the server's storages and networks…").padding(40)
                    } else if recommended {
                        RecommendedForm(model: model)
                    } else {
                        CustomForm(model: model)
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
        .onChange(of: model.draft.os) { os in
            model.osChanged(from: previousOS)
            previousOS = os
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                Text(verbatim: error).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
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
                    Task {
                        if await model.create(recommended: recommended) { presentation.wrappedValue.dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.creating || !model.draft.problems.isEmpty)
            }
        }
    }
}

// MARK: - Layout

/// One form row: right-aligned label column, control on the right. (SwiftUI's
/// Form inside a ScrollView has no width on macOS and lays out off-screen.)
private struct Row<Content: View>: View {
    let label: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ label: LocalizedStringKey?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let label { Text(label) } else { Text(verbatim: "") }
            }
            .frame(width: 160, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: - Shared pieces

private struct NodePicker: View {
    @ObservedObject var model: VMWizardModel

    var body: some View {
        if model.nodes.count > 1 {
            Row("Node") {
                Picker("", selection: $model.draft.node) {
                    ForEach(model.nodes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
                .onChange(of: model.draft.node) { _ in Task { await model.loadNode() } }
            }
        }
    }
}

private struct ISOPicker: View {
    let title: LocalizedStringKey
    let isos: [ProxmoxClient.StorageItem]
    @Binding var selection: String?

    var body: some View {
        Row(title) {
            Picker("", selection: $selection) {
                Text("None").tag(String?.none)
                ForEach(isos) { iso in
                    Text(verbatim: iso.fileName).tag(Optional(iso.volid))
                }
            }
            .labelsHidden()
        }
    }
}

private struct StoragePicker: View {
    let title: LocalizedStringKey
    let storages: [ProxmoxClient.Storage]
    @Binding var selection: String

    var body: some View {
        Row(title) {
            Picker("", selection: $selection) {
                ForEach(storages) { s in
                    Text(verbatim: label(s)).tag(s.storage)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func label(_ s: ProxmoxClient.Storage) -> String {
        guard let free = s.avail else { return s.storage }
        let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        return "\(s.storage) — " + String(format: NSLocalizedString("%@ free", comment: ""), f)
    }
}

private struct BridgePicker: View {
    let bridges: [ProxmoxClient.NetworkInterface]
    @Binding var selection: String

    var body: some View {
        Row("Network") {
            Picker("", selection: $selection) {
                ForEach(bridges) { b in
                    Text(verbatim: b.comments.map { "\(b.iface) — \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? b.iface)
                        .tag(b.iface)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

private struct ChoiceRow<T: Hashable, Item: Identifiable>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @Binding var selection: T
    let tag: (Item) -> T
    let text: (Item) -> String
    var width: CGFloat = 260

    var body: some View {
        Row(title) {
            Picker("", selection: $selection) {
                ForEach(items) { Text(verbatim: text($0)).tag(tag($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: width, alignment: .leading)
        }
    }
}

private struct StringChoice: Identifiable { let value: String; var id: String { value } }

private struct NumberField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: String = ""

    var body: some View {
        Row(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper("", value: $value, in: range, step: step).labelsHidden()
                if !unit.isEmpty { Text(verbatim: unit).foregroundColor(.secondary) }
            }
        }
    }
}

private struct CheckRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Row(nil) { Toggle(title, isOn: $isOn) }
    }
}

// MARK: - Recommended

private struct RecommendedForm: View {
    @ObservedObject var model: VMWizardModel

    private var memoryGB: Binding<Int> {
        Binding(get: { max(1, model.draft.memoryMiB / 1024) }, set: { model.draft.memoryMiB = $0 * 1024 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NodePicker(model: model)
            Row("Name") {
                TextField("", text: $model.draft.name, prompt: Text(verbatim: "win11-office"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            ChoiceRow(title: "Operating system", items: VMDraft.OS.allCases, selection: $model.draft.os,
                      tag: { $0 }, text: { $0.label }, width: 320)
            ISOPicker(title: "Installation ISO", isos: model.isos, selection: $model.draft.iso)
            if model.draft.os.isWindows {
                ISOPicker(title: "VirtIO drivers ISO", isos: model.isos, selection: $model.draft.virtioISO)
                Row(nil) {
                    Text(model.draft.virtioISO == nil
                         ? "Without the drivers ISO, Chili uses SATA and Intel network devices that Windows recognises by itself."
                         : "During setup, load the disk driver from the VirtIO CD (vioscsi\\w11\\amd64), then install virtio-win-guest-tools for networking, clipboard and resizing.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().padding(.vertical, 4)
            NumberField(title: "CPU cores", value: $model.draft.cores, range: 1...model.maxCores)
            NumberField(title: "Memory", value: memoryGB, range: 1...max(1, model.maxMemoryMiB / 1024), unit: "GB")
            NumberField(title: "Disk size", value: $model.draft.diskSizeGB, range: 1...65536, unit: "GB")
            StoragePicker(title: "Disk storage", storages: model.diskStorages, selection: $model.draft.diskStorage)
            BridgePicker(bridges: model.bridges, selection: $model.draft.bridge)
            Divider().padding(.vertical, 4)
            CheckRow(title: "Start the VM and open its console", isOn: $model.draft.startAfterCreate)
            Row(nil) {
                Text(verbatim: "ID \(model.draft.vmid) · CPU \(model.draft.recommendedCPUType)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Custom

private struct CustomForm: View {
    @ObservedObject var model: VMWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionBox("General") {
                NodePicker(model: model)
                NumberField(title: "VM ID", value: $model.draft.vmid, range: 100...999_999_999)
                Row("Name") {
                    TextField("", text: $model.draft.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
                CheckRow(title: "Start at boot", isOn: $model.draft.startAtBoot)
            }
            SectionBox("OS") {
                ISOPicker(title: "Installation ISO", isos: model.isos, selection: $model.draft.iso)
                ChoiceRow(title: "Guest OS type", items: VMDraft.OS.allCases, selection: $model.draft.os,
                          tag: { $0 }, text: { $0.label }, width: 320)
                if model.draft.os.isWindows {
                    ISOPicker(title: "VirtIO drivers ISO", isos: model.isos, selection: $model.draft.virtioISO)
                }
            }
            SectionBox("System") {
                ChoiceRow(title: "Machine", items: VMDraft.Machine.allCases, selection: $model.draft.machine,
                          tag: { $0 }, text: { $0.rawValue }, width: 160)
                ChoiceRow(title: "BIOS", items: VMDraft.BIOS.allCases, selection: $model.draft.bios,
                          tag: { $0 }, text: { $0.label }, width: 200)
                if model.draft.bios == .ovmf || model.draft.addTPM {
                    StoragePicker(title: "EFI/TPM storage", storages: model.diskStorages, selection: $model.draft.efiStorage)
                }
                CheckRow(title: "Add TPM 2.0", isOn: $model.draft.addTPM)
                ChoiceRow(title: "SCSI controller", items: VMDraft.scsiControllers.map(StringChoice.init),
                          selection: $model.draft.scsiController, tag: { $0.value }, text: { $0.value }, width: 220)
                CheckRow(title: "QEMU guest agent", isOn: $model.draft.guestAgent)
            }
            SectionBox("Disk") {
                ChoiceRow(title: "Bus", items: VMDraft.Bus.allCases, selection: $model.draft.diskBus,
                          tag: { $0 }, text: { $0.label }, width: 200)
                StoragePicker(title: "Storage", storages: model.diskStorages, selection: $model.draft.diskStorage)
                NumberField(title: "Size", value: $model.draft.diskSizeGB, range: 1...65536, unit: "GB")
                ChoiceRow(title: "Cache", items: VMDraft.cacheModes.map(StringChoice.init), selection: $model.draft.diskCache,
                          tag: { $0.value },
                          text: { $0.value.isEmpty ? NSLocalizedString("Default (no cache)", comment: "") : $0.value },
                          width: 220)
                CheckRow(title: "Discard", isOn: $model.draft.discard)
                CheckRow(title: "IO thread", isOn: $model.draft.ioThread)
                CheckRow(title: "SSD emulation", isOn: $model.draft.ssdEmulation)
            }
            SectionBox("CPU") {
                NumberField(title: "Sockets", value: $model.draft.sockets, range: 1...4)
                NumberField(title: "Cores", value: $model.draft.cores, range: 1...model.maxCores)
                ChoiceRow(title: "Type", items: VMDraft.cpuTypes.map(StringChoice.init), selection: $model.draft.cpuType,
                          tag: { $0.value }, text: { $0.value }, width: 220)
            }
            SectionBox("Memory") {
                NumberField(title: "Memory", value: $model.draft.memoryMiB, range: 256...model.maxMemoryMiB, step: 512, unit: "MiB")
                CheckRow(title: "Ballooning device", isOn: $model.draft.ballooning)
                if model.draft.ballooning {
                    NumberField(title: "Minimum memory", value: $model.draft.minMemoryMiB, range: 0...model.draft.memoryMiB,
                                step: 512, unit: "MiB")
                }
            }
            SectionBox("Network") {
                BridgePicker(bridges: model.bridges, selection: $model.draft.bridge)
                ChoiceRow(title: "Model", items: VMDraft.NetModel.allCases, selection: $model.draft.netModel,
                          tag: { $0 }, text: { $0.label }, width: 260)
                NumberField(title: "VLAN tag (0 = none)", value: $model.draft.vlanTag, range: 0...4094)
                CheckRow(title: "Firewall", isOn: $model.draft.firewall)
            }
            SectionBox("Display & audio") {
                ChoiceRow(title: "Display", items: VMDraft.Display.allCases, selection: $model.draft.display,
                          tag: { $0 }, text: { $0.label }, width: 260)
                if model.draft.display == .spice {
                    NumberField(title: "Monitors", value: $model.draft.monitors, range: 1...4)
                    CheckRow(title: "SPICE audio", isOn: $model.draft.audio)
                }
            }
            SectionBox("After creation") {
                CheckRow(title: "Start the VM and open its console", isOn: $model.draft.startAfterCreate)
            }
        }
    }
}
