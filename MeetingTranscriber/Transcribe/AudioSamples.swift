import Foundation
import AVFoundation

/// Loads a recording as 16 kHz mono `Float` samples, with recovery for files
/// whose WAV header was never finalized — e.g. the app was force-quit or
/// crashed mid-recording, leaving the RIFF/`data` chunk sizes at 0.
/// `AVAudioFile` trusts the header and reports length 0 for those, silently
/// dropping all audio; we then fall back to reading the raw PCM payload
/// directly so the recording isn't lost.
enum AudioSamples {

    static func load16kMono(from url: URL) throws -> [Float] {
        if let viaAVF = try? loadViaAVAudioFile(url), !viaAVF.isEmpty {
            return viaAVF
        }
        // Header says empty (or AVFoundation refused the file) but the bytes may
        // still be on disk — recover by walking the WAV chunks ourselves.
        return (try? loadByParsingWav(url)) ?? []
    }

    // MARK: - Normal path (header is valid)

    private static func loadViaAVAudioFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buf)
        return monoFloats(from: buf)
    }

    private static func monoFloats(from buf: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return [] }
        let channelCount = Int(buf.format.channelCount)

        if let channels = buf.floatChannelData {
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channelCount {
                let ch = channels[c]
                for i in 0..<frames { mono[i] += ch[i] }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
            return mono
        }

        // Interleaved fallback (floatChannelData is nil on some variants).
        let abl = buf.audioBufferList.pointee
        guard let data = abl.mBuffers.mData else { return [] }
        let floatCount = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let src = data.bindMemory(to: Float.self, capacity: floatCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: src, count: min(floatCount, frames)))
        }
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount { sum += src[i * channelCount + c] }
            mono[i] = sum / Float(channelCount)
        }
        return mono
    }

    // MARK: - Recovery path (unfinalized / corrupt header)

    /// Minimal WAV chunk walker. Handles the exact format `StemWriter` produces
    /// (PCM Int16, 16 kHz, mono) plus Float32/Int32, and treats a 0-length or
    /// over-long `data` chunk as "everything to end of file".
    private static func loadByParsingWav(_ url: URL) throws -> [Float] {
        // Read the whole file into heap RAM — NOT memory-mapped. A truncated or
        // partially-written WAV (the app was force-quit mid-record) can have a
        // header/length that outruns the bytes actually backed on disk; paging
        // such a region in via `.mappedIfSafe` faults with SIGBUS even for an
        // in-bounds `Data` subscript. Copying into RAM makes every access safe.
        let d = try Data(contentsOf: url)
        guard d.count > 44,
              d[0] == 0x52, d[1] == 0x49, d[2] == 0x46, d[3] == 0x46,   // "RIFF"
              d[8] == 0x57, d[9] == 0x41, d[10] == 0x56, d[11] == 0x45  // "WAVE"
        else { return [] }

        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int {
            Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24
        }

        var offset = 12
        var channels = 1, bits = 16, isFloat = false
        var dataRange: Range<Int>?

        while offset + 8 <= d.count {
            let id = String(bytes: d[offset..<offset + 4], encoding: .ascii) ?? ""
            var size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " && body + 16 <= d.count {
                let audioFormat = u16(body)                  // 1 = PCM, 3 = IEEE float
                channels = max(1, u16(body + 2))
                bits = u16(body + 14)
                isFloat = (audioFormat == 3) || (audioFormat == 0xFFFE && bits == 32)
            } else if id == "data" {
                if size <= 0 || body + size > d.count { size = d.count - body }
                dataRange = body..<(body + size)
                break
            }
            if size <= 0 { break }
            offset = body + size + (size & 1)                // chunks are word-aligned
        }

        guard let range = dataRange, !range.isEmpty else { return [] }
        return decodePCM(d.subdata(in: range), channels: channels, bits: bits, isFloat: isFloat)
    }

    private static func decodePCM(_ payload: Data, channels: Int, bits: Int, isFloat: Bool) -> [Float] {
        let ch = max(1, channels)
        return payload.withUnsafeBytes { raw -> [Float] in
            if isFloat, bits == 32 {
                let p = raw.bindMemory(to: Float32.self)
                return downmix(count: p.count, channels: ch) { Float(p[$0]) }
            }
            if bits == 16 {
                let p = raw.bindMemory(to: Int16.self)
                return downmix(count: p.count, channels: ch) { Float(p[$0]) / 32768.0 }
            }
            if bits == 32 {                                  // Int32 PCM
                let p = raw.bindMemory(to: Int32.self)
                return downmix(count: p.count, channels: ch) { Float(p[$0]) / 2_147_483_648.0 }
            }
            return []
        }
    }

    private static func downmix(count: Int, channels: Int, sample: (Int) -> Float) -> [Float] {
        if channels == 1 {
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count { out[i] = sample(i) }
            return out
        }
        let frames = count / channels
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<channels { s += sample(f * channels + c) }
            out[f] = s / Float(channels)
        }
        return out
    }
}
