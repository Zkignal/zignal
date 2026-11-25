import Foundation
import UserNotifications

/// An optional daily nudge to open Zignal. iOS makes it on this phone at the time the user
/// picked: a local notification, with no push service and no server. Zignal can't check for
/// messages while it's locked, so the reminder never knows, and never says, whether anything
/// arrived. Its time is kept only by iOS, in the pending notification: not in Zignal's files
/// or preferences, and the same whichever profile is open.
enum Reminder {
    static let identifier = "zignal.reminder"
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

    /// The notification: the same words every day, silent, with no badge and nothing about
    /// messages, contacts or profiles.
    static func request(at time: Time) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var when = DateComponents()
        when.hour = time.hour
        when.minute = time.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
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

    /// The reminder's time, or nil when it's off.
    static func current() async -> Time? {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        for request in pending {
            if let time = time(of: request) { return time }
        }
        return nil
    }

    /// Turns the reminder on at `time`. The first time, iOS asks whether Zignal may show
    /// notifications. Returns false when the user hasn't allowed them.
    static func set(_ time: Time) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert]) else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try await center.add(request(at: time))
        return true
    }

    /// Turns the reminder off, and takes a shown one off the lock screen.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Takes a shown reminder off the lock screen and Notification Center. Called at unlock.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
