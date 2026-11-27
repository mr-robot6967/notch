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

    /// UIDs of the Bluetooth outputs seen so far, to notice a new one (AirPods connecting) without
    /// the Bluetooth permission IOBluetooth's connect notifications need.
    private var knownBluetooth = Set<String>()
    /// Devices present at launch and re-enumerated after wake aren't "just connected".
    private var ignoreNewUntil = Date().addingTimeInterval(5)

    func start() {
        guard !listening else { return }
        listening = true
        ignoreNewUntil = Date().addingTimeInterval(5)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AudioDevices.shared.ignoreNewUntil = Date().addingTimeInterval(5) }
        }
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
        let previousID = currentID
        currentID = Self.defaultOutput()
        if previousID != kAudioObjectUnknown, previousID != currentID { BrightnessWatcher.shared.audioRouteChanged() }
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
        noticeNewBluetoothOutputs(ids.filter(Self.hasOutput))
    }

    private func noticeNewBluetoothOutputs(_ ids: [AudioObjectID]) {
        var current = Set<String>()
        var added: [String] = []
        for id in ids {
            let transport = Self.transport(of: id)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let uid = Self.uid(of: id) else { continue }
            current.insert(uid)
            if !knownBluetooth.contains(uid), let name = Self.name(of: id) { added.append(name) }
        }
        knownBluetooth = current
        guard Date() >= ignoreNewUntil else { return }
        // NotchController dedupes against the IOBluetooth notification for the same device.
        for name in added { AppDelegate.shared?.notch?.deviceConnected(name) }
    }

    private static func transport(of id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }

    private static func uid(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let value = uid?.takeRetainedValue() else { return nil }
        return value as String
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

    /// The default output has a settable mute (HDMI/DisplayPort outputs often don't).
    static func canSetMute() -> Bool {
        let device = defaultOutput()
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
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
        case kAudioDeviceTransportTypeBuiltIn: // (a nil IOPS reading during wake is transient; the store keeps the last one)
            return WidgetStore.shared.mac == nil && MacBattery.read() == nil ? "desktopcomputer" : "laptopcomputer"
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
    /// The display the change notifications are registered for. Launching in clamshell mode (or with
    /// the built-in panel off) registered for the external screen only, and opening the lid never
    /// re-registered, so the brightness HUD stayed dead until relaunch.
    @MainActor private static var registeredDisplays = Swift.Set<CGDirectDisplayID>()

    @MainActor static func observe() {
        guard let registerFn else { return }
        let target = display
        guard !registeredDisplays.contains(target) else { return }
        registeredDisplays.insert(target)
        let result = registerFn(target, nil) { _, _, _, _, _ in
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
        ignoreAutomatic(for: 5)
    }

    func start() {
        last = Brightness.get() ?? -1
        Brightness.observe()
        // Register for the built-in panel once it appears (lid opened, display reconnected).
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Brightness.observe()
                BrightnessWatcher.shared.ignoreAutomatic(for: 3)
            }
        }
        // The display ramps its brightness down when it sleeps (and the idle dim before that) and
        // back up on wake; those automatic changes are not the user pressing a key.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { BrightnessWatcher.shared.ignoreAutomatic(for: 5) }
            }
        }
    }

    private func ignoreAutomatic(for seconds: TimeInterval) {
        ignoreAutomaticUntil = max(ignoreAutomaticUntil, Date().addingTimeInterval(seconds))
    }

    /// Called by the media-key tap so key presses always show the HUD immediately.
    func userChanged(to value: Float) {
        last = value
        lastUserChange = Date()
        NotchModel.shared.flash(.brightness(level: value), seconds: 1.6)
    }

    /// When the previous brightness notification arrived (to tell a key step from a ramp).
    private var lastNotificationAt = Date.distantPast

    /// The default audio output switched (AirPods out of the ears, headphones…): auto-brightness
    /// adjustments around that moment showed a "Display" pop-up nobody asked for.
    func audioRouteChanged() { ignoreAutomatic(for: 3) }

    fileprivate func changed() {
        guard let value = Brightness.get() else { return }
        let now = Date()
        let delta = abs(value - last)
        let stableFor = now.timeIntervalSince(lastNotificationAt)
        lastNotificationAt = now
        // Running baseline: every reading moves it, so a slow auto-brightness ramp (many small
        // notifications) can never add up to a pop-up. (It used to compare against the last *shown*
        // level, so drift accumulated until it crossed the threshold.)
        last = value
        guard now.timeIntervalSince(lastUserChange) > 0.3, now >= ignoreAutomaticUntil else { return }
        // A brightness key (without the key tap) is one discrete step of 1/16 (1/64 with ⌥⇧, ~0.016)
        // arriving after the level was still; automatic changes come as small increments in quick
        // succession. Fine ⌥⇧ steps are below this threshold and so only show through the key tap.
        // While a brightness HUD is already up, further key steps (held key) update it.
        let hudUp: Bool = { if case .brightness = NotchModel.shared.transient { return true } else { return false } }()
        guard delta >= 0.05, stableFor >= 0.4 || hudUp else { return }
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
        // Same for mute: without a settable mute property the key was swallowed and did nothing.
        if code == 7 && !MainActor.assumeIsolated({ AudioDevices.canSetMute() }) { return false }
        if [2, 3].contains(code) && (disabled.contains("brightness") || Brightness.get() == nil) { return false }
        guard isDown else { return true } // swallow key-up too
        let fine = ns.modifierFlags.contains(.option) && ns.modifierFlags.contains(.shift)
        let shift = ns.modifierFlags.contains(.shift)
        let step: Float = fine ? 1.0 / 64.0 : 1.0 / 16.0
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch code {
                case 0, 1:
                    MediaKeyTap.lastVolumeKeyAt = Date()
                    let v = min(1, max(0, AudioDevices.volume() + (code == 0 ? step : -step)))
                    AudioDevices.setVolume((v * 64).rounded() / 64)
                    VolumeFeedback.play(shiftHeld: shift)
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

/// macOS's "Play feedback when volume is changed" pop. Because the key tap sets the volume itself
/// (to show the island instead of Apple's pop-up), macOS no longer plays it — so we do, using the
/// system's own sound, whenever that setting is on (Shift inverts it, exactly like macOS).
@MainActor
enum VolumeFeedback {
    private static var lastPlayed = Date.distantPast
    private static var cached: (path: String, sound: NSSound)?

    /// What macOS plays for volume feedback: the alert sound chosen in System Settings › Sound
    /// (com.apple.sound.beep.sound), at the alert volume. The old built-in "volume" pop is only a
    /// fallback when no alert sound is set.
    private static func feedbackSound() -> (NSSound, Float)? {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let fallback = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        var path = (global["com.apple.sound.beep.sound"] as? String) ?? fallback
        if !FileManager.default.fileExists(atPath: path) { path = fallback }
        let volume = Float((global["com.apple.sound.beep.volume"] as? Double) ?? 1)
        if let cached, cached.path == path { return (cached.sound, volume) }
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        cached = (path, sound)
        return (sound, volume)
    }

    static func play(shiftHeld: Bool) {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let enabled = (global["com.apple.sound.beep.feedback"] as? NSNumber)?.intValue == 1
        // Shift inverts the setting, exactly like macOS; no sound while muted.
        guard enabled != shiftHeld, !AudioDevices.isMuted(), let (sound, volume) = feedbackSound() else { return }
        // Holding the key repeats fast; one sound per ~120 ms, like macOS.
        guard Date().timeIntervalSince(lastPlayed) > 0.12 else { return }
        lastPlayed = Date()
        sound.stop()
        sound.volume = max(0.05, min(1, volume))
        sound.play()
    }
}
