import AppKit
import Accelerate
import Combine
import CoreAudio
import Foundation
import os

/// Live per-band audio levels for the Now Playing waveform.
///
/// Captures the system output mix with a Core Audio process tap (macOS 14.2+) only while it is
/// actually needed: the setting is on, music is playing and at least one waveform is on screen.
/// Everything is torn down ~2 s after any of those stops being true, so there is no CPU use and no
/// recording indicator while idle. If the tap can't be created (old macOS, permission denied) or
/// delivers only silence, `isLive` stays false and the views keep their synthetic animation.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()

    /// Number of frequency bands published (low → high). Views resample to their own bar count.
    nonisolated static let bandCount = 8

    /// Process taps exist from macOS 14.2.
    nonisolated static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// 0…1 per band, smoothed and normalised. All zeros while not live.
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: AudioLevels.bandCount)
    /// True while real audio is being analysed (tap running and non-silent).
    @Published private(set) var isLive = false

    private var settingOn = true
    private var playing = false
    private var visibleWaveforms = 0
    /// Set when starting failed; cleared on the next play or setting change so we don't retry in a loop.
    private var failed = false

    private var engine: AnyObject?          // AudioTapEngine on macOS 14.2+
    private var pollTimer: DispatchSourceTimer?
    private var stopWork: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var cancellables = Set<AnyCancellable>()
    private let controlQueue = DispatchQueue(label: "notch.audiolevels.control", qos: .userInitiated)
    private var scratch = [Float](repeating: 0, count: AudioLevels.bandCount)

    private init() {
        AppSettings.shared.$config
            .map(\.waveformReactsToAudio)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.settingOn = on
                    self.failed = false
                    self.reevaluate()
                }
            }
            .store(in: &cancellables)

        MediaController.shared.$info
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isPlaying && !self.playing { self.failed = false }
                    self.playing = isPlaying
                    self.reevaluate()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdownForQuit() }
        }
    }

    // MARK: Waveform visibility (called by WaveformBars)

    func waveformAppeared() {
        visibleWaveforms += 1
        reevaluate()
    }

    func waveformDisappeared() {
        visibleWaveforms = max(0, visibleWaveforms - 1)
        reevaluate()
    }

    // MARK: State machine

    private var wanted: Bool {
        Self.isSupported && settingOn && playing && visibleWaveforms > 0 && !failed
    }

    private func reevaluate() {
        if wanted {
            stopWork?.cancel()
            stopWork = nil
            if engine == nil { start() }
        } else if engine != nil, stopWork == nil {
            // Linger briefly so a quick pause/resume or page change doesn't rebuild the tap.
            let delay: Double = (!settingOn || failed) ? 0 : 2
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopWork = nil
                    if !self.wanted { self.stop() }
                }
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func start() {
        guard #available(macOS 14.2, *) else { return }
        let e = AudioTapEngine()
        engine = e
        // Creating the tap can block on the System Audio Recording prompt: keep it off main.
        controlQueue.async { [weak self] in
            let ok = e.start()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.engine === e else { return }   // stopped meanwhile
                    if ok {
                        self.startPolling(e)
                        self.listenForOutputChanges()
                    } else {
                        self.failed = true
                        self.stop()
                    }
                }
            }
        }
    }

    private func stop() {
        stopWork?.cancel()
        stopWork = nil
        pollTimer?.cancel()
        pollTimer = nil
        removeOutputListener()
        if isLive { isLive = false }
        if bands.contains(where: { $0 != 0 }) {
            bands = Array(repeating: 0, count: Self.bandCount)
        }
        guard let e = engine else { return }
        engine = nil
        if #available(macOS 14.2, *), let tap = e as? AudioTapEngine {
            controlQueue.async { tap.stop() }
        }
    }

    private func shutdownForQuit() {
        guard engine != nil else { return }
        stop()
        // Wait (briefly) for the teardown queued by stop() so the private device and tap are gone.
        let done = DispatchSemaphore(value: 0)
        controlQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: Publishing (≤30 Hz, main thread only reads a snapshot)

    @available(macOS 14.2, *)
    private func startPolling(_ e: AudioTapEngine) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll(e) }
        }
        pollTimer = timer
        timer.resume()
    }

    @available(macOS 14.2, *)
    private func poll(_ e: AudioTapEngine) {
        guard engine === e else { return }
        let silentFor = scratch.withUnsafeMutableBufferPointer { e.analyzer.read(into: $0) }
        // Live once we've heard real (non-zero) samples; drop back to the synthetic animation after
        // a stretch of digital silence (permission denied delivers zeros, or audio we can't see).
        let live = silentFor < 1.5
        if live != isLive { isLive = live }
        if live {
            var changed = false
            for i in 0..<Self.bandCount where abs(scratch[i] - bands[i]) > 0.002 { changed = true; break }
            if changed { bands = scratch }
        } else if bands.contains(where: { $0 != 0 }) {
            bands = Array(repeating: 0, count: Self.bandCount)
        }
    }

    // MARK: Default output changes (AirPods connecting etc.) → rebuild the aggregate device

    private func listenForOutputChanges() {
        removeOutputListener()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.engine != nil else { return }
                self.stop()
                self.reevaluate()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr { deviceListener = block }
    }

    private func removeOutputListener() {
        guard let block = deviceListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        deviceListener = nil
    }
}

// MARK: - Core Audio process tap + aggregate device

@available(macOS 14.2, *)
private final class AudioTapEngine: @unchecked Sendable {
    let analyzer = BandAnalyzer()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let ioQueue = DispatchQueue(label: "notch.audiolevels.io", qos: .userInteractive)

    deinit { stop() }

    /// Builds tap → aggregate device → IOProc and starts it. Returns false (with everything torn
    /// down) on any failure. Call on the control queue.
    func start() -> Bool {
        guard !running else { return true }

        // 1. Global stereo tap of everything playing, minus our own process.
        var excluded: [AudioObjectID] = []
        if let me = Self.ownProcessObject() { excluded.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Notch waveform"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        let tapUID = desc.uuid.uuidString

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &newTap) == noErr, newTap != kAudioObjectUnknown else {
            stop(); return false
        }
        tapID = newTap

        // 2. Tap format (Float32 PCM expected).
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0 else {
            stop(); return false
        }
        analyzer.configure(sampleRate: format.mSampleRate)

        // 3. Private aggregate device holding the tap (clocked by the current output device).
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Waveform",
            kAudioAggregateDeviceUIDKey: "com.k2a.notch.waveform." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        if let outputUID = Self.defaultOutputUID() {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAggregate) == noErr,
              newAggregate != kAudioObjectUnknown else {
            stop(); return false
        }
        aggregateID = newAggregate

        // 4. IOProc on a dedicated serial queue. The block only touches preallocated buffers.
        let analyzer = self.analyzer
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { _, inInputData, _, _, _ in
            analyzer.process(inInputData)
        }
        guard status == noErr, let proc = newProc else { stop(); return false }
        procID = proc

        guard AudioDeviceStart(aggregateID, proc) == noErr else { stop(); return false }
        running = true
        return true
    }

    /// Idempotent full teardown: IOProc, aggregate device, tap.
    func stop() {
        if let proc = procID {
            if running { _ = AudioDeviceStop(aggregateID, proc) }
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        running = false
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr,
              let cf = uid?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }
}

// MARK: - Band analysis (runs on the IO queue; allocation-free after init)

private final class BandAnalyzer: @unchecked Sendable {
    private static let fftSize = 1024
    private static let log2n: vDSP_Length = 10
    private static let ringSize = 4096                 // power of two
    private static let maxFrames = 16384               // scratch for one IO buffer
    private let bandCount = AudioLevels.bandCount

    // Audio-thread state (IO queue only).
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let frame = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let imag = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let power = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let bandLo = UnsafeMutablePointer<Int>.allocate(capacity: AudioLevels.bandCount)
    private let bandHi = UnsafeMutablePointer<Int>.allocate(capacity: AudioLevels.bandCount)
    private let peakDb = UnsafeMutablePointer<Float>.allocate(capacity: AudioLevels.bandCount)
    private let smoothed = UnsafeMutablePointer<Float>.allocate(capacity: AudioLevels.bandCount)
    private let fftSetup: FFTSetup?
    private var writeIndex = 0
    private var sinceAnalysis = 0
    private var hop = 1600
    private var sampleRate: Double = 48_000
    private var attack: Float = 0.4
    private var release: Float = 0.15
    private var peakDecay: Float = 0.13
    private var silentSamples = Int.max / 2

    // Shared snapshot (guarded by lock; written on IO queue, read on main).
    private let lock = OSAllocatedUnfairLock()
    private let published = UnsafeMutablePointer<Float>.allocate(capacity: AudioLevels.bandCount)
    private var publishedSilentSeconds: Double = .infinity

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        ring.initialize(repeating: 0, count: Self.ringSize)
        mono.initialize(repeating: 0, count: Self.maxFrames)
        frame.initialize(repeating: 0, count: Self.fftSize)
        window.initialize(repeating: 0, count: Self.fftSize)
        vDSP_hann_window(window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        real.initialize(repeating: 0, count: Self.fftSize / 2)
        imag.initialize(repeating: 0, count: Self.fftSize / 2)
        power.initialize(repeating: 0, count: Self.fftSize / 2)
        bandLo.initialize(repeating: 1, count: bandCount)
        bandHi.initialize(repeating: 2, count: bandCount)
        peakDb.initialize(repeating: -45, count: bandCount)
        smoothed.initialize(repeating: 0, count: bandCount)
        published.initialize(repeating: 0, count: bandCount)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        ring.deallocate(); mono.deallocate(); frame.deallocate(); window.deallocate()
        real.deallocate(); imag.deallocate(); power.deallocate()
        bandLo.deallocate(); bandHi.deallocate(); peakDb.deallocate(); smoothed.deallocate()
        published.deallocate()
    }

    /// Called once before the IOProc starts.
    func configure(sampleRate sr: Double) {
        sampleRate = sr
        hop = max(256, Int(sr / 30))                   // analyse at most ~30×/s
        let dt = Double(hop) / sr
        attack = Float(1 - exp(-dt / 0.06))            // ~60 ms attack
        release = Float(1 - exp(-dt / 0.2))            // ~200 ms release
        peakDecay = Float(4 * dt)                      // peak falls ~4 dB/s → adapts over seconds
        // Log-spaced bands, 50 Hz … 14 kHz (capped below Nyquist).
        let binHz = sr / Double(Self.fftSize)
        let maxBin = Self.fftSize / 2 - 1
        let lo = 50.0, hi = min(14_000, sr * 0.45)
        for k in 0..<bandCount {
            let f0 = lo * pow(hi / lo, Double(k) / Double(bandCount))
            let f1 = lo * pow(hi / lo, Double(k + 1) / Double(bandCount))
            let b0 = min(maxBin, max(1, Int(f0 / binHz)))
            let b1 = min(maxBin + 1, max(b0 + 1, Int(f1 / binHz)))
            bandLo[k] = b0
            bandHi[k] = b1
        }
    }

    /// IO callback: mix to mono, push into the ring, analyse every `hop` samples.
    func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var frames = 0
        var totalChannels = 0
        for buffer in buffers {
            let ch = Int(buffer.mNumberChannels)
            guard ch > 0, let data = buffer.mData else { continue }
            let n = min(Self.maxFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch))
            guard n > 0 else { continue }
            if totalChannels == 0 {
                frames = n
                vDSP_vclr(mono, 1, vDSP_Length(n))
            }
            let src = data.assumingMemoryBound(to: Float.self)
            let m = min(n, frames)
            for c in 0..<ch {
                vDSP_vadd(src + c, vDSP_Stride(ch), mono, 1, mono, 1, vDSP_Length(m))
            }
            totalChannels += ch
        }
        guard frames > 0, totalChannels > 0 else { return }
        var scale = 1 / Float(totalChannels)
        vDSP_vsmul(mono, 1, &scale, mono, 1, vDSP_Length(frames))

        var peak: Float = 0
        vDSP_maxmgv(mono, 1, &peak, vDSP_Length(frames))
        if peak > 1e-6 { silentSamples = 0 } else { silentSamples = min(Int.max / 2, silentSamples + frames) }

        // Ring write (only the newest ringSize samples matter).
        let start = max(0, frames - Self.ringSize)
        var remaining = frames - start
        var src = mono + start
        while remaining > 0 {
            let chunk = min(remaining, Self.ringSize - writeIndex)
            (ring + writeIndex).update(from: src, count: chunk)
            writeIndex = (writeIndex + chunk) & (Self.ringSize - 1)
            src += chunk
            remaining -= chunk
        }

        sinceAnalysis += frames
        if sinceAnalysis >= hop {
            sinceAnalysis = 0
            analyse()
        }
    }

    private func analyse() {
        guard let fftSetup else { return }
        let n = Self.fftSize
        // Newest n samples from the ring, in order.
        let begin = (writeIndex - n + Self.ringSize) & (Self.ringSize - 1)
        let first = min(n, Self.ringSize - begin)
        frame.update(from: ring + begin, count: first)
        if first < n { (frame + first).update(from: ring, count: n - first) }
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: real, imagp: imag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
        imag[0] = 0                                    // packed Nyquist; bin 0 is skipped anyway
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(n / 2))
        // Normalise so a full-scale sine peaks near 1 (zrip is 2× the DFT; Hann gain ~0.5).
        var norm = 1 / Float(n * n / 4)
        vDSP_vsmul(power, 1, &norm, power, 1, vDSP_Length(n / 2))

        let range: Float = 36                          // dB shown below the adaptive peak
        let silent = silentSamples > hop
        for k in 0..<bandCount {
            var sum: Float = 0
            let lo = bandLo[k], hi = bandHi[k]
            if hi > lo { vDSP_sve(power + lo, 1, &sum, vDSP_Length(hi - lo)) }
            let db = 10 * log10f(sum + 1e-12)
            // Slowly adapting peak (instant rise, slow fall, floor so silence stays low).
            peakDb[k] = max(-45, max(db, peakDb[k] - peakDecay))
            var level = (db - (peakDb[k] - range)) / range
            level = min(1, max(0, level))
            level = powf(level, 1.5)                   // a little contrast
            if silent { level = 0 }
            let a = level > smoothed[k] ? attack : release
            smoothed[k] += (level - smoothed[k]) * a
        }

        let silentSeconds = Double(silentSamples) / sampleRate
        if lock.lockIfAvailable() {                    // never block the audio thread
            published.update(from: smoothed, count: bandCount)
            publishedSilentSeconds = silentSeconds
            lock.unlock()
        }
    }

    /// Main thread: copies the latest bands; returns seconds of digital silence so far.
    func read(into out: UnsafeMutableBufferPointer<Float>) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let n = min(out.count, bandCount)
        if let base = out.baseAddress { base.update(from: published, count: n) }
        return publishedSilentSeconds
    }
}
