import Foundation
import Network

/// Puts Proxmox' web consoles (noVNC, xterm.js) behind Cloudflare Access with a service token.
/// WKWebView can add headers to page navigations but not to the console's WebSocket, and Access
/// doesn't answer a service token with a cookie, so the WebSocket got a 403 ("Failed to connect to
/// server"). This proxy listens on 127.0.0.1 over plain HTTP (the console pages then use ws://,
/// Proxmox' noVNC and xterm.js pick the scheme from the page) and forwards every request, WebSocket
/// upgrades included, to the Proxmox host over TLS with the extra headers. One request per
/// connection (it asks for `Connection: close`), so it never has to parse a body.
/// Same design as the Windows app (`WebConsoleProxy.cs`, which speaks HTTPS to WebView2 instead).
final class WebConsoleProxy {
    let host: String
    let port: Int
    private let headers: [String: String]
    /// Checks the Proxmox host's certificate (the API's rule: valid, or pinned by the user).
    private let accepts: (SecTrust) -> Bool
    private let queue = DispatchQueue(label: "chili.webconsole-proxy")
    private var listener: NWListener?
    private var startWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var exchanges: [ObjectIdentifier: Exchange] = [:]

    private let lock = NSLock()
    private var _lastError: String?
    /// The last failure to reach the Proxmox host, for diagnostics.
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }

    init(host: String, port: Int, headers: [String: String], accepts: @escaping (SecTrust) -> Bool) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
        self.headers = headers
        self.accepts = accepts
    }

    /// The same page, through the proxy.
    static func local(_ remote: URL, port: UInt16) -> URL {
        var c = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Int(port)
        return c.url ?? remote
    }

    /// Starts listening (once) and returns the local port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                if let l = listener, let port = l.port?.rawValue, l.state == .ready { return cont.resume(returning: port) }
                startWaiters.append(cont)
                guard listener == nil else { return }
                do {
                    let params = NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    params.allowLocalEndpointReuse = true
                    let l = try NWListener(using: params)
                    listener = l
                    l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                    l.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                    l.start(queue: queue)
                } catch {
                    failWaiters(error)
                }
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            let waiters = startWaiters
            startWaiters = []
            for w in waiters { w.resume(returning: port) }
        case .failed(let e):
            listener?.cancel()
            listener = nil
            failWaiters(e)
        default: break
        }
    }

    private func failWaiters(_ error: Error) {
        let waiters = startWaiters
        startWaiters = []
        for w in waiters { w.resume(throwing: error) }
    }

    /// Closes the listener and every open connection (the console's WebSocket included).
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for e in exchanges.values { e.close() }
            exchanges = [:]
        }
    }

    private func setLastError(_ message: String) {
        lock.lock(); _lastError = message; lock.unlock()
    }

    // MARK: One browser connection ↔ one connection to Proxmox

    private func accept(_ client: NWConnection) {
        let tls = NWProtocolTLS.Options()
        let accepts = self.accepts
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(accepts(sec_trust_copy_ref(trust).takeRetainedValue()))
        }, queue)
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 443,
                                    using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let exchange = Exchange(client: client, upstream: upstream, proxy: self)
        let id = ObjectIdentifier(exchange)
        exchanges[id] = exchange
        exchange.onClose = { [weak self] in self?.exchanges[id] = nil }
        exchange.start(queue: queue)
    }

    private var authority: String { port == 443 ? hostForHeader : "\(hostForHeader):\(port)" }
    private var hostForHeader: String { host.contains(":") ? "[\(host)]" : host }
    private var origin: String { "https://\(authority)" }

    /// Host, Origin and Referer point at the Proxmox host; the extra headers are added; keep-alive
    /// is turned off (upgrades keep their Connection: Upgrade).
    fileprivate func rewriteRequest(_ head: String) -> (Data, upgrade: Bool) {
        let lines = head.components(separatedBy: "\r\n")
        let fields = lines.dropFirst().compactMap(Self.split)
        let upgrade = fields.contains { $0.name.lowercased() == "upgrade" }
            && fields.contains { $0.name.lowercased() == "connection" && $0.value.lowercased().contains("upgrade") }
        let dropped = Set(["host", "connection", "keep-alive", "proxy-connection"] + headers.keys.map { $0.lowercased() })
        var out = lines[0] + "\r\nHost: \(authority)\r\n"
        for (name, value) in fields where !dropped.contains(name.lowercased()) {
            var v = value
            if name.lowercased() == "origin" { v = origin }
            else if name.lowercased() == "referer", let r = URLComponents(string: value) {
                v = origin + (r.percentEncodedPath.isEmpty ? "/" : r.percentEncodedPath)
                    + (r.percentEncodedQuery.map { "?" + $0 } ?? "")
            }
            out += "\(name): \(v)\r\n"
        }
        out += "Connection: \(upgrade ? "Upgrade" : "close")\r\n"
        for (k, v) in headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        return (Data(out.utf8), upgrade)
    }

    /// Tells the browser not to reuse the connection (one request each), except for a switch to WebSocket.
    fileprivate static func rewriteResponse(_ head: String, upgrade: Bool) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        let switching = upgrade && status.count > 1 && status[1] == "101"
        var out = lines[0] + "\r\n"
        for line in lines.dropFirst() {
            let name = split(line)?.name.lowercased() ?? ""
            if !switching && (name == "connection" || name == "keep-alive") { continue }
            out += line + "\r\n"
        }
        if !switching { out += "Connection: close\r\n" }
        out += "\r\n"
        return Data(out.utf8)
    }

    private static func split(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
        return (line[..<colon].trimmingCharacters(in: .whitespaces),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    fileprivate func upstreamFailed(_ error: NWError) { setLastError(error.localizedDescription) }

    /// Runs on the proxy's queue.
    private final class Exchange {
        let client: NWConnection
        let upstream: NWConnection
        weak var proxy: WebConsoleProxy?
        var onClose: (() -> Void)?
        private var closed = false
        private var upgrade = false
        /// The response head went to the browser: a later failure just closes.
        private var responded = false
        private static let headEnd = Data("\r\n\r\n".utf8)
        private static let maxHead = 65536

        init(client: NWConnection, upstream: NWConnection, proxy: WebConsoleProxy) {
            self.client = client
            self.upstream = upstream
            self.proxy = proxy
        }

        func start(queue: DispatchQueue) {
            client.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
            upstream.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e), .waiting(let e):
                    self?.proxy?.upstreamFailed(e)
                    self?.badGateway()
                case .cancelled: self?.close()
                default: break
                }
            }
            client.start(queue: queue)
            readHead(from: client, buffer: Data()) { [weak self] head, rest in
                guard let self, let proxy = self.proxy else { return }
                let (request, upgrade) = proxy.rewriteRequest(head)
                self.upgrade = upgrade
                self.upstream.start(queue: queue)
                self.upstream.send(content: request + rest, completion: .contentProcessed { _ in })
                self.pump(from: self.client, to: self.upstream)
                self.readHead(from: self.upstream, buffer: Data()) { [weak self] responseHead, more in
                    guard let self else { return }
                    self.responded = true
                    let rewritten = WebConsoleProxy.rewriteResponse(responseHead, upgrade: self.upgrade)
                    self.client.send(content: rewritten + more, completion: .contentProcessed { _ in })
                    self.pump(from: self.upstream, to: self.client)
                }
            }
        }

        /// Reads up to the blank line that ends an HTTP head; calls back with the head's text and any
        /// bytes read past it, or closes if the stream ends first.
        private func readHead(from c: NWConnection, buffer: Data, then: @escaping (String, Data) -> Void) {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let r = buffer.range(of: Self.headEnd) {
                    let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                    return then(head, Data(buffer[r.upperBound...]))
                }
                if isComplete || error != nil || buffer.count > Self.maxHead { return self.close() }
                self.readHead(from: c, buffer: buffer, then: then)
            }
        }

        /// Copies bytes until `from` ends, then closes the exchange.
        private func pump(from: NWConnection, to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        if sendError != nil { self?.close() }
                    })
                }
                if isComplete || error != nil {
                    // Let what was queued go out before closing.
                    to.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
                    return
                }
                self.pump(from: from, to: to)
            }
        }

        private func badGateway() {
            guard !closed else { return }
            if responded { return close() }
            let answer = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            client.send(content: answer, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
        }

        func close() {
            guard !closed else { return }
            closed = true
            client.cancel()
            upstream.cancel()
            onClose?()
            onClose = nil
        }
    }
}
