import CryptoKit
import Foundation
import Security

struct ProxmoxVM: Identifiable, Hashable, Decodable {
    let vmid: Int
    let name: String?
    let node: String
    let status: String
    let type: String
    let template: Int?
    let maxmem: Int64?
    let maxcpu: Double?
    let uptime: Int?
    // Live usage, refreshed by Proxmox (pvestatd) roughly every 10 seconds.
    let cpu: Double?        // fraction of maxcpu, 0…1
    let mem: Int64?
    let maxdisk: Int64?
    let netin: Int64?       // cumulative bytes
    let netout: Int64?
    let diskread: Int64?
    let diskwrite: Int64?

    var id: String { "\(node)/\(vmid)" }
    var displayName: String { name ?? "VM \(vmid)" }
    var isRunning: Bool { status == "running" }
    var isTemplate: Bool { (template ?? 0) == 1 }
    var isContainer: Bool { type == "lxc" }
}

struct ProxmoxRealm: Identifiable, Hashable, Decodable {
    let realm: String
    let comment: String?
    var id: String { realm }
}

enum ProxmoxError: LocalizedError {
    case untrustedCertificate(host: String, fingerprint: String)
    case needsTOTP
    case http(Int, String)
    case badResponse
    case noSpice
    case invalidHost(String)

    var errorDescription: String? {
        switch self {
        case .untrustedCertificate(let host, _):
            return String(format: NSLocalizedString("The certificate of %@ is not trusted.", comment: ""), host)
        case .needsTOTP:
            return NSLocalizedString("A two-factor authentication code is required.", comment: "")
        case .http(401, _):
            return NSLocalizedString("Authentication failed: check user name, realm and password.", comment: "")
        case .http(let code, let message):
            return message.isEmpty ? String(format: NSLocalizedString("Server error (HTTP %d).", comment: ""), code) : message
        case .badResponse:
            return NSLocalizedString("Unexpected response from the server.", comment: "")
        case .invalidHost(let host):
            return String(format: NSLocalizedString("“%@” is not a valid host name or IP address.", comment: ""), host)
        case .noSpice:
            return NSLocalizedString("This VM has no SPICE display. In Proxmox, set Hardware → Display to “SPICE (qxl)” and restart the VM.", comment: "")
        }
    }
}

/// Minimal Proxmox VE API client: just what's needed to pick a VM and get its SPICE ticket.
final class ProxmoxClient: NSObject, URLSessionDelegate {
    enum Auth {
        case ticket(ticket: String, csrf: String)
        case token(id: String, secret: String)
    }

    let host: String
    let port: Int
    private(set) var auth: Auth?
    private var session: URLSession!

    init(host: String, port: Int) {
        self.host = Self.normalizedHost(host)
        self.port = port
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private func baseURL() throws -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = port
        guard !host.isEmpty, let url = c.url else { throw ProxmoxError.invalidHost(host) }
        return url
    }

    /// Accepts what people paste from the browser: "https://pve:8006/#v1:0:…" → "pve".
    /// IPv6 literals keep their brackets, as URLComponents expects.
    static func normalizedHost(_ input: String) -> String {
        var h = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(where: { "/?#".contains($0) }) { h = String(h[..<i]) }
        if h.hasPrefix("[") {
            if let close = h.firstIndex(of: "]") { h = String(h[...close]) }
        } else if h.filter({ $0 == ":" }).count == 1, let colon = h.firstIndex(of: ":") {
            h = String(h[..<colon])
        } else if h.contains(":") {
            h = "[\(h)]"     // bare IPv6 address
        }
        return h
    }

    /// The port in a pasted URL ("https://pve:8443"), if any.
    static func port(in input: String) -> Int? {
        var h = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(where: { "/?#".contains($0) }) { h = String(h[..<i]) }
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            let rest = h[h.index(after: close)...]
            return rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
        }
        let parts = h.split(separator: ":")
        return parts.count == 2 ? Int(parts[1]) : nil
    }

    // MARK: Authentication

    func realms() async throws -> [ProxmoxRealm] {
        try await request("GET", "/api2/json/access/domains", authenticated: false)
    }

    /// Logs in with a password. Throws `.needsTOTP` when the account has 2FA;
    /// call again with `otp` set to complete the login.
    func login(username: String, password: String, otp: String? = nil) async throws {
        struct Ticket: Decodable {
            let ticket: String
            let CSRFPreventionToken: String?
            let NeedTFA: Int?
        }
        let first: Ticket = try await request("POST", "/api2/json/access/ticket",
                                              form: ["username": username, "password": password, "new-format": "1"],
                                              authenticated: false)
        guard first.NeedTFA == 1 else {
            guard let csrf = first.CSRFPreventionToken else { throw ProxmoxError.badResponse }
            auth = .ticket(ticket: first.ticket, csrf: csrf)
            return
        }
        guard let otp, !otp.isEmpty else { throw ProxmoxError.needsTOTP }
        let code = otp.trimmingCharacters(in: .whitespaces)
        // Recovery keys contain dashes; TOTP codes are digits only.
        let answer = code.contains("-") ? "recovery:\(code)" : "totp:\(code)"
        let second: Ticket = try await request("POST", "/api2/json/access/ticket",
                                               form: ["username": username, "tfa-challenge": first.ticket,
                                                      "password": answer, "new-format": "1"],
                                               authenticated: false)
        guard let csrf = second.CSRFPreventionToken else { throw ProxmoxError.badResponse }
        auth = .ticket(ticket: second.ticket, csrf: csrf)
    }

    /// Uses an API token ("user@realm!tokenname" + secret) instead of a password.
    func useToken(id: String, secret: String) async throws {
        auth = .token(id: id, secret: secret)
        struct Version: Decodable { let version: String }
        let _: Version = try await request("GET", "/api2/json/version")
    }

    // MARK: VMs

    func virtualMachines() async throws -> [ProxmoxVM] {
        let all: [ProxmoxVM] = try await request("GET", "/api2/json/cluster/resources?type=vm")
        return all.filter { ($0.type == "qemu" || $0.type == "lxc") && !$0.isTemplate }.sorted { $0.vmid < $1.vmid }
    }

    func nodes() async throws -> [String] {
        struct Node: Decodable { let node: String; let status: String? }
        let list: [Node] = try await request("GET", "/api2/json/nodes")
        return list.filter { $0.status != "offline" }.map(\.node).sorted()
    }

    func start(_ vm: ProxmoxVM) async throws {
        let _: String = try await request("POST", "/api2/json/nodes/\(vm.node)/\(vm.type)/\(vm.vmid)/status/start", form: [:])
    }

    // MARK: Inventory for the VM wizard

    struct Storage: Decodable, Hashable, Identifiable {
        let storage: String
        let type: String?
        let content: String?
        let avail: Int64?
        let total: Int64?
        let active: Int?
        var id: String { storage }
    }

    struct StorageItem: Decodable, Hashable, Identifiable {
        let volid: String
        let size: Int64?
        var id: String { volid }
        var fileName: String { volid.split(separator: "/").last.map(String.init) ?? volid }
    }

    struct NetworkInterface: Decodable, Hashable, Identifiable {
        let iface: String
        let type: String?
        let active: Int?
        let comments: String?
        var id: String { iface }
    }

    struct NodeStatus: Decodable {
        struct CPUInfo: Decodable { let cpus: Int?; let model: String?; let flags: String? }
        struct Memory: Decodable { let total: Int64?; let free: Int64? }
        let cpuinfo: CPUInfo?
        let memory: Memory?
    }

    func nextVMID() async throws -> Int {
        // Returned as a string ("102") by most versions, as a number by some.
        let data = try await raw("GET", "/api2/json/cluster/nextid")
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["data"] as? String, let n = Int(s) { return n }
            if let n = obj["data"] as? Int { return n }
        }
        throw ProxmoxError.badResponse
    }

    /// Storages of a node that accept `content` (images, iso, rootdir, vztmpl).
    func storages(node: String, content: String) async throws -> [Storage] {
        let list: [Storage] = try await request("GET", "/api2/json/nodes/\(node)/storage?content=\(content)&enabled=1")
        return list.filter { ($0.active ?? 1) == 1 }.sorted { $0.storage < $1.storage }
    }

    func isoImages(node: String, storage: String) async throws -> [StorageItem] {
        let list: [StorageItem] = try await request("GET", "/api2/json/nodes/\(node)/storage/\(storage)/content?content=iso")
        return list.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    func bridges(node: String) async throws -> [NetworkInterface] {
        let list: [NetworkInterface] = try await request("GET", "/api2/json/nodes/\(node)/network?type=any_bridge")
        return list.sorted { $0.iface < $1.iface }
    }

    func nodeStatus(node: String) async throws -> NodeStatus {
        try await request("GET", "/api2/json/nodes/\(node)/status")
    }

    // MARK: Creating and managing VMs

    /// A VM's configuration as strings (for display and checks).
    func vmConfig(_ vm: ProxmoxVM) async throws -> [String: String] {
        let data = try await raw("GET", "/api2/json/nodes/\(vm.node)/\(vm.type)/\(vm.vmid)/config")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = obj["data"] as? [String: Any] else { throw ProxmoxError.badResponse }
        return config.mapValues { "\($0)" }
    }

    /// Creates a QEMU VM; returns the task id (UPID).
    func createVM(node: String, parameters: [String: String]) async throws -> String {
        try await request("POST", "/api2/json/nodes/\(node)/qemu", form: parameters)
    }

    enum PowerAction: String { case start, shutdown, reboot, stop, reset, suspend, resume }

    @discardableResult
    func power(_ vm: ProxmoxVM, _ action: PowerAction) async throws -> String {
        try await request("POST", "/api2/json/nodes/\(vm.node)/\(vm.type)/\(vm.vmid)/status/\(action.rawValue)", form: [:])
    }

    /// Deletes a stopped VM or container together with its disks.
    @discardableResult
    func delete(_ vm: ProxmoxVM) async throws -> String {
        try await request("DELETE", "/api2/json/nodes/\(vm.node)/\(vm.type)/\(vm.vmid)?purge=1&destroy-unreferenced-disks=1")
    }

    // MARK: History and logs

    struct TaskEntry: Decodable, Identifiable, Hashable {
        let upid: String
        let type: String
        let status: String?        // "OK", an error, or nil while running
        let starttime: Int
        let endtime: Int?
        let user: String?
        let node: String
        var id: String { upid }
        var isRunning: Bool { endtime == nil }
        var succeeded: Bool { status == "OK" }
        var startDate: Date { Date(timeIntervalSince1970: TimeInterval(starttime)) }
        var duration: TimeInterval? { endtime.map { TimeInterval($0 - starttime) } }
    }

    /// Proxmox' task history for one VM or container, newest first.
    func tasks(for vm: ProxmoxVM, limit: Int = 100) async throws -> [TaskEntry] {
        let list: [TaskEntry] = try await request("GET", "/api2/json/nodes/\(vm.node)/tasks?vmid=\(vm.vmid)&limit=\(limit)&source=all")
        return list.sorted { $0.starttime > $1.starttime }
    }

    func taskLog(node: String, upid: String) async throws -> [String] {
        struct Line: Decodable { let t: String }
        let escaped = upid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? upid
        let lines: [Line] = try await request("GET", "/api2/json/nodes/\(node)/tasks/\(escaped)/log?limit=5000")
        return lines.map(\.t)
    }

    /// The latest entries of the node's system journal (newest last).
    /// (/syslog pages from the oldest entry; /journal?lastentries gives the tail.)
    func syslog(node: String, lines: Int = 1000) async throws -> [String] {
        let list: [String] = try await request("GET", "/api2/json/nodes/\(node)/journal?lastentries=\(lines)")
        // Drop journalctl's cursor lines ("s=…;i=…;b=…") and "-- …" markers.
        return list.filter { !$0.hasPrefix("-- ") && !($0.hasPrefix("s=") && $0.contains(";i=") && $0.contains(";b=")) }
    }

    // MARK: Containers

    /// Container templates already on a storage (volids like "local:vztmpl/debian-12-standard_….tar.zst").
    func containerTemplates(node: String, storage: String) async throws -> [StorageItem] {
        let list: [StorageItem] = try await request("GET", "/api2/json/nodes/\(node)/storage/\(storage)/content?content=vztmpl")
        return list.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    struct Appliance: Decodable, Hashable, Identifiable {
        let template: String
        let headline: String?
        let os: String?
        let section: String?
        let version: String?
        var id: String { template }
    }

    /// Proxmox' catalogue of downloadable container templates.
    func appliances(node: String) async throws -> [Appliance] {
        let list: [Appliance] = try await request("GET", "/api2/json/nodes/\(node)/aplinfo")
        return list.filter { $0.section == "system" }.sorted { $0.template < $1.template }
    }

    func downloadTemplate(node: String, storage: String, template: String) async throws -> String {
        try await request("POST", "/api2/json/nodes/\(node)/aplinfo", form: ["storage": storage, "template": template])
    }

    /// Creates an LXC container; returns the task id.
    func createContainer(node: String, parameters: [String: String]) async throws -> String {
        try await request("POST", "/api2/json/nodes/\(node)/lxc", form: parameters)
    }

    /// Log of the most recent task for a VM (for diagnostics).
    func lastTaskLog(_ vm: ProxmoxVM) async throws -> [String] {
        struct TaskEntry: Decodable { let upid: String }
        struct Line: Decodable { let t: String }
        let tasks: [TaskEntry] = try await request("GET", "/api2/json/nodes/\(vm.node)/tasks?vmid=\(vm.vmid)&limit=1")
        guard let upid = tasks.first?.upid else { return [] }
        let escaped = upid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? upid
        let lines: [Line] = try await request("GET", "/api2/json/nodes/\(vm.node)/tasks/\(escaped)/log?limit=500")
        return lines.map(\.t)
    }

    struct TaskStatus: Decodable {
        let status: String          // "running" / "stopped"
        let exitstatus: String?     // "OK" or the error
    }

    /// Waits for a Proxmox task; throws with the task's last log lines if it failed.
    func waitForTask(node: String, upid: String, timeout: TimeInterval = 600) async throws {
        let escaped = upid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":@"))) ?? upid
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let st: TaskStatus = try await request("GET", "/api2/json/nodes/\(node)/tasks/\(escaped)/status")
            if st.status == "stopped" {
                if st.exitstatus == "OK" { return }
                struct Line: Decodable { let t: String }
                let log: [Line] = (try? await request("GET", "/api2/json/nodes/\(node)/tasks/\(escaped)/log?limit=500")) ?? []
                let tail = log.suffix(6).map(\.t).joined(separator: "\n")
                throw ProxmoxError.http(0, [st.exitstatus ?? "", tail].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw ProxmoxError.http(0, NSLocalizedString("The task is taking too long; check it in Proxmox.", comment: ""))
    }

    // MARK: Web consoles (noVNC / xterm.js served by Proxmox itself)

    enum WebConsoleKind { case vm(ProxmoxVM), nodeShell(String) }

    /// The web UI URL that opens Proxmox's own console page for a VM, container or node.
    func webConsoleURL(_ kind: WebConsoleKind) throws -> URL {
        var c = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false)!
        c.path = "/"
        switch kind {
        case .vm(let vm) where vm.isContainer:
            c.queryItems = [.init(name: "console", value: "lxc"), .init(name: "xtermjs", value: "1"),
                            .init(name: "vmid", value: String(vm.vmid)), .init(name: "vmname", value: vm.name ?? ""),
                            .init(name: "node", value: vm.node)]
        case .vm(let vm):
            c.queryItems = [.init(name: "console", value: "kvm"), .init(name: "novnc", value: "1"),
                            .init(name: "vmid", value: String(vm.vmid)), .init(name: "vmname", value: vm.name ?? ""),
                            .init(name: "node", value: vm.node), .init(name: "resize", value: "scale")]
        case .nodeShell(let node):
            c.queryItems = [.init(name: "console", value: "shell"), .init(name: "xtermjs", value: "1"),
                            .init(name: "node", value: node)]
        }
        return c.url!
    }

    /// Cookie that logs the web console page in. Proxmox' web pages need a
    /// password-based ticket; API tokens can't be used there.
    func authCookie() -> HTTPCookie? {
        guard case .ticket(let ticket, _) = auth else { return nil }
        return HTTPCookie(properties: [
            .name: "PVEAuthCookie",
            .value: ticket.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ticket,
            .domain: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            .path: "/",
            .secure: "TRUE",
        ])
    }

    var usesTicket: Bool {
        if case .ticket = auth { return true }
        return false
    }

    /// Tickets are valid for two hours; an existing ticket can be traded for a new one.
    func renewTicket(username: String) async throws {
        guard case .ticket(let ticket, _) = auth else { return }
        try await login(username: username, password: ticket)
    }

    /// Asks Proxmox for a one-time SPICE ticket. The connection goes through the
    /// node's spiceproxy (TCP 3128) on the same host we're talking to.
    func spiceConfig(for vm: ProxmoxVM) async throws -> ViewerConfig {
        do {
            let data = try await raw("POST", "/api2/spiceconfig/nodes/\(vm.node)/qemu/\(vm.vmid)/spiceproxy",
                                     form: ["proxy": host])
            guard let text = String(data: data, encoding: .utf8), text.contains("[virt-viewer]") else {
                throw ProxmoxError.badResponse
            }
            return ViewerConfig(vvText: text)
        } catch ProxmoxError.http(let code, let msg) where code >= 500 {
            // The reason is only in the HTTP status line; check the usual suspect ourselves.
            if try await !hasSpiceDisplay(vm) { throw ProxmoxError.noSpice }
            throw ProxmoxError.http(code, msg)
        }
    }

    private func hasSpiceDisplay(_ vm: ProxmoxVM) async throws -> Bool {
        struct Config: Decodable { let vga: String? }
        let config: Config = try await request("GET", "/api2/json/nodes/\(vm.node)/qemu/\(vm.vmid)/config")
        return config.vga?.hasPrefix("qxl") ?? false
    }

    // MARK: Plumbing

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private func request<T: Decodable>(_ method: String, _ path: String, form: [String: String]? = nil,
                                       authenticated: Bool = true) async throws -> T {
        let data = try await raw(method, path, form: form, authenticated: authenticated)
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data).data
        } catch {
            throw ProxmoxError.badResponse
        }
    }

    private func raw(_ method: String, _ path: String, form: [String: String]? = nil,
                     authenticated: Bool = true) async throws -> Data {
        guard let url = URL(string: path, relativeTo: try baseURL()) else { throw ProxmoxError.invalidHost(host) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let form {
            // Strict encoding: Proxmox splits form fields on ';' as well as '&', and VM
            // options such as "boot=order=scsi0;ide2" are full of ';', '=' and ','.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let body = form.map { key, value in
                (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "="
                    + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            }.joined(separator: "&")
            req.httpBody = Data(body.utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            switch auth {
            case .ticket(let ticket, let csrf):
                req.setValue("PVEAuthCookie=\(ticket)", forHTTPHeaderField: "Cookie")
                if method != "GET" { req.setValue(csrf, forHTTPHeaderField: "CSRFPreventionToken") }
            case .token(let id, let secret):
                req.setValue("PVEAPIToken=\(id)=\(secret)", forHTTPHeaderField: "Authorization")
            case nil:
                break
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled || e.code == .serverCertificateUntrusted
                                       || e.code == .serverCertificateHasUnknownRoot {
            if let fp = lastRejectedFingerprint { throw ProxmoxError.untrustedCertificate(host: host, fingerprint: fp) }
            throw e
        }
        guard let http = response as? HTTPURLResponse else { throw ProxmoxError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProxmoxError.http(http.statusCode, Self.errorMessage(http, data))
        }
        return data
    }

    private static func errorMessage(_ response: HTTPURLResponse, _ data: Data) -> String {
        // Proxmox puts the human-readable reason in the HTTP status line, which
        // URLSession doesn't expose; fall back to the JSON body.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // "Parameter verification failed." comes with the details per parameter in "errors".
            var parts: [String] = []
            if let msg = obj["message"] as? String { parts.append(msg.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let errors = obj["errors"] as? [String: Any] {
                parts += errors.sorted { $0.key < $1.key }.map { "\($0.key): \("\($0.value)".trimmingCharacters(in: .whitespacesAndNewlines))" }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: TLS — Proxmox ships a self-signed certificate, so we trust on first use

    private var lastRejectedFingerprint: String?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        let fingerprint = Self.fingerprint(of: trust)
        if let fingerprint, TrustStore.isTrusted(fingerprint, host: host, port: port) {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        lastRejectedFingerprint = fingerprint
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Certificate fingerprints the user explicitly accepted, per host:port.
enum TrustStore {
    private static let key = "trustedCertificates"

    static func isTrusted(_ fingerprint: String, host: String, port: Int) -> Bool {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return all["\(host.lowercased()):\(port)"] == fingerprint
    }

    static func trust(_ fingerprint: String, host: String, port: Int) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all["\(host.lowercased()):\(port)"] = fingerprint
        UserDefaults.standard.set(all, forKey: key)
    }
}
