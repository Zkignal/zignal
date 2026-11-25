import Foundation
import UserNotifications

/// Optional nudges to open Zignal: a daily one at a time of day, and a countdown that fires once
/// or keeps repeating after a length of time the user picks. iOS makes them on this phone: local
/// notifications, with no push service and no server. Zignal can't check for messages while
/// it's locked, so a reminder never knows, and never says, whether anything arrived. Both are
/// kept only by iOS, in the pending notifications: not in Zignal's files or preferences, and the
/// same whichever profile is open.
enum Reminder {
    static let identifier = "zignal.reminder"
    static let countdownIdentifier = "zignal.reminder.countdown"
    static let title = "Zignal"
    static let body = "Open to check"

    /// A time of day.
    struct Time: Equatable, Sendable {
        let hour: Int
        let minute: Int

        init?(hour: Int, minute: Int) {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            self.hour = hour
            self.minute = minute
        }
    }

    /// A length of time for the countdown: at least a minute, less than a day.
    struct Interval: Equatable, Sendable {
        let hours: Int
        let minutes: Int

        init?(hours: Int, minutes: Int) {
            guard (0...23).contains(hours), (0...59).contains(minutes), hours > 0 || minutes > 0
            else { return nil }
            self.hours = hours
            self.minutes = minutes
        }

        var seconds: TimeInterval { TimeInterval(hours * 3_600 + minutes * 60) }
    }

    /// The countdown: once after the interval, or every time the interval passes.
    struct Countdown: Equatable, Sendable {
        let interval: Interval
        let repeats: Bool
    }

    /// A pending countdown and when it fires next (nil if iOS doesn't say).
    struct PendingCountdown: Equatable, Sendable {
        let countdown: Countdown
        let next: Date?
    }

    /// The words of every reminder: the same each time, silent, with no badge and nothing about
    /// messages, contacts or profiles.
    private static func content() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return content
    }

    /// The daily notification.
    static func request(at time: Time) -> UNNotificationRequest {
        var when = DateComponents()
        when.hour = time.hour
        when.minute = time.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        return UNNotificationRequest(identifier: identifier, content: content(), trigger: trigger)
    }

    /// The countdown notification.
    static func request(after countdown: Countdown) -> UNNotificationRequest {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: countdown.interval.seconds,
                                                        repeats: countdown.repeats)
        return UNNotificationRequest(identifier: countdownIdentifier, content: content(),
                                     trigger: trigger)
    }

    /// The time a pending request fires at, if it is Zignal's daily reminder.
    static func time(of request: UNNotificationRequest) -> Time? {
        guard request.identifier == identifier,
              let trigger = request.trigger as? UNCalendarNotificationTrigger, trigger.repeats,
              let hour = trigger.dateComponents.hour,
              let minute = trigger.dateComponents.minute
        else { return nil }
        return Time(hour: hour, minute: minute)
    }

    /// The countdown a pending request holds, if it is Zignal's countdown.
    static func countdown(of request: UNNotificationRequest) -> Countdown? {
        guard request.identifier == countdownIdentifier,
              let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        else { return nil }
        let seconds = Int(trigger.timeInterval.rounded())
        guard seconds % 60 == 0,
              let interval = Interval(hours: seconds / 3_600, minutes: seconds % 3_600 / 60)
        else { return nil }
        return Countdown(interval: interval, repeats: trigger.repeats)
    }

    /// The daily reminder's time, or nil when it's off.
    static func current() async -> Time? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        for request in pending {
            if let time = time(of: request) { return time }
        }
        return nil
    }

    /// The pending countdown, or nil when there is none (off, or a single one already shown).
    static func currentCountdown() async -> PendingCountdown? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        for request in pending {
            if let countdown = countdown(of: request) {
                let next = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                return PendingCountdown(countdown: countdown, next: next)
            }
        }
        return nil
    }

    /// Turns the daily reminder on at `time`. The first time, iOS asks whether Zignal may show
    /// notifications. Returns false when the user hasn't allowed them.
    static func set(_ time: Time) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert]) else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try await center.add(request(at: time))
        return true
    }

    /// Starts the countdown from now, replacing any pending one. Returns false when the user
    /// hasn't allowed notifications.
    static func setCountdown(_ countdown: Countdown) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert]) else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [countdownIdentifier])
        try await center.add(request(after: countdown))
        return true
    }

    /// Turns the daily reminder off, and takes a shown one off the lock screen.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Turns the countdown off, and takes a shown one off the lock screen.
    static func clearCountdown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [countdownIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [countdownIdentifier])
    }

    /// Takes shown reminders off the lock screen and Notification Center. Called at unlock.
    static func clearDelivered() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier, countdownIdentifier])
    }
}
