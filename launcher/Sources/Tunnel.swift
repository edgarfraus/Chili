import Foundation
import Network

/// Reaches Proxmox' spiceproxy (TCP 3128) through a Cloudflare Tunnel without any client software:
/// the tunnel publishes it as `service: tcp://localhost:3128` on its own hostname, and Cloudflare
/// carries such services as WebSocket streams over HTTPS (what `cloudflared access tcp` does).
/// This listens on 127.0.0.1 and pipes every accepted connection through its own WebSocket to
/// `wss://<host>/` in binary frames. SPICE then uses `proxy=http://127.0.0.1:<port>`.
/// Same design as the Windows app (`TcpOverWebSocket.cs`).
final class TcpOverWebSocket: NSObject, URLSessionWebSocketDelegate {
    let endpoint: URL
    private let queue = DispatchQueue(label: "chili.tunnel")
    private var listener: NWListener?
    private var startWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var pipes: [Int: Pipe] = [:]   // by URLSessionTask.taskIdentifier
    private lazy var urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3600 * 24   // idle SPICE channels are fine; the handshake has its own timer
        c.timeoutIntervalForResource = .infinity
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private let lock = NSLock()
    private var _lastError: String?
    private var _bridged = 0
    /// The last failure to open a WebSocket, for diagnostics.
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return _lastError }
    /// WebSockets opened so far (diagnostics / debug action).
    var bridgedCount: Int { lock.lock(); defer { lock.unlock() }; return _bridged }

    /// - Parameter host: hostname of the tunnel's TCP service, e.g. "spice.example.com" (or a wss:// URL).
    init(host: String) {
        endpoint = Self.endpoint(for: host)
        super.init()
    }

    /// "spice.example.com" → wss://spice.example.com/ (ws:// and wss:// URLs are kept, https → wss).
    static func endpoint(for host: String) -> URL {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = h.lowercased()
        if lower.hasPrefix("https://") { h = "wss://" + h.dropFirst(8) }
        else if lower.hasPrefix("http://") { h = "ws://" + h.dropFirst(7) }
        else if !lower.hasPrefix("ws://") && !lower.hasPrefix("wss://") { h = "wss://" + h }
        if var c = URLComponents(string: h) {
            if c.path.isEmpty { c.path = "/" }
            if let url = c.url { return url }
        }
        return URL(string: "wss://invalid.invalid/")!
    }

    /// Starts listening (once) and returns the local port SPICE should use as its HTTP proxy.
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

    /// Closes the listener and every open stream. Required: the URL session keeps this object alive.
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for p in pipes.values { p.close() }
            pipes = [:]
        }
        urlSession.invalidateAndCancel()
    }

    // MARK: One TCP connection ↔ one WebSocket

    private final class Pipe {
        let tcp: NWConnection
        let ws: URLSessionWebSocketTask
        var opened = false
        var closed = false
        var ping: DispatchSourceTimer?
        let onClose: () -> Void

        init(tcp: NWConnection, ws: URLSessionWebSocketTask, onClose: @escaping () -> Void) {
            self.tcp = tcp; self.ws = ws; self.onClose = onClose
        }

        func close() {
            guard !closed else { return }
            closed = true
            ping?.cancel()
            tcp.cancel()
            ws.cancel(with: .normalClosure, reason: nil)
            onClose()
        }
    }

    private func accept(_ tcp: NWConnection) {
        let ws = urlSession.webSocketTask(with: endpoint)
        ws.maximumMessageSize = 16 * 1024 * 1024
        let id = ws.taskIdentifier
        let pipe = Pipe(tcp: tcp, ws: ws) { [weak self] in self?.pipes[id] = nil }
        pipes[id] = pipe
        tcp.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: pipe.close()
            default: break
            }
        }
        tcp.start(queue: queue)
        ws.resume()
        // Opening the WebSocket must not take forever; afterwards, keep idle channels alive.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard !pipe.opened, !pipe.closed else { return }
            self?.record(NSLocalizedString("The connection timed out.", comment: ""))
            pipe.close()   // closing the TCP connection makes SPICE report the failure
        }
        tcpToWebSocket(pipe)
        webSocketToTcp(pipe)
    }

    private func tcpToWebSocket(_ pipe: Pipe) {
        pipe.tcp.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !pipe.closed else { return }
            if let data, !data.isEmpty {
                pipe.ws.send(.data(data)) { error in
                    self.queue.async {
                        if error != nil { pipe.close() } else if !isComplete { self.tcpToWebSocket(pipe) } else { pipe.close() }
                    }
                }
            } else if isComplete || error != nil {
                pipe.close()   // one side ended: end the other too
            } else {
                self.tcpToWebSocket(pipe)
            }
        }
    }

    private func webSocketToTcp(_ pipe: Pipe) {
        pipe.ws.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !pipe.closed else { return }
                switch result {
                case .failure:
                    pipe.close()
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = Data(s.utf8)
                    @unknown default: data = Data()
                    }
                    pipe.tcp.send(content: data, completion: .contentProcessed { error in
                        self.queue.async { if error != nil { pipe.close() } else { self.webSocketToTcp(pipe) } }
                    })
                }
            }
        }
    }

    private func record(_ error: String) {
        lock.lock(); _lastError = error; lock.unlock()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let id = webSocketTask.taskIdentifier
        lock.lock(); _bridged += 1; lock.unlock()
        queue.async { [self] in
            guard let pipe = pipes[id] else { return }
            pipe.opened = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20)
            t.setEventHandler { [weak pipe] in pipe?.ws.sendPing { _ in } }
            t.resume()
            pipe.ping = t
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        queue.async { [self] in
            let pipe = pipes[id]
            if let error, pipe?.opened == false {
                var message = error.localizedDescription
                if let http = task.response as? HTTPURLResponse {
                    message = "HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
                }
                record(message)
            }
            pipe?.close()
        }
    }
}
