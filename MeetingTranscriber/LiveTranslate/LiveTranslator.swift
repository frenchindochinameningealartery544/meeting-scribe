import Foundation

/// One finalized live-translation line.
struct LiveCaption: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translated: String
}

/// Drives a live-translation session: takes 16 kHz mono float samples from the
/// recording pipeline, packs them into 100 ms 16-bit PCM chunks, streams them to
/// the Gemini Live API, and turns the returned transcription text into captions.
///
/// Audio is fed from the capture thread; buffering happens on a private serial
/// queue. Caption updates are published via `onUpdate` on the main queue.
final class LiveTranslator {
    /// 100 ms at 16 kHz.
    private static let chunkFrames = 1600

    private let client: GeminiLiveClient
    private let queue = DispatchQueue(label: "live.translate.buffer")
    private var pending: [Float] = []

    // Accumulated text for the in-progress turn.
    private var currentOriginal = ""
    private var currentTranslated = ""

    /// (finalized captions, in-progress translated line). Main queue.
    var onUpdate: (([LiveCaption], String) -> Void)?
    /// Connection status. Main queue. nil error = healthy/closed cleanly.
    var onStatus: ((Status) -> Void)?

    enum Status: Equatable { case connecting, live, closed(String?) }

    private(set) var captions: [LiveCaption] = []

    init(apiKey: String) {
        client = GeminiLiveClient(apiKey: apiKey)
        client.onEvent = { [weak self] event in self?.handle(event) }
    }

    func start(targetCode: String) {
        onStatus?(.connecting)
        client.start(targetCode: targetCode)
    }

    /// Feed 16 kHz mono float samples (called from the capture thread).
    func feed(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: samples)
            while self.pending.count >= Self.chunkFrames {
                let chunk = Array(self.pending.prefix(Self.chunkFrames))
                self.pending.removeFirst(Self.chunkFrames)
                self.client.sendAudio(base64: Self.encode(chunk))
            }
        }
    }

    /// Original-language lines recognized so far (finalized + in-progress).
    /// Read on the main queue (same as caption updates).
    func originalLines() -> [String] {
        var lines = captions.map(\.original).filter { !$0.isEmpty }
        let partial = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { lines.append(partial) }
        return lines
    }

    /// Translated lines so far (finalized + in-progress).
    func translatedLines() -> [String] {
        var lines = captions.map(\.translated).filter { !$0.isEmpty }
        let partial = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty { lines.append(partial) }
        return lines
    }

    func finish() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.pending.isEmpty {
                self.client.sendAudio(base64: Self.encode(self.pending))
                self.pending.removeAll()
            }
            self.client.close()
        }
    }

    // MARK: – Event handling (main queue)

    private func handle(_ event: LiveEvent) {
        switch event {
        case .ready:
            onStatus?(.live)
        case .input(let text):
            currentOriginal += text
            publishInProgress()
        case .output(let text):
            currentTranslated += text
            publishInProgress()
        case .turnComplete:
            let original = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            let translated = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
            currentOriginal = ""
            currentTranslated = ""
            // Subtitles show the original spoken text, so finalize a line as soon
            // as the source transcription is non-empty (translation is ignored).
            guard !original.isEmpty else { publishInProgress(); return }
            captions.append(LiveCaption(original: original, translated: translated))
            onUpdate?(captions, "")
        case .closed(let error):
            onStatus?(.closed(error))
        }
    }

    private func publishInProgress() {
        // The in-progress line is the original source transcription (the subtitle).
        onUpdate?(captions, currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: – Float32 → little-endian Int16 PCM → base64

    private static func encode(_ samples: [Float]) -> String {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data.base64EncodedString()
    }
}
