import Foundation

/// Server -> client message.
struct RelayMessage: Decodable {
    let type: String          // "ready" | "interim" | "final" | "error"
    let seq: Int?
    let src: String?
    let tgt: String?
    let source: String?
    let translation: String?
    let message: String?      // for errors
}

/// Thin WebSocket client to the Python relay. Sends binary PCM16 chunks and
/// JSON control frames; decodes JSON results back.
///
/// Stability: while `active` (between connect() and disconnect()) it transparently
/// reconnects with backoff whenever the socket drops — so a tunnel hiccup or a
/// relay restart never ends the session. The current language pair is re-sent on
/// every (re)connect.
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    let name: String                       // "mic" | "system" — for diagnostics/logging
    init(name: String) { self.name = name; super.init() }

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self, delegateQueue: nil)
    private(set) var isConnected = false

    private var active = false              // user wants the session up
    private var url: URL?
    private var pair: (String, String) = ("ko", "ja")
    private var reconnectDelay: TimeInterval = 0.5
    private var generation = 0              // invalidates stale receive loops

    var onMessage: ((RelayMessage) -> Void)?
    var onState: ((Bool) -> Void)?   // connected?

    func connect(url: URL) {
        self.url = url
        active = true
        openSocket()
    }

    private func openSocket() {
        guard active, let url else { return }
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(gen: gen)
    }

    func disconnect() {
        active = false
        generation += 1
        sendJSON(["type": "end"])
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    func setPair(_ a: String, _ b: String) {
        pair = (a, b)
        sendJSON(["type": "config", "pair": [a, b]])
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        task?.send(.data(data)) { _ in }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func receiveLoop(gen: Int) {
        task?.receive { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .failure:
                self.setConnected(false)
                self.scheduleReconnect(gen: gen)
            case .success(let msg):
                if case .string(let s) = msg,
                   let data = s.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(RelayMessage.self, from: data) {
                    if decoded.type == "ready" {
                        self.reconnectDelay = 0.5          // reset backoff
                        self.setConnected(true)
                        // Re-assert our language pair after a (re)connect.
                        self.sendJSON(["type": "config", "pair": [self.pair.0, self.pair.1]])
                    }
                    DispatchQueue.main.async { self.onMessage?(decoded) }
                }
                self.receiveLoop(gen: gen)
            }
        }
    }

    private func scheduleReconnect(gen: Int) {
        guard active, gen == generation else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 5.0)      // capped exponential backoff
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active, gen == self.generation else { return }
            self.openSocket()
        }
    }

    private func setConnected(_ v: Bool) {
        guard isConnected != v else { return }
        isConnected = v
        DispatchQueue.main.async { self.onState?(v) }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // We flip isConnected on the "ready" frame instead, to ensure the
        // relay's ASR model finished loading.
    }
}
