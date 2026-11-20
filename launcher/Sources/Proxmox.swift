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

    var id: String { "\(node)/\(vmid)" }
    var displayName: String { name ?? "VM \(vmid)" }
    var isRunning: Bool { status == "running" }
    var isTemplate: Bool { (template ?? 0) == 1 }
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
        self.host = host
        self.port = port
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private var baseURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = port
        return c.url!
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
        return all.filter { $0.type == "qemu" && !$0.isTemplate }.sorted { $0.vmid < $1.vmid }
    }

    func start(_ vm: ProxmoxVM) async throws {
        let _: String = try await request("POST", "/api2/json/nodes/\(vm.node)/qemu/\(vm.vmid)/status/start", form: [:])
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
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        req.httpMethod = method
        if let form {
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves '+' alone, which form decoding would read as a space.
            let body = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
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
            if let msg = obj["message"] as? String { return msg.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let errors = obj["errors"] as? [String: String] {
                return errors.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
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
