import Foundation

/// Everything needed to create a QEMU VM, turned into Proxmox API parameters by
/// `parameters`. The quick wizard fills it with `applyChiliPreset()`; the
/// custom wizard exposes every field.
struct VMDraft {
    enum OS: String, CaseIterable, Identifiable {
        case win11, win10, linux, other
        var id: String { rawValue }
        var ostype: String {
            switch self {
            case .win11: return "win11"
            case .win10: return "win10"
            case .linux: return "l26"
            case .other: return "other"
            }
        }
        var isWindows: Bool { self == .win11 || self == .win10 }
        var label: String {
            switch self {
            case .win11: return "Windows 11 / Server 2022+"
            case .win10: return "Windows 10 / Server 2016–2019"
            case .linux: return "Linux"
            case .other: return NSLocalizedString("Other", comment: "")
            }
        }
    }

    enum Machine: String, CaseIterable, Identifiable { case i440fx, q35; var id: String { rawValue } }
    enum BIOS: String, CaseIterable, Identifiable {
        case seabios, ovmf
        var id: String { rawValue }
        var label: String { self == .ovmf ? "OVMF (UEFI)" : "SeaBIOS" }
    }
    enum Bus: String, CaseIterable, Identifiable {
        case scsi, sata, virtio, ide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .scsi: return "SCSI"
            case .sata: return "SATA"
            case .virtio: return "VirtIO Block"
            case .ide: return "IDE"
            }
        }
    }
    enum NetModel: String, CaseIterable, Identifiable {
        case virtio, e1000e, e1000, rtl8139, vmxnet3
        var id: String { rawValue }
        var label: String {
            switch self {
            case .virtio: return "VirtIO (paravirtualized)"
            case .e1000e: return "Intel E1000E"
            case .e1000: return "Intel E1000"
            case .rtl8139: return "Realtek RTL8139"
            case .vmxnet3: return "VMware vmxnet3"
            }
        }
    }
    enum Display: String, CaseIterable, Identifiable {
        case spice, std, virtio, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .spice: return NSLocalizedString("SPICE (best with Chili)", comment: "")
            case .std: return NSLocalizedString("Standard VGA (noVNC)", comment: "")
            case .virtio: return "VirtIO-GPU (noVNC)"
            case .none: return NSLocalizedString("None", comment: "")
            }
        }
    }
    static let scsiControllers = ["virtio-scsi-single", "virtio-scsi-pci", "lsi", "megasas", "pvscsi"]
    static let cpuTypes = ["x86-64-v2", "host", "x86-64-v2-AES", "x86-64-v3", "kvm64", "qemu64"]
    static let cacheModes = ["", "writeback", "writethrough", "directsync", "unsafe"]

    // General
    var node = ""
    var vmid = 100
    var name = ""
    var startAtBoot = false
    // OS
    var os = OS.linux
    var iso: String?            // volid, e.g. "local:iso/debian.iso"
    var virtioISO: String?      // Windows drivers
    // System
    var machine = Machine.q35
    var bios = BIOS.seabios
    var efiStorage = ""
    var addTPM = false
    var scsiController = "virtio-scsi-single"
    var guestAgent = true
    // Disk
    var diskBus = Bus.scsi
    var diskStorage = ""
    var diskSizeGB = 32
    var diskCache = ""
    var discard = true
    var ioThread = true
    var ssdEmulation = false
    // CPU
    var sockets = 1
    var cores = 2
    var cpuType = "x86-64-v2"
    // Memory
    var memoryMiB = 4096
    var ballooning = true
    var minMemoryMiB = 0        // 0 = same as memory
    // Network
    var bridge = ""
    var netModel = NetModel.virtio
    var vlanTag = 0             // 0 = none
    var firewall = true
    // Display & audio
    var display = Display.spice
    var monitors = 1
    var audio = true
    // After creation
    var startAfterCreate = true

    /// Default CPU model: x86-64-v2 (live-migratable, starts on any recent CPU — the
    /// "-AES" variant fails on hosts without AES-NI), or "host" on CPUs too old for v2.
    static func cpuType(forHostFlags flags: String?) -> String {
        guard let flags else { return "x86-64-v2" }
        let set = Set(flags.split(separator: " ").map(String.init))
        let v2: Set = ["cx16", "lahf_lm", "popcnt", "sse4_1", "sse4_2", "ssse3"]
        return set.isSuperset(of: v2) ? "x86-64-v2" : "host"
    }

    /// Set from the node's CPU flags when the wizard loads.
    var recommendedCPUType = "x86-64-v2"

    /// The settings Chili recommends: SPICE display and audio, guest agent, VirtIO
    /// where drivers are available, UEFI + TPM for Windows 11.
    mutating func applyChiliPreset() {
        machine = .q35
        scsiController = "virtio-scsi-single"
        guestAgent = true
        display = .spice
        monitors = 1
        audio = true
        cpuType = recommendedCPUType
        sockets = 1
        diskCache = ""
        discard = true
        ballooning = true
        minMemoryMiB = 0
        firewall = true
        switch os {
        case .win11:
            bios = .ovmf
            addTPM = true
        case .win10:
            bios = .ovmf
            addTPM = false
        case .linux, .other:
            bios = .seabios
            addTPM = false
        }
        if os.isWindows {
            // Without the VirtIO drivers ISO, Windows setup can't see VirtIO disks
            // or NICs: fall back to devices it supports out of the box.
            let drivers = virtioISO != nil
            diskBus = drivers ? .scsi : .sata
            netModel = drivers ? .virtio : .e1000e
            ssdEmulation = true
        } else {
            diskBus = .scsi
            netModel = .virtio
            ssdEmulation = false
        }
        ioThread = diskBus == .scsi || diskBus == .virtio
        if efiStorage.isEmpty { efiStorage = diskStorage }
    }

    var parameters: [String: String] {
        var p: [String: String] = [
            "vmid": String(vmid),
            "ostype": os.ostype,
            "sockets": String(sockets),
            "cores": String(cores),
            "cpu": cpuType,
            "memory": String(memoryMiB),
            "scsihw": scsiController,
            "agent": guestAgent ? "enabled=1" : "enabled=0",
        ]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { p["name"] = trimmed }
        if startAtBoot { p["onboot"] = "1" }
        if machine == .q35 { p["machine"] = "q35" }
        p["bios"] = bios.rawValue
        if bios == .ovmf {
            p["efidisk0"] = "\(efiStorage.isEmpty ? diskStorage : efiStorage):1,efitype=4m"
                + (os.isWindows ? ",pre-enrolled-keys=1" : "")
        }
        if addTPM { p["tpmstate0"] = "\(efiStorage.isEmpty ? diskStorage : efiStorage):1,version=v2.0" }

        var disk = "\(diskStorage):\(diskSizeGB)"
        if discard { disk += ",discard=on" }
        if ioThread && (diskBus == .virtio || (diskBus == .scsi && scsiController == "virtio-scsi-single")) {
            disk += ",iothread=1"
        }
        if ssdEmulation && diskBus != .virtio { disk += ",ssd=1" }
        if !diskCache.isEmpty { disk += ",cache=\(diskCache)" }
        let diskKey = "\(diskBus.rawValue)0"
        p[diskKey] = disk

        p["ide2"] = (iso ?? "none") + ",media=cdrom"
        if let virtioISO, os.isWindows {
            p[diskBus == .ide ? "ide1" : "ide0"] = virtioISO + ",media=cdrom"
        }

        var net = "\(netModel.rawValue),bridge=\(bridge)"
        if firewall { net += ",firewall=1" }
        if vlanTag > 0 { net += ",tag=\(vlanTag)" }
        p["net0"] = net

        if !ballooning {
            p["balloon"] = "0"
        } else if minMemoryMiB > 0 && minMemoryMiB < memoryMiB {
            p["balloon"] = String(minMemoryMiB)
        }

        switch display {
        case .spice: p["vga"] = monitors > 1 ? "qxl\(monitors)" : "qxl"
        case .std: p["vga"] = "std"
        case .virtio: p["vga"] = "virtio"
        case .none: p["vga"] = "none"
        }
        // Audio goes through SPICE; with other displays there would be no way to hear it.
        if audio && display == .spice { p["audio0"] = "device=ich9-intel-hda,driver=spice" }

        p["boot"] = "order=\(diskKey);ide2;net0"
        return p
    }

    /// Problems that would make Proxmox reject the request, for the UI.
    var problems: [String] {
        var list: [String] = []
        if node.isEmpty { list.append(NSLocalizedString("Choose a node.", comment: "")) }
        if diskStorage.isEmpty { list.append(NSLocalizedString("Choose a storage for the disk.", comment: "")) }
        if bridge.isEmpty { list.append(NSLocalizedString("Choose a network bridge.", comment: "")) }
        if vmid < 100 { list.append(NSLocalizedString("The VM ID must be 100 or higher.", comment: "")) }
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n.range(of: "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) == nil {
            list.append(NSLocalizedString("The name may only contain letters, digits, dots and dashes.", comment: ""))
        }
        return list
    }
}
