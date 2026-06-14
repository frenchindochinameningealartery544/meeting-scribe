import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import Accelerate

/// Captures system audio from the main display using ScreenCaptureKit.
/// Delivers resampled 16 kHz mono f32 samples to the consumer.
///
/// Config mirrors the one used by `silverstein/minutes` (known-working on
/// macOS 14+/15): `SCRecordingOutput`-friendly video stub + `.audio` output
/// only — no `.screen` or `.microphone` output types.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias SampleConsumer = ([Float]) async -> Void
    typealias LevelConsumer = (Float) -> Void

    var onSamples: SampleConsumer?
    var onLevel: LevelConsumer?

    private var stream: SCStream?
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let outputQueue = DispatchQueue(label: "sc.audio.out", qos: .userInteractive)
    private var didLogFirstCallback = false
    private var sampleCount = 0

    // MARK: Broken-tap recovery
    // ScreenCaptureKit's audio tap silently breaks after a mid-stream audio
    // route change (e.g. a conferencing app grabbing the output device when a
    // call starts): buffers keep arriving but become EXACT zeros forever, so we
    // get a full-length but empty `.system.wav`. Genuine captured silence is
    // never exact-zero (there's always a noise floor), so a run of exact-zero
    // buffers *after* real audio was seen is a reliable "tap died" signal.
    // Recreating the SCStream restores capture. All these are touched only on
    // `outputQueue` (the SCStream sample-handler queue + the CoreAudio listener
    // queue), so no extra locking is needed.
    private var hasSeenAudio = false
    private var consecutiveZeroFrames = 0
    /// Restart once the dead-silence run exceeds ~8 s of frames at 16 kHz.
    private let zeroRestartThreshold = 16_000 * 8
    private var isRestarting = false
    private var restartCount = 0
    private let maxRestarts = 8
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var lastPreferredBundleID = ""

    func start(preferredBundleID: String) async throws {
        restartCount = 0
        hasSeenAudio = false
        consecutiveZeroFrames = 0
        isRestarting = false
        lastPreferredBundleID = preferredBundleID
        try await startStream(preferredBundleID: preferredBundleID)
        installDefaultOutputListener()
    }

    private func startStream(preferredBundleID _: String) async throws {
        NSLog("SystemAudio: requesting SCShareableContent")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        NSLog("SystemAudio: \(content.applications.count) apps, \(content.displays.count) displays")

        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display."])
        }

        // Match minutes' filter exactly: empty excludes + empty exceptingWindows.
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        NSLog("SystemAudio: stream started")
        self.stream = stream
        self.didLogFirstCallback = false
        self.sampleCount = 0
    }

    func stop() async {
        removeDefaultOutputListener()
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            NSLog("SystemAudio: stopCapture failed: \(error)")
        }
        self.stream = nil
        self.converter = nil
        self.lastInputFormat = nil
    }

    // MARK: Broken-tap recovery

    /// Tear down and rebuild the SCStream in place. Consumers (`onSamples`,
    /// `onLevel`) are untouched, so capture resumes transparently — at the cost
    /// of a short gap in the `.system.wav` while the new stream warms up.
    private func restartStream() async {
        let bundleID = lastPreferredBundleID
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        converter = nil
        lastInputFormat = nil
        do {
            try await startStream(preferredBundleID: bundleID)
            NSLog("SystemAudio: stream restarted (#\(restartCount))")
        } catch {
            NSLog("SystemAudio: restart failed: \(error)")
        }
        outputQueue.async { [weak self] in
            self?.consecutiveZeroFrames = 0
            self?.isRestarting = false
        }
    }

    /// Schedule a restart, debounced and capped. Must be called on `outputQueue`.
    private func scheduleRestart(reason: String) {
        guard !isRestarting, restartCount < maxRestarts else { return }
        isRestarting = true
        restartCount += 1
        consecutiveZeroFrames = 0
        NSLog("SystemAudio: restarting stream (#\(restartCount)) — \(reason)")
        Task { [weak self] in await self?.restartStream() }
    }

    /// Restart the capture whenever the system's default output device changes —
    /// the most common trigger for the audio tap dying mid-call.
    private func installDefaultOutputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(reason: "default output device changed")
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, outputQueue, block)
    }

    private func removeDefaultOutputListener() {
        guard let block = deviceListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, outputQueue, block)
        deviceListenerBlock = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if !didLogFirstCallback {
            didLogFirstCallback = true
            NSLog("SystemAudio: first stream callback (type=\(type.rawValue))")
        }
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee

        let inputFormat = AVAudioFormat(streamDescription: asbdPtr)
            ?? AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                             channels: AVAudioChannelCount(asbd.mChannelsPerFrame))
        guard let inputFormat else { return }

        if converter == nil || lastInputFormat != inputFormat {
            let conv = AVAudioConverter(from: inputFormat, to: targetFormat)
            // High-quality anti-aliased resampling at the 48k→16k boundary.
            // Default quality trades noticeable aliasing for speed; Whisper WER
            // is very sensitive to that aliasing.
            conv?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            conv?.sampleRateConverterQuality = .max
            converter = conv
            lastInputFormat = inputFormat
            NSLog("SystemAudio: converter input format = \(inputFormat) (mastering/.max)")
        }
        guard let converter else { return }

        guard let inputPCM = Self.makePCMBuffer(from: sampleBuffer, format: inputFormat) else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inputPCM.frameLength) * ratio + 32)
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outputPCM, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inputPCM
        }
        guard status != .error, let ch = outputPCM.floatChannelData?[0] else { return }
        let count = Int(outputPCM.frameLength)
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(ch, 1, &rms, vDSP_Length(count))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }

        // Broken-tap watchdog: once we've seen real audio, a sustained run of
        // EXACT-zero buffers means the SCStream's audio tap has died (a genuine
        // signal always carries a non-zero noise floor). Recreate the stream.
        if rms == 0 {
            if hasSeenAudio {
                consecutiveZeroFrames += count
                if consecutiveZeroFrames >= zeroRestartThreshold {
                    scheduleRestart(reason: "system audio went exact-zero (tap died)")
                }
            }
        } else {
            hasSeenAudio = true
            consecutiveZeroFrames = 0
            restartCount = 0 // healthy again — re-arm the restart budget
        }

        let samples = Array(UnsafeBufferPointer(start: ch, count: count))
        sampleCount += count
        if sampleCount == count || sampleCount % (16_000 * 5) < count {
            NSLog("SystemAudio: received batch (\(count) samples, \(sampleCount) total)")
        }
        Task { [weak self] in await self?.onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudio: stopped with error \(error)")
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                                      format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(sampleCount)

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }

        let channelCount = Int(format.channelCount)
        let asbd = format.streamDescription.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = isFloat ? 4 : 2

        if format.isInterleaved {
            // Copy interleaved bytes straight into the PCM buffer.
            if let dst = pcm.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, data, totalLength)
            }
        } else if isNonInterleaved {
            // Non-interleaved: CM block is [ch0 frames | ch1 frames | ...].
            let planeSize = sampleCount * bytesPerSample
            let channelsData = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for ch in 0..<channelCount where ch < channelsData.count {
                let srcOff = ch * planeSize
                if srcOff + planeSize <= totalLength,
                   let dst = channelsData[ch].mData {
                    memcpy(dst, data.advanced(by: srcOff), planeSize)
                }
            }
        } else {
            // Fallback: single-channel contiguous buffer.
            if let dst = pcm.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, data, min(totalLength, Int(pcm.audioBufferList.pointee.mBuffers.mDataByteSize)))
            }
        }
        return pcm
    }
}
