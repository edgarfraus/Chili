import Foundation

/// CHILI_DEMO=1: a made-up server with sample VMs, for screenshots and UI work.
/// No network, no Keychain, and the saved server list is left untouched.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["CHILI_DEMO"] != nil

    static let profile = ServerProfile(name: "Homelab", host: "pve.example.lan")

    static let vms: [ProxmoxVM] = [
        vm(100, "win11-desktop", "qemu", running: true, cpus: 4, memGB: 8, cpu: 0.27, mem: 0.62),
        vm(101, "ubuntu-server", "qemu", running: true, cpus: 2, memGB: 4, cpu: 0.06, mem: 0.38),
        vm(102, "debian-web", "lxc", running: true, cpus: 1, memGB: 1, cpu: 0.02, mem: 0.21),
        vm(103, "pihole", "lxc", running: true, cpus: 1, memGB: 0.5, cpu: 0.01, mem: 0.44),
        vm(104, "truenas", "qemu", running: true, cpus: 2, memGB: 16, cpu: 0.81, mem: 0.93),
        vm(105, "win-server-2022", "qemu", running: false, cpus: 4, memGB: 8, cpu: 0, mem: 0),
        vm(106, "fedora-test", "qemu", running: false, cpus: 2, memGB: 4, cpu: 0, mem: 0),
    ]

    private static func vm(_ id: Int, _ name: String, _ type: String, running: Bool, cpus: Double, memGB: Double,
                           cpu: Double, mem: Double) -> ProxmoxVM {
        let maxmem = Int64(memGB * 1_073_741_824)
        return ProxmoxVM(vmid: id, name: name, node: "pve1", status: running ? "running" : "stopped", type: type,
                         template: nil, maxmem: maxmem, maxcpu: cpus, uptime: running ? 86_400 : nil,
                         cpu: running ? cpu : nil, mem: running ? Int64(Double(maxmem) * mem) : nil, maxdisk: nil,
                         netin: running ? Int64(id) * 1_000_000 : nil, netout: running ? Int64(id) * 400_000 : nil,
                         diskread: nil, diskwrite: nil)
    }
}
