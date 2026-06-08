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
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self, delegateQueue: nil)
    private(set) var isConnected = false

    var onMessage: ((RelayMessage) -> Void)?
    var onState: ((Bool) -> Void)?   // connected?

    func connect(url: URL) {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        sendJSON(["type": "end"])
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    func setPair(_ a: String, _ b: String) {
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

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.setConnected(false)
            case .success(let msg):
                if case .string(let s) = msg,
                   let data = s.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(RelayMessage.self, from: data) {
                    if decoded.type == "ready" { self.setConnected(true) }
                    DispatchQueue.main.async { self.onMessage?(decoded) }
                }
                self.receiveLoop()
            }
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
