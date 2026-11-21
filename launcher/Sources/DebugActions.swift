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
        let name = (try? await session.api.vmConfig(vm))?["name"] ?? vm.displayName
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

    /// Deletes every leftover chili-test-* VM.
    static func cleanup(_ session: ServerSession) async {
        try? await session.reload()
        for vm in session.vms where vm.vmid != 100 && vm.vmid != 101 {
            await deleteVM(session, vm)   // only deletes chili-test-* (checked against the config)
        }
    }

    /// Shows the wizard with made-up inventory (no login, no Keychain) to check its layout.
    static func previewWizard(app: AppModel, recommended: Bool, os: VMDraft.OS) -> NSWindow {
        let profile = ServerProfile(name: "Preview", host: "preview.invalid")
        let model = VMWizardModel(session: ServerSession(profile: profile, app: app))
        model.nodes = ["pve01"]
        model.diskStorages = [
            .init(storage: "local-lvm", type: "lvmthin", content: "images", avail: 151_636_672_512, total: nil, active: 1),
            .init(storage: "Data-SSD", type: "nfs", content: "images,iso", avail: 288_513_327_104, total: nil, active: 1),
        ]
        model.isos = [.init(volid: "Data-SSD:iso/Windows-11-30072025.iso", size: nil),
                      .init(volid: "Data-SSD:iso/virtio-win.iso", size: nil),
                      .init(volid: "Data-SSD:iso/alpine-standard-3.22.0-x86_64.iso", size: nil)]
        model.bridges = [.init(iface: "vmbr0", type: "bridge", active: 1, comments: nil)]
        model.maxCores = 12
        model.maxMemoryMiB = 15_770
        model.draft.node = "pve01"
        model.draft.vmid = 106
        model.draft.os = os
        model.draft.diskStorage = "local-lvm"
        model.draft.efiStorage = "local-lvm"
        model.draft.bridge = "vmbr0"
        model.draft.virtioISO = "Data-SSD:iso/virtio-win.iso"
        model.loading = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VMWizardView(model: model, recommended: recommended))
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
