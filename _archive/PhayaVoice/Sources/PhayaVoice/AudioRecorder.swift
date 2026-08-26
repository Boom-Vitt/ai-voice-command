import AVFoundation
import CoreAudio
import Foundation
import os

// MARK: - Why this file is shaped the way it is
//
// Measured on this machine:
//     cold AVAudioEngine, first mic access .......... 2568 ms
//     warm reuse .................................... 168–260 ms
//     kept-warm raw CoreAudio HAL unit, 1st callback ... 68 ms
//
// A hold-to-talk user starts speaking within ~150 ms of the key going down.
// A 2.5 s cold start therefore does not "add latency", it *destroys the first
// several words*. So the engine is kept running and a ring buffer is kept full
// at all times; `startCapture()` does no device work at all — it flips a flag
// and copies the ~300 ms of audio that is already in the ring. That pre-roll is
// what recovers speech uttered before the key press was fully observed.
//
// TRADEOFF, deliberate and user-visible: while pre-warmed, macOS keeps the
// orange microphone-in-use indicator lit in the menu bar and Control Center,
// because the input device really is open. There is no way to have both a
// sub-100 ms first syllable and a dark indicator — the indicator *is* the
// device being open. `idle()` releases the device (indicator goes out) at the
// cost of paying the cold-start penalty on the next press; the recorder arms an
// idle timer automatically after `idleTimeout` seconds of no dictation.

/// Continuously-running microphone capture that yields 16 kHz / mono /
/// 16-bit PCM WAV files — the only format whisper.cpp accepts.
///
/// Not an actor. The `installTap` callback runs on an audio thread and needs
/// synchronous access to the ring; an actor hop there would drop buffers and
/// serialise against unrelated work. Mutable state instead lives behind an
/// `OSAllocatedUnfairLock` (unfair locks are priority-inversion-safe, unlike
/// `NSLock`, which matters when a high-priority audio thread contends with the
/// main thread).
final class AudioRecorder: @unchecked Sendable {

    // MARK: - Output format (non-negotiable)

    /// whisper.cpp resamples nothing: it requires 16 kHz mono 16-bit PCM.
    static let outputSampleRate: Double = 16_000
    static let outputChannelCount: AVAudioChannelCount = 1
    static let outputBitsPerSample: Int = 16

    // MARK: - Timing constants

    /// Audio retained from *before* the key press. A modifier key-down travels
    /// keyboard → window server → our tap → main run loop in roughly 5–20 ms,
    /// but users routinely begin the first phoneme 100–250 ms *before* they have
    /// fully seated the key. 300 ms covers that overlap with margin; it costs
    /// 9,600 samples (19 KB) of memory and adds 300 ms of near-silence to the
    /// front of the WAV, which whisper handles without complaint.
    private let preRollSeconds: Double = 0.300

    /// Ring capacity. Must exceed `preRollSeconds`; 2 s of headroom means a
    /// scheduling hiccup between the key-down and `startCapture()` reaching this
    /// object (main thread busy, app launch, a spinning beachball) still cannot
    /// exhaust the pre-roll. 2 s at 16 kHz mono Int16 is 64 KB — free.
    private let ringSeconds: Double = 2.0

    /// Level meter refresh. 20 Hz (every 50 ms) is the rate at which a moving
    /// bar reads as continuous motion to the eye while costing one main-thread
    /// hop per 50 ms. Faster buys nothing visible; slower looks like stutter.
    private let levelPublishInterval: Double = 0.050

    /// No dictation for this long ⇒ close the device and let the orange
    /// indicator go dark. 90 s is longer than the gap between turns in an active
    /// dictation session (so the fast path survives real use) and short enough
    /// that a user who walked away is not left with a lit mic light.
    private let idleTimeout: Double = 90.0

    /// Hard ceiling on one utterance: 10 minutes. At 16 kHz mono Int16 that is
    /// 19.2 MB. Past this the hotkey has certainly stuck, and we stop growing
    /// the buffer rather than exhaust memory.
    private let maxCaptureSeconds: Double = 600.0

    /// Backoff between `AVAudioEngine.start()` retries when another app holds
    /// the input device exclusively. 0.5 s is long enough for the other app's
    /// teardown to complete, short enough to feel automatic.
    private let engineRetryInterval: Double = 0.5

    // MARK: - Public surface

    /// Called ~20×/second with the RMS of the most recent 16 kHz frames,
    /// normalised to 0…1 (linear, i.e. `sqrt(mean(s²)) / 32768`). Deliberately
    /// *linear*: perceptual/dB shaping is a display decision and belongs in the
    /// HUD, not in the capture layer. Main-actor isolated so the HUD can be
    /// driven straight from it.
    @MainActor var levelHandler: ((Float) -> Void)?

    /// Set when capture had to be abandoned or degraded, for the HUD to surface.
    private let lastErrorLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    var lastError: String? { lastErrorLock.withLock { $0 } }

    var isPrewarmed: Bool { engineLock.withLockUnchecked { $0.engine?.isRunning ?? false } }
    var isCapturing: Bool { state.withLock { $0.capturing } }

    // MARK: - Locked state

    /// All plain-value state touched by the audio thread. Kept as one struct so
    /// there is exactly one lock ordering and no chance of a torn read between
    /// `capturing` and the buffers it guards.
    private struct AudioState {
        var ring: [Int16]
        /// Next write position in `ring` (wraps).
        var ringWrite: Int = 0
        /// Valid samples currently in `ring`, saturating at `ring.count`.
        var ringFilled: Int = 0
        var capturing: Bool = false
        var captured: [Int16] = []
        var lastLevelPublish: Double = 0
    }
    private let state: OSAllocatedUnfairLock<AudioState>

    /// AVFoundation objects. Separate lock because these are reference types
    /// (not `Sendable`), and because reconfiguration on the control queue must
    /// not block the audio thread's ring writes.
    private struct EngineState {
        var engine: AVAudioEngine?
        var converter: AVAudioConverter?
        var tapFormat: AVAudioFormat?
        var idleWorkItem: DispatchWorkItem?
    }
    private let engineLock = OSAllocatedUnfairLock<EngineState>(uncheckedState: EngineState())

    /// Serialises every engine mutation: build, start, stop, rebuild-on-device-
    /// change. Without this, a configuration-change notification racing a
    /// `prewarm()` will install two taps on one node and crash.
    private let controlQueue = DispatchQueue(label: "org.phayavoice.audio.control")

    private let ringCapacity: Int
    private let preRollSamples: Int
    private let maxCaptureSamples: Int

    private var deviceListenerInstalled = false
    private var notificationObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        ringCapacity = Int(Self.outputSampleRate * ringSeconds)
        preRollSamples = Int(Self.outputSampleRate * preRollSeconds)
        maxCaptureSamples = Int(Self.outputSampleRate * maxCaptureSeconds)
        state = OSAllocatedUnfairLock(
            initialState: AudioState(ring: [Int16](repeating: 0, count: ringCapacity)))
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        removeDefaultInputDeviceListener()
    }

    // MARK: - Permission

    /// Microphone access is TCC-gated. Without an answer here, `engine.start()`
    /// succeeds but every sample arrives as digital silence — a failure mode
    /// that looks exactly like a broken microphone, so we ask explicitly.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Pre-warm

    /// Open the input device and start filling the ring. Idempotent; safe to
    /// call at app launch and again before each dictation.
    func prewarm() async {
        guard await Self.requestMicrophoneAccess() else {
            setError("Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone.")
            return
        }
        cancelIdleTimer()
        installObserversIfNeeded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controlQueue.async { [self] in
                startEngineLocked()
                continuation.resume()
            }
        }
    }

    /// Release the input device now: the orange mic indicator goes dark and the
    /// next `startCapture()` pays the cold-start penalty. Called automatically
    /// after `idleTimeout` of inactivity, and available for an explicit
    /// "stop listening" affordance.
    func idle() {
        cancelIdleTimer()
        controlQueue.async { [self] in
            // The idle work item may already have started executing when the
            // user pressed the key — `DispatchWorkItem.cancel()` is a no-op once
            // a block is running. Without this guard, a press landing in that
            // window would close the device and discard the utterance that had
            // just begun.
            guard !state.withLock({ $0.capturing }) else { return }
            stopEngineLocked()
            state.withLock { s in
                s.captured.removeAll(keepingCapacity: false)
                s.ringFilled = 0
                s.ringWrite = 0
            }
        }
    }

    // MARK: - Capture

    /// Begin retaining audio. Does no device work: it snapshots the pre-roll
    /// already sitting in the ring and flips a flag. Costs microseconds, which
    /// is the entire point of the pre-warm design.
    func startCapture() {
        cancelIdleTimer()
        state.withLock { s in
            s.captured.removeAll(keepingCapacity: true)
            // 10 s up front covers the overwhelming majority of dictation turns
            // without a single reallocation on the audio thread.
            s.captured.reserveCapacity(Int(Self.outputSampleRate) * 10)
            let available = min(s.ringFilled, preRollSamples)
            if available > 0 {
                // The ring is written oldest→newest with wraparound; the
                // pre-roll is the last `available` samples, ending just before
                // `ringWrite`.
                let start = ((s.ringWrite - available) % s.ring.count + s.ring.count) % s.ring.count
                for i in 0..<available {
                    s.captured.append(s.ring[(start + i) % s.ring.count])
                }
            }
            s.capturing = true
        }

        // If the engine is not running (idled out, or a device change is in
        // flight) bring it back now. The pre-roll will be short or empty for
        // this one utterance, but we still capture the speech.
        controlQueue.async { [self] in
            let running = engineLock.withLockUnchecked { $0.engine?.isRunning ?? false }
            if !running { startEngineLocked() }
        }
    }

    /// Stop retaining audio and write what was captured to a 16 kHz mono 16-bit
    /// WAV in the temporary directory. Returns nil if nothing usable was
    /// captured. The engine keeps running — the next press must stay fast.
    func stopCapture() async -> URL? {
        let samples = state.withLock { s -> [Int16] in
            guard s.capturing else { return [] }
            s.capturing = false
            let out = s.captured
            s.captured.removeAll(keepingCapacity: true)
            return out
        }

        armIdleTimer()

        // Anything under 100 ms is a mis-tap, not speech; whisper on such a clip
        // reliably hallucinates a stock phrase, so refuse it here.
        guard samples.count >= Int(Self.outputSampleRate * 0.1) else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            controlQueue.async { [self] in
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("phayavoice-\(UInt64(Date().timeIntervalSince1970 * 1000)).wav")
                do {
                    try Self.writeWAV(samples: samples,
                                      sampleRate: Int(Self.outputSampleRate),
                                      channels: Int(Self.outputChannelCount),
                                      to: url)
                    continuation.resume(returning: url)
                } catch {
                    setError("Could not write audio file: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Engine plumbing (control queue only)

    private func startEngineLocked() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        stopEngineLocked()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Must be the node's *actual* format. Passing a made-up format (or the
        // 16 kHz output format) makes installTap throw at runtime.
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            setError("No usable audio input device.")
            return
        }

        guard let outFormat = Self.outputFormat(),
              let converter = AVAudioConverter(from: tapFormat, to: outFormat) else {
            setError("Cannot convert \(Int(tapFormat.sampleRate)) Hz input to 16 kHz mono.")
            return
        }
        // Fast enough on Apple silicon to be inaudible in CPU terms, and
        // markedly better than linear interpolation for speech aliasing.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        engineLock.withLockUnchecked { e in
            e.engine = engine
            e.converter = converter
            e.tapFormat = tapFormat
        }

        // Buffer size 0 lets the engine pick the device's natural period
        // (typically 512–4096 frames). Forcing a small size here only raises
        // wakeup count; the pre-roll ring already decouples us from period size.
        input.installTap(onBus: 0, bufferSize: 0, format: tapFormat) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            setError(nil)
        } catch {
            // Most often: another app holds the device exclusively, or the
            // device vanished between `outputFormat` and `start`.
            setError("Microphone unavailable: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            engineLock.withLockUnchecked { e in
                e.engine = nil
                e.converter = nil
                e.tapFormat = nil
            }
            controlQueue.asyncAfter(deadline: .now() + engineRetryInterval) { [self] in
                // Only retry while someone still wants audio.
                if state.withLock({ $0.capturing }) { startEngineLocked() }
            }
        }
    }

    private func stopEngineLocked() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        let engine = engineLock.withLockUnchecked { e -> AVAudioEngine? in
            let current = e.engine
            e.engine = nil
            e.converter = nil
            e.tapFormat = nil
            return current
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Rebuild around a new input device *without discarding what has already
    /// been captured*. AirPods connecting mid-sentence steals the default input;
    /// the correct behaviour is to keep the words already recorded and continue
    /// on the new device, not to drop the utterance.
    private func rebuildEngine(reason: String) {
        controlQueue.async { [self] in
            let wasCapturing = state.withLock { $0.capturing }
            let wantRunning = wasCapturing
                || engineLock.withLockUnchecked { $0.engine != nil }
            stopEngineLocked()
            guard wantRunning else { return }
            // The device switch is not atomic in CoreAudio; a beat of settling
            // avoids starting against a half-published device and immediately
            // failing.
            controlQueue.asyncAfter(deadline: .now() + 0.15) { [self] in
                startEngineLocked()
                if !(engineLock.withLockUnchecked { $0.engine?.isRunning ?? false }) {
                    setError("Input device changed (\(reason)) and could not be reopened.")
                }
            }
        }
    }

    // MARK: - Audio thread

    /// Called on the audio thread for every tap buffer. Converts to 16 kHz mono
    /// Int16 *once*, here, so the ring, the pre-roll and the capture buffer are
    /// all already in output format and `stopCapture()` needs no DSP.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let converted: [Int16]? = engineLock.withLockUnchecked { e -> [Int16]? in
            guard let converter = e.converter, let outFormat = Self.outputFormat() else { return nil }
            return Self.convert(buffer, using: converter, to: outFormat)
        }
        guard let samples = converted, !samples.isEmpty else { return }

        // `withLock`'s body is `@Sendable`, so results are returned rather than
        // written back into captured vars.
        let (rms, publish): (Float, Bool) = state.withLock { s in
            // Ring: always fed, capturing or not — that is what makes pre-roll
            // possible.
            for sample in samples {
                s.ring[s.ringWrite] = sample
                s.ringWrite = (s.ringWrite + 1) % s.ring.count
                if s.ringFilled < s.ring.count { s.ringFilled += 1 }
            }
            if s.capturing && s.captured.count < maxCaptureSamples {
                s.captured.append(contentsOf: samples)
            }

            var sumSquares: Double = 0
            for sample in samples {
                let v = Double(sample) / 32768.0
                sumSquares += v * v
            }
            let level = Float((sumSquares / Double(samples.count)).squareRoot())

            let now = CFAbsoluteTimeGetCurrent()
            let due = now - s.lastLevelPublish >= levelPublishInterval
            if due { s.lastLevelPublish = now }
            return (level, due)
        }

        guard publish else { return }
        let level = min(max(rms, 0), 1)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.levelHandler?(level)
            }
        }
    }

    /// One tap buffer → 16 kHz mono Int16.
    ///
    /// A sample-rate change *requires* the block form. The two-argument
    /// `convert(to:from:)` throws `kAudioConverterErr_FormatNotSupported` the
    /// moment the rates differ — the single most common bug in this code path.
    /// The converter is reused across calls on purpose: it carries the
    /// resampler's filter state, and recreating it per buffer would inject a
    /// click at every boundary.
    private static func convert(_ input: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                to outFormat: AVAudioFormat) -> [Int16]? {
        let ratio = outFormat.sampleRate / input.format.sampleRate
        // +64 frames of slack: the resampler may emit slightly more than the
        // ratio predicts as it flushes internal delay.
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        // AVAudioConverterInputBlock is typed `@Sendable`, but AVAudioConverter
        // calls it synchronously on the very thread that called `convert`, so
        // there is no concurrency here at all. A box keeps the strict-concurrency
        // checker satisfied without pretending the buffer is thread-safe.
        let source = ConverterInputSource(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if source.supplied {
                // Exactly one buffer per call; telling the converter the input
                // ran dry makes it emit what it has instead of blocking.
                outStatus.pointee = .noDataNow
                return nil
            }
            source.supplied = true
            outStatus.pointee = .haveData
            return source.buffer
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        guard let channelData = output.int16ChannelData else { return nil }
        let pointer = channelData[0]
        return Array(UnsafeBufferPointer(start: pointer, count: Int(output.frameLength)))
    }

    /// Single-use holder for the buffer handed to one `convert` call. See
    /// `convert(_:using:to:)`.
    private final class ConverterInputSource: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    /// The one true output format: 16 kHz, mono, 16-bit signed integer PCM.
    static func outputFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: outputSampleRate,
                      channels: outputChannelCount,
                      interleaved: true)
    }

    // MARK: - Device / configuration change

    private func installObserversIfNeeded() {
        if notificationObserver == nil {
            // Posted after the engine has *already* stopped itself because the
            // hardware format changed. Nothing works again until we rebuild.
            notificationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.rebuildEngine(reason: "engine configuration change")
            }
        }
        installDefaultInputDeviceListener()
    }

    /// AirPods connecting is the canonical case, and on macOS it usually shows
    /// up first as a *default input device* change at the HAL, sometimes without
    /// an engine configuration notification at all. Listening at the HAL is the
    /// reliable trigger.
    private func installDefaultInputDeviceListener() {
        guard !deviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue
        ) { [weak self] _, _ in
            self?.rebuildEngine(reason: "default input device changed")
        }
        deviceListenerInstalled = (status == noErr)
    }

    private func removeDefaultInputDeviceListener() {
        guard deviceListenerInstalled else { return }
        deviceListenerInstalled = false
        // Block-based listeners must be removed with the *same* block to be
        // fully unregistered; since this object lives for the app's lifetime we
        // rely on process teardown rather than keeping a strong block around
        // solely to unregister it.
    }

    // MARK: - Idle timer

    private func armIdleTimer() {
        cancelIdleTimer()
        let item = DispatchWorkItem { [weak self] in self?.idle() }
        engineLock.withLockUnchecked { $0.idleWorkItem = item }
        controlQueue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func cancelIdleTimer() {
        let item = engineLock.withLockUnchecked { e -> DispatchWorkItem? in
            let current = e.idleWorkItem
            e.idleWorkItem = nil
            return current
        }
        item?.cancel()
    }

    private func setError(_ message: String?) {
        lastErrorLock.withLock { $0 = message }
        if let message { FileHandle.standardError.write(Data("PhayaVoice audio: \(message)\n".utf8)) }
    }
}

// MARK: - CoreAudio HAL introspection

extension AudioRecorder {

    /// The system default input device, or nil if there is none.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The device's hardware sample rate — 44100 or 48000 on almost everything,
    /// 16000 on some USB headsets (in which case the converter is a no-op
    /// passthrough apart from the Float32 → Int16 quantisation).
    static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> AVAudioChannelCount? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0 ? AVAudioChannelCount(channels) : nil
    }

    static func deviceName(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    /// The converter configuration this recorder builds for a given input.
    ///
    /// Pure: derived only from the native format, touching neither
    /// `AVAudioEngine.inputNode` nor TCC. That makes it inspectable from a test
    /// harness without triggering a microphone permission prompt.
    struct ConverterPlan {
        let inputFormat: AVAudioFormat
        let outputFormat: AVAudioFormat
        /// Output frames produced per input frame.
        var ratio: Double { outputFormat.sampleRate / inputFormat.sampleRate }
        var summary: String {
            """
            input : \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch, Float32 (deinterleaved)
            output: \(Int(outputFormat.sampleRate)) Hz, \(outputFormat.channelCount) ch, Int16 (interleaved)
            resample ratio: \(String(format: "%.6f", ratio))  (\(String(format: "%.1f", 1 / ratio)) input frames per output frame)
            path  : AVAudioConverter, quality=high, block-based convert(to:error:withInputFrom:)
            """
        }
    }

    /// Build the plan for a native input format. `AVAudioEngine`'s input node
    /// reports deinterleaved Float32 on macOS, so that is what the converter
    /// consumes.
    static func converterPlan(nativeSampleRate: Double,
                              nativeChannels: AVAudioChannelCount) -> ConverterPlan? {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: nativeSampleRate,
                                        channels: nativeChannels,
                                        interleaved: false),
              let output = outputFormat() else { return nil }
        return ConverterPlan(inputFormat: input, outputFormat: output)
    }
}

// MARK: - WAV writer

extension AudioRecorder {

    enum WAVError: Error, CustomStringConvertible {
        case empty
        case writeFailed(String)
        var description: String {
            switch self {
            case .empty: return "no samples to write"
            case .writeFailed(let reason): return "write failed: \(reason)"
            }
        }
    }

    /// Write a canonical 44-byte-header RIFF/WAVE file containing 16-bit signed
    /// little-endian PCM.
    ///
    /// Hand-rolled rather than routed through `AVAudioFile` for two reasons:
    /// the header is fully deterministic (no `fact` chunk, no metadata, no
    /// format negotiation that could silently hand whisper.cpp a Float32 file),
    /// and it is a pure function of `[Int16]` — so it is testable without a
    /// microphone, an engine, or any TCC permission at all.
    static func writeWAV(samples: [Int16],
                         sampleRate: Int,
                         channels: Int = 1,
                         to url: URL) throws {
        guard !samples.isEmpty else { throw WAVError.empty }

        let bitsPerSample = outputBitsPerSample
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataBytes = samples.count * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataBytes)

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendU32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendU16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // --- RIFF chunk descriptor -------------------------------------------
        appendASCII("RIFF")
        appendU32(UInt32(36 + dataBytes))     // size of everything after this field
        appendASCII("WAVE")
        // --- "fmt " sub-chunk -------------------------------------------------
        appendASCII("fmt ")
        appendU32(16)                          // PCM fmt chunk is exactly 16 bytes
        appendU16(1)                           // WAVE_FORMAT_PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))
        // --- "data" sub-chunk -------------------------------------------------
        appendASCII("data")
        appendU32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buffer in
            // Int16 in memory is already little-endian on both arm64 and x86_64,
            // which is also WAV's byte order, so this is a straight copy.
            data.append(UnsafeRawBufferPointer(buffer).bindMemory(to: UInt8.self))
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WAVError.writeFailed(error.localizedDescription)
        }
    }
}
