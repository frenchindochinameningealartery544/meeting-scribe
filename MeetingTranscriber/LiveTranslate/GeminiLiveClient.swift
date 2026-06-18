import Foundation

/// Events surfaced from the Gemini Live API bidi stream.
enum LiveEvent {
    case ready                  // setupComplete received
    case input(String)          // transcript of the source audio
    case output(String)         // transcript of the translated audio (the caption)
    case turnComplete           // model finished the current utterance
    case closed(String?)        // stream ended; non-nil = error message
}

/// Thin WebSocket client for the Gemini Live API (BidiGenerateContent).
/// Sends a setup frame, streams 16-bit PCM audio, and surfaces input/output
/// transcription text. Speech-to-speech audio in the response is ignored — we
/// only consume the transcription, which is the live caption.
///
/// URLSessionWebSocketTask's send/receive are safe to call from any thread, so
/// this is a plain class; `onEvent` is always delivered on the main queue.
final class GeminiLiveClient {
    private let task: URLSessionWebSocketTask
    private var closed = false

    /// Delivered on the main queue.
    var onEvent: ((LiveEvent) -> Void)?

    init(apiKey: String) {
        var comps = URLComponents(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        task = URLSession.shared.webSocketTask(with: comps.url!)
    }

    /// Open the socket and send the setup frame. `targetCode` is a BCP-47 code.
    func start(targetCode: String) {
        NSLog("GeminiLive: start() resuming socket, target=\(targetCode)")
        task.resume()
        // Field placement matters: `inputAudioTranscription` and
        // `outputAudioTranscription` live at the setup top level, while
        // `responseModalities` and `translationConfig` go inside
        // `generationConfig` (verified against the live server — anything else
        // is rejected with a 1007 "Unknown name" error).
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-live-translate-preview",
                "inputAudioTranscription": [:],
                "outputAudioTranscription": [:],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": targetCode,
                        "echoTargetLanguage": false
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: setup) else {
            emit(.closed("Could not encode setup")); return
        }
        task.send(.data(data)) { [weak self] err in
            if let err {
                NSLog("GeminiLive: setup send FAILED: \(err.localizedDescription)")
                self?.emit(.closed(err.localizedDescription)); return
            }
            NSLog("GeminiLive: setup sent, receiving")
            self?.receive()
        }
    }

    /// Stream one chunk of base64-encoded 16-bit PCM (16 kHz mono, little-endian).
    func sendAudio(base64 b64: String) {
        guard !closed else { return }
        let json = "{\"realtimeInput\":{\"audio\":{\"data\":\"\(b64)\",\"mimeType\":\"audio/pcm;rate=16000\"}}}"
        task.send(.string(json)) { _ in }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: – Receive loop

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let e):
                NSLog("GeminiLive: receive FAILED (socket closed): \(e.localizedDescription)")
                self.emit(.closed(e.localizedDescription))
            case .success(let message):
                self.handle(message)
                self.receive()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):   data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default:    return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if obj["setupComplete"] != nil {
            NSLog("GeminiLive: setupComplete received → ready")
            emit(.ready)
        }

        guard let content = obj["serverContent"] as? [String: Any] else { return }

        if let input = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
           !input.isEmpty {
            emit(.input(input))
        }
        if let output = (content["outputTranscription"] as? [String: Any])?["text"] as? String,
           !output.isEmpty {
            emit(.output(output))
        }
        if (content["turnComplete"] as? Bool) == true ||
           (content["generationComplete"] as? Bool) == true {
            emit(.turnComplete)
        }
    }

    private func emit(_ event: LiveEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
