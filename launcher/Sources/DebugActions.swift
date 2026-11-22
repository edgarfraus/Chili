import AppKit
import SwiftUI

/// Development aid, enabled only through CHILI_DEBUG_ACTION (see main.swift).
/// Exercises the VM wizard code against a real server and logs to stderr.
@MainActor
enum DebugActions {
    nonisolated static func log(_ s: String) {
        FileHandle.standardError.write(Data("[debug] \(s)\n".utf8))
    }

    static func inventory(_ session: ServerSession) async {
        let api = session.api
        do {
            let nodes = try await api.nodes()
            log("nodes: \(nodes)")
            for node in nodes {
                log("[\(node)] next id: \(try await api.nextVMID())")
                log("[\(node)] disk storages: \(try await api.storages(node: node, content: "images").map { "\($0.storage) (\($0.type ?? "?"), free \($0.avail ?? 0))" })")
                for s in try await api.storages(node: node, content: "iso") {
                    log("[\(node)] isos on \(s.storage): \(try await api.isoImages(node: node, storage: s.storage).map(\.fileName))")
                }
                log("[\(node)] bridges: \(try await api.bridges(node: node).map(\.iface))")
                let st = try await api.nodeStatus(node: node)
                log("[\(node)] cpus \(st.cpuinfo?.cpus ?? 0), memory \(st.memory?.total ?? 0)")
            }
        } catch {
            log("inventory failed: \(error.localizedDescription)")
        }
    }

    /// Creates a VM with the wizard model, prints the resulting config, optionally deletes it.
    static func createTest(_ session: ServerSession, variant: String, keep: Bool) async {
        let model = VMWizardModel(session: session)
        await model.load()
        var recommended = true
        model.draft.name = "chili-test-\(variant)"
        model.draft.diskSizeGB = 4
        model.draft.startAfterCreate = false
        switch variant {
        case "linux":
            model.draft.os = .linux
            model.draft.iso = model.isos.first { !$0.fileName.localizedCaseInsensitiveContains("virtio") }?.volid
        case "win11":
            model.draft.os = .win11
            model.draft.iso = model.isos.first { $0.fileName.localizedCaseInsensitiveContains("win") && !$0.fileName.localizedCaseInsensitiveContains("virtio") }?.volid
        case "win11-nodrivers":
            model.draft.os = .win11
            model.draft.virtioISO = nil
        case "start":
            model.draft.os = .linux
            model.draft.memoryMiB = 1024
            model.draft.cores = 1
            model.draft.iso = model.isos.first { $0.fileName.localizedCaseInsensitiveContains("alpine") }?.volid
            model.draft.startAfterCreate = true
        case "custom":
            recommended = false
            model.draft.os = .other
            model.draft.machine = .i440fx
            model.draft.bios = .seabios
            model.draft.diskBus = .virtio
            model.draft.netModel = .e1000
            model.draft.vlanTag = 0
            model.draft.display = .std
            model.draft.cores = 1
            model.draft.memoryMiB = 1024
            model.draft.ballooning = false
        default:
            break
        }
        var preview = model.draft
        if recommended { preview.applyChiliPreset() }
        log("creating \(variant) id \(preview.vmid) on \(preview.node): \(preview.parameters.sorted { $0.key < $1.key })")
        let ok = await model.create(recommended: recommended)
        log("create \(variant): \(ok ? "OK" : "FAILED: \(model.error ?? "?")")")
        guard ok, let vm = session.vms.first(where: { $0.vmid == preview.vmid }) else { return }
        await printConfig(session, vm)
        if !keep { await deleteVM(session, vm) }
    }

    static func printConfig(_ session: ServerSession, _ vm: ProxmoxVM) async {
        if let config = try? await session.api.vmConfig(vm) {
            log("config \(vm.vmid): \(config.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))")
        }
    }

    static func deleteVM(_ session: ServerSession, _ vm: ProxmoxVM) async {
        // Check the name in the VM's own config: the cluster list can lag behind.
        let config = try? await session.api.vmConfig(vm)
        let name = config?["name"] ?? config?["hostname"] ?? vm.displayName   // containers use "hostname"
        guard name.hasPrefix("chili-test-") else { return log("refusing to delete \(vm.vmid) (\(name))") }
        do {
            if let current = session.vms.first(where: { $0.id == vm.id }), current.isRunning {
                let stop = try await session.api.power(vm, .stop)
                try await session.api.waitForTask(node: vm.node, upid: stop, timeout: 120)
            }
            let upid = try await session.api.delete(vm)
            try await session.api.waitForTask(node: vm.node, upid: upid)
            try await session.reload()
            log("deleted \(vm.vmid)")
        } catch {
            log("delete failed: \(error.localizedDescription)")
        }
    }

    /// Creates chili-test-ct with the container wizard (downloading Alpine if no
    /// template is present), starts it into its console, then checks the logs APIs.
    static func containerTest(_ session: ServerSession) async {
        let model = ContainerWizardModel(session: session)
        await model.load()
        log("ct templates on server: \(model.templates.map(\.fileName)); rootdir storages: \(model.rootStorages.map(\.storage)); vztmpl storages: \(model.templateStorages.map(\.storage)); catalogue: \(model.appliances.count)")
        if let alpine = model.templates.first(where: { $0.fileName.hasPrefix("alpine") }) {
            model.draft.template = alpine.volid
        } else if let alpine = model.appliances.last(where: { $0.template.hasPrefix("alpine") }) {
            model.draft.template = ContainerDraft.downloadPrefix + alpine.template
        }
        model.draft.hostname = "chili-test-ct"
        model.draft.password = UUID().uuidString
        model.draft.passwordConfirm = model.draft.password
        model.draft.memoryMiB = 256
        model.draft.rootSizeGB = 2
        model.draft.startAfterCreate = true
        log("ct params: \(model.draft.parameters(ostemplate: model.draft.template).filter { $0.key != "password" }.sorted { $0.key < $1.key })")
        log("ct problems: \(model.draft.problems)")
        let ok = await model.create()
        log("ct create: \(ok ? "OK" : "FAILED: \(model.error ?? "?")")")
        guard ok, let ct = session.vms.first(where: { $0.vmid == model.draft.vmid }) else { return }
        await printConfig(session, ct)
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        if let tasks = try? await session.api.tasks(for: ct) {
            log("ct tasks: \(tasks.map { "\($0.type)=\($0.status ?? "running")" })")
            if let first = tasks.first, let lines = try? await session.api.taskLog(node: ct.node, upid: first.upid) {
                log("ct last task log: \(lines.suffix(3))")
            }
        }
        if let sys = try? await session.api.syslog(node: ct.node, lines: 50) {
            log("syslog lines: \(sys.count), last: \(sys.last ?? "-")")
        }
    }

    /// Deletes every leftover chili-test-* VM.
    static func cleanup(_ session: ServerSession) async {
        try? await session.reload()
        for vm in session.vms {
            await deleteVM(session, vm)   // only deletes chili-test-* (checked against the config)
        }
    }

    /// Shows the wizard with made-up inventory (no login, no Keychain) to check its layout.
    static func previewWizard(app: AppModel, recommended: Bool, os: VMDraft.OS) -> NSWindow {
        let profile = ServerProfile(name: "Preview", host: "preview.invalid")
        let model = VMWizardModel(session: ServerSession(profile: profile, app: app))
        model.nodes = ["pve1"]
        model.diskStorages = [
            .init(storage: "local-lvm", type: "lvmthin", content: "images", avail: 151_636_672_512, total: nil, active: 1),
            .init(storage: "nas-iso", type: "nfs", content: "images,iso", avail: 288_513_327_104, total: nil, active: 1),
        ]
        model.isos = [.init(volid: "nas-iso:iso/Win11_24H2_English_x64.iso", size: nil),
                      .init(volid: "nas-iso:iso/virtio-win-0.1.266.iso", size: nil),
                      .init(volid: "nas-iso:iso/alpine-standard-3.22.0-x86_64.iso", size: nil)]
        model.bridges = [.init(iface: "vmbr0", type: "bridge", active: 1, comments: nil)]
        model.maxCores = 12
        model.maxMemoryMiB = 15_770
        model.draft.node = "pve1"
        model.draft.vmid = 106
        model.draft.os = os
        model.draft.diskStorage = "local-lvm"
        model.draft.efiStorage = "local-lvm"
        model.draft.bridge = "vmbr0"
        model.draft.virtioISO = "nas-iso:iso/virtio-win-0.1.266.iso"
        model.loading = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VMWizardView(model: model, recommended: recommended))
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func previewWindow<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func previewSession(app: AppModel) -> ServerSession {
        ServerSession(profile: ServerProfile(name: "Preview", host: "preview.invalid"), app: app)
    }

    static func previewContainerWizard(app: AppModel) -> NSWindow {
        let model = ContainerWizardModel(session: previewSession(app: app))
        model.nodes = ["pve1"]
        model.rootStorages = [.init(storage: "local-lvm", type: "lvmthin", content: "rootdir,images", avail: 151_636_672_512, total: nil, active: 1)]
        model.templateStorages = [.init(storage: "local", type: "dir", content: "vztmpl,iso", avail: 50_000_000_000, total: nil, active: 1)]
        model.templates = [.init(volid: "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst", size: nil)]
        model.appliances = [.init(template: "alpine-3.22-default_20250617_amd64.tar.xz", headline: nil, os: "alpine", section: "system", version: nil),
                            .init(template: "ubuntu-24.04-standard_24.04-2_amd64.tar.zst", headline: nil, os: "ubuntu", section: "system", version: nil)]
        model.bridges = [.init(iface: "vmbr0", type: "bridge", active: 1, comments: nil)]
        model.maxCores = 12
        model.draft.node = "pve1"
        model.draft.vmid = 106
        model.draft.rootStorage = "local-lvm"
        model.draft.downloadStorage = "local"
        model.draft.bridge = "vmbr0"
        model.draft.template = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
        model.draft.ipv4 = .staticIP
        model.draft.vlanTag = 20
        model.loading = false
        return previewWindow(ContainerWizardView(model: model), size: NSSize(width: 640, height: 680))
    }

    static func previewLogs(app: AppModel) -> NSWindow {
        let now = Int(Date().timeIntervalSince1970)
        func t(_ type: String, _ ago: Int, _ dur: Int?, _ status: String?) -> ProxmoxClient.TaskEntry {
            .init(upid: "UPID:pve1:\(type):\(ago)", type: type, status: status, starttime: now - ago,
                  endtime: dur.map { now - ago + $0 }, user: "root@pam", node: "pve1")
        }
        let tasks = [t("vncproxy", 30, nil, nil), t("qmstart", 120, 3, "OK"), t("qmstart", 400, 2, "start failed: QEMU exited with code 1"),
                     t("vzdump", 86_400, 412, "OK"), t("qmshutdown", 90_000, 14, "OK"), t("qmcreate", 200_000, 5, "OK")]
        let log = ["kvm: warning: host doesn't support requested feature: CPUID[eax=01h].ECX.aes [bit 25]",
                   "kvm: Host doesn't support requested features", "TASK ERROR: start failed: QEMU exited with code 1"]
        let vm = ProxmoxVM(vmid: 100, name: "win11-desktop", node: "pve1", status: "running", type: "qemu", template: nil, maxmem: nil,
                           maxcpu: nil, uptime: nil, cpu: nil, mem: nil, maxdisk: nil, netin: nil, netout: nil, diskread: nil, diskwrite: nil)
        return previewWindow(VMLogsView(session: previewSession(app: app), vm: vm, preview: (tasks, log)),
                             size: NSSize(width: 980, height: 620))
    }

    static func previewSyslog(app: AppModel) -> NSWindow {
        let lines = (0..<40).map { i in "Nov 22 01:\(String(format: "%02d", i)):12 pve1 pvedaemon[1234]: <root@pam> successful auth for user 'root@pam'" }
            + ["Nov 22 01:41:00 pve1 kernel: warning: something odd", "Nov 22 01:41:02 pve1 pveproxy[999]: error: connection refused"]
        return previewWindow(NodeLogView(session: previewSession(app: app), node: "pve1", preview: lines),
                             size: NSSize(width: 980, height: 640))
    }
}
