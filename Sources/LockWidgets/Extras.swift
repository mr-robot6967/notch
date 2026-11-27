import AppKit
import Combine
import IOKit.pwr_mgt

/// Smaller features: keep awake, hourly chime, calendar quick peek, Low Power Mode and
/// Focus changes.
@MainActor
final class Extras {
    static let shared = Extras()

    private var assertion: IOPMAssertionID = 0
    private var chimeTimer: Timer?
    private var peekTimer: Timer?
    private var peeked = Set<String>()
    private var lastLowPower = false
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let settings = AppSettings.shared

        settings.$config.map(\.keepAwake).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setKeepAwake(on) }
            .store(in: &cancellables)

        settings.$config.map(\.hourlyChime).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.scheduleChime(on) }
            .store(in: &cancellables)
        // Timers drift while asleep; re-align the chime to the hour after wake.
        // (Also after the clock or time zone changes, which would leave it off the hour.)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleChime(AppSettings.shared.config.hourlyChime) }
            .store(in: &cancellables)

        // Calendar quick peek: check each minute for an event about to start.
        let peek = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Extras.shared.checkUpcomingEvent() }
        }
        peek.tolerance = 10
        RunLoop.main.add(peek, forMode: .common)
        peekTimer = peek

        lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // The notification is also posted without Low Power Mode changing (other power-state
                // updates, wake); only an actual change is news.
                let on = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard on != self.lastLowPower else { return }
                self.lastLowPower = on
                guard AppSettings.shared.config.lowPowerActivity else { return }
                // "Low Power Mode: only on battery" switches it as a consequence of (un)plugging the
                // charger; that automatic change must not replace the charging status just shown.
                if case .charging = NotchModel.shared.transient, NotchModel.shared.statusIsFresh(3) { return }
                NotchModel.shared.flash(.lowPower(on), seconds: 3)
            }
            .store(in: &cancellables)

        FocusWatcher.shared.start()
    }

    private func setKeepAwake(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Notch: Keep awake" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    private func scheduleChime(_ on: Bool) {
        chimeTimer?.invalidate()
        chimeTimer = nil
        guard on else { return }
        let calendar = Calendar.current
        guard let nextHour = calendar.nextDate(after: Date(), matching: DateComponents(minute: 0, second: 0),
                                               matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: nextHour, interval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !NotchModel.shared.locked else { return }
                // A repeating timer whose fire date passed during sleep fires once on wake, at a random
                // minute (before the wake handler re-aligns it). Only chime on the hour.
                let minute = Calendar.current.component(.minute, from: Date())
                guard minute == 0 || minute == 59 else { return }
                SystemSounds.play("Purr")
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        chimeTimer = timer
    }

    private func checkUpcomingEvent() {
        let cfg = AppSettings.shared.config
        guard cfg.calendarPeek, let event = WidgetStore.shared.nextEvent, !event.isHappeningNow else { return }
        let minutes = Int((event.start.timeIntervalSinceNow / 60).rounded(.up))
        guard minutes >= 0, minutes <= cfg.calendarPeekMinutes else { return }
        let key = "\(event.title)|\(event.start.timeIntervalSince1970)"
        guard peeked.insert(key).inserted else { return }
        NotchModel.shared.flash(.event(title: event.title, minutes: minutes, colorHex: event.colorHex), seconds: 6)
        if cfg.lockSounds { SystemSounds.play("Glass") }
    }
}
