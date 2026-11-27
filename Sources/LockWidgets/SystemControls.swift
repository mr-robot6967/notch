import AppKit
import ApplicationServices
import Combine
import CoreAudio
import OSLog

private let controlsLog = Logger(subsystem: "com.k2a.LockWidgets", category: "controls")

// MARK: - Audio output devices + volume (CoreAudio)

@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let name: String
        let symbol: String
    }

    @Published private(set) var outputs: [Device] = []
    @Published private(set) var currentID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var listening = false
    private var watchedSourceDevice = AudioObjectID(kAudioObjectUnknown)
    private lazy var sourceBlock: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { AudioDevices.shared.refresh() }
    }

    func start() {
        guard !listening else { return }
        listening = true
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { AudioDevices.shared.refresh() }
            }
        }
    }

    func refresh() {
        currentID = Self.defaultOutput()
        watchDataSource(of: currentID)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        outputs = ids.filter(Self.hasOutput).compactMap { id in
            guard var name = Self.name(of: id) else { return nil }
            // The built-in output switches between speakers and the headphone jack as a "data source",
            // not as a separate device, so check which one is active.
            if let source = Self.dataSource(of: id) {
                if let sourceName = source.name { name = sourceName }
                if source.code == 0x6864_706E { // 'hdpn'
                    return Device(id: id, name: name, symbol: "headphones")
                }
            }
            return Device(id: id, name: name, symbol: Self.symbol(for: id, name: name))
        }
    }

    func select(_ device: Device) {
        var id = device.id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
        refresh()
    }

    var current: Device? { outputs.first { $0.id == currentID } }

    /// Re-check when headphones are plugged into / pulled out of the jack.
    private func watchDataSource(of id: AudioObjectID) {
        guard id != watchedSourceDevice else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if watchedSourceDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watchedSourceDevice, &address, .main, sourceBlock)
        }
        watchedSourceDevice = id
        if AudioObjectHasProperty(id, &address) {
            AudioObjectAddPropertyListenerBlock(id, &address, .main, sourceBlock)
        }
    }

    private static func dataSource(of id: AudioObjectID) -> (code: UInt32, name: String?)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var code: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &code) == noErr else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var input = code
        var cfName: Unmanaged<CFString>?
        let name: String? = withUnsafeMutablePointer(to: &input) { inputPtr in
            withUnsafeMutablePointer(to: &cfName) { outputPtr in
                var translation = AudioValueTranslation(mInputData: inputPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                                        mOutputData: outputPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &translationSize, &translation) == noErr else { return nil }
                return outputPtr.pointee?.takeRetainedValue() as String?
            }
        }
        return (code, name)
    }

    // Volume of the default output (0...1)
    static func volume() -> Float {
        let device = defaultOutput()
        var value: Float32 = 0
        for element in [kAudioObjectPropertyElementMain, 1] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr { return value }
        }
        return 0
    }

    static func setVolume(_ volume: Float) {
        let device = defaultOutput()
        var value = Float32(min(1, max(0, volume)))
        var set = false
        var main = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) {
            set = AudioObjectSetPropertyData(device, &main, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        }
        if !set {
            for channel: UInt32 in [1, 2] {
                var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
                if AudioObjectHasProperty(device, &a) {
                    AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
                }
            }
        }
        if value > 0 && isMuted() { setMuted(false) }
    }

    /// HDMI/DisplayPort outputs and some USB DACs have no software volume; for those macOS shows its
    /// own "can't change" HUD, which is better than swallowing the key and doing nothing.
    static func canSetVolume() -> Bool {
        let device = defaultOutput()
        for element in [kAudioObjectPropertyElementMain, 1] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    static func isMuted() -> Bool {
        let device = defaultOutput()
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &a) else { return false }
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &muted)
        return muted != 0
    }

    static func setMuted(_ muted: Bool) {
        let device = defaultOutput()
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        guard AudioObjectHasProperty(device, &a) else { return }
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func defaultOutput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func symbol(for id: AudioObjectID, name: String) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        // Desktop Macs (no internal battery) have built-in speakers too; don't draw a laptop for them.
        case kAudioDeviceTransportTypeBuiltIn: return MacBattery.read() == nil ? "desktopcomputer" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }
}

// MARK: - Display brightness (private DisplayServices)

enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    /// nil when the private framework or symbol is missing (feature off, keys go to macOS).
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? { handle.flatMap { dlsym($0, name) } }
    private static let getFn = symbol("DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setFn = symbol("DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
    private static let registerFn = symbol("DisplayServicesRegisterForBrightnessChangeNotifications")
        .map { unsafeBitCast($0, to: Register.self) }

    /// The built-in display (where brightness keys apply).
    static var display: CGDirectDisplayID {
        // Look for the built-in panel by ID, not by notch: MacBooks without a notch (and those whose
        // external monitor is the main display) would otherwise target the external screen, where
        // DisplayServices fails and the brightness HUD never shows.
        let ids = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        return ids.first { CGDisplayIsBuiltin($0) != 0 } ?? ids.first ?? CGMainDisplayID()
    }

    static func get() -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        _ = setFn?(display, min(1, max(0, value)))
    }

    /// Calls back on every brightness change (keys, Control Center, ambient light…).
    static func observe() {
        guard let registerFn else { return }
        let result = registerFn(display, nil) { _, _, _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BrightnessWatcher.shared.changed() }
            }
        }
        controlsLog.notice("Brightness notifications registered: \(result)")
    }
}

/// Turns brightness changes into notch HUD events (ignores tiny ambient-light drifts).
@MainActor
final class BrightnessWatcher {
    static let shared = BrightnessWatcher()
    private var last: Float = -1
    private var lastUserChange = Date.distantPast
    /// macOS dims/brightens the display by itself when the charger is plugged in or removed; those
    /// changes must not replace the charging status with a brightness pop-up.
    private var ignoreAutomaticUntil = Date.distantPast

    func powerSourceChanged() {
        ignoreAutomaticUntil = Date().addingTimeInterval(5)
    }

    func start() {
        last = Brightness.get() ?? -1
        Brightness.observe()
    }

    /// Called by the media-key tap so key presses always show the HUD immediately.
    func userChanged(to value: Float) {
        last = value
        lastUserChange = Date()
        NotchModel.shared.flash(.brightness(level: value), seconds: 1.6)
    }

    fileprivate func changed() {
        guard let value = Brightness.get() else { return }
        // Auto-brightness makes small changes all the time; only show clear, user-sized steps.
        guard abs(value - last) >= 0.03, Date().timeIntervalSince(lastUserChange) > 0.3 else { return }
        last = value
        guard Date() >= ignoreAutomaticUntil else { return }
        // A change not made with the keys never covers another status (charging, device, song…).
        if let current = NotchModel.shared.transient {
            if case .brightness = current {} else { return }
        }
        NotchModel.shared.flash(.brightness(level: value), seconds: 1.6)
    }
}

// MARK: - Media keys (replaces the system volume/brightness HUD; needs Accessibility)

/// Intercepts the volume/brightness/mute keys with a CGEvent tap, applies the change itself and
/// swallows the key so macOS doesn't draw its own HUD — the notch HUD shows instead.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Last volume/mute key press handled by the tap (to tell key changes from automatic ones).
    nonisolated(unsafe) static var lastVolumeKeyAt = Date.distantPast

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, Self.isTrusted else { return tap != nil }
        let mask = CGEventMask(1 << 14) // NSEventType.systemDefined
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { MediaKeyTap.shared.reenable() } }
                return Unmanaged.passUnretained(event)
            }
            return MediaKeyTap.handle(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            controlsLog.error("Media key tap could not be created")
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        controlsLog.notice("Media key tap running")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true if the key was handled (and should be swallowed).
    nonisolated private static func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = Int((ns.data1 & 0xFFFF_0000) >> 16)
        let state = (ns.data1 & 0xFF00) >> 8
        let isDown = state == 0xA
        // 0 vol up, 1 vol down, 2 brightness up, 3 brightness down, 7 mute
        guard [0, 1, 2, 3, 7].contains(code) else { return false }
        // While the island is hidden (fullscreen) or off, let macOS show its own HUD.
        let hidden = MainActor.assumeIsolated { AppDelegate.shared?.notch?.hiddenForFullscreen ?? true }
        if hidden { return false }
        // If that HUD is turned off in the island, leave the key (and Apple's HUD) to macOS.
        // The tap runs on the main run loop, so read settings directly (main.sync here would deadlock).
        let disabled = MainActor.assumeIsolated { AppSettings.shared.config.disabledActivities }
        if [0, 1, 7].contains(code) && disabled.contains("volume") { return false }
        if [0, 1].contains(code) && !MainActor.assumeIsolated({ AudioDevices.canSetVolume() }) { return false }
        if [2, 3].contains(code) && (disabled.contains("brightness") || Brightness.get() == nil) { return false }
        guard isDown else { return true } // swallow key-up too
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch code {
                case 0, 1:
                    MediaKeyTap.lastVolumeKeyAt = Date()
                    let v = min(1, max(0, AudioDevices.volume() + (code == 0 ? step : -step)))
                    AudioDevices.setVolume((v * 64).rounded() / 64)
                    // At 0 % / 100 % CoreAudio reports no change, so show the level (and limit haptic) here.
                    if v <= 0 || v >= 1 {
                        NotchModel.shared.flash(.volume(level: v, muted: AudioDevices.isMuted()), seconds: 1.6)
                        if AppSettings.shared.config.notchHaptics {
                            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                        }
                    }
                case 7:
                    MediaKeyTap.lastVolumeKeyAt = Date()
                    AudioDevices.setMuted(!AudioDevices.isMuted())
                case 2, 3:
                    let b = min(1, max(0, (Brightness.get() ?? 0.5) + (code == 2 ? step : -step)))
                    Brightness.set(b)
                    BrightnessWatcher.shared.userChanged(to: b)
                default:
                    break
                }
            }
        }
        return true
    }
}
