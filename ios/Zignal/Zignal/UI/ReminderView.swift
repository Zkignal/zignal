import SwiftUI

/// The optional reminders (see `Reminder`): a daily one, and a countdown that fires once or keeps
/// repeating. They're kept by iOS, not in a profile, so this screen is the same for both profiles
/// and shows nothing about either.
struct ReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var time = ReminderView.date(hour: 21, minute: 0)
    @State private var countdownOn = false
    @State private var hours = 0
    @State private var minutes = 10
    @State private var repeats = false
    @State private var pending: Reminder.PendingCountdown?
    @State private var loaded = false
    @State private var note: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $enabled)
                    if enabled {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Every day at the time you pick.")
                }
                Section {
                    Toggle("Remind me in", isOn: $countdownOn)
                    if countdownOn {
                        HStack(spacing: 0) {
                            Picker("Hours", selection: $hours) {
                                ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            Picker("Minutes", selection: $minutes) {
                                ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        }
                        .frame(height: 150)
                        Toggle("Repeat", isOn: $repeats)
                    }
                } footer: {
                    countdownFooter
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Zignal can't check for messages while it's locked, and no server watches for you. These reminders are made by your iPhone. They always say \"\(Reminder.title): \(Reminder.body)\", never whether anything arrived. Anyone who can see your lock screen sees them too.")
                }
                if let note {
                    Section { Text(note).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!loaded || saving)
                }
            }
            .task {
                if let current = await Reminder.current() {
                    enabled = true
                    time = ReminderView.date(hour: current.hour, minute: current.minute)
                }
                if let current = await Reminder.currentCountdown() {
                    pending = current
                    countdownOn = true
                    hours = current.countdown.interval.hours
                    minutes = current.countdown.interval.minutes
                    repeats = current.countdown.repeats
                }
                loaded = true
            }
        }
    }

    @ViewBuilder private var countdownFooter: some View {
        if !countdownOn {
            Text("Once, or again and again, after a length of time you pick.")
        } else if let next = pending?.next, picked == pending?.countdown {
            Text("Next reminder at \(next, style: .time). A change starts it again when you save.")
        } else if repeats {
            Text("Again every time this much time passes, until you turn it off. It starts when you save.")
        } else {
            Text("Once, this long after you save.")
        }
    }

    /// The countdown as picked on screen, or nil for 0 h 0 min.
    private var picked: Reminder.Countdown? {
        Reminder.Interval(hours: hours, minutes: minutes).map {
            Reminder.Countdown(interval: $0, repeats: repeats)
        }
    }

    private func save() {
        guard !saving else { return }
        note = nil
        let daily: Reminder.Time?
        if enabled {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            guard let at = Reminder.Time(hour: parts.hour ?? -1, minute: parts.minute ?? -1) else { return }
            daily = at
        } else {
            daily = nil
        }
        let countdown: Reminder.Countdown?
        if countdownOn {
            guard let chosen = picked else {
                note = "Pick at least 1 minute."
                return
            }
            countdown = chosen
        } else {
            countdown = nil
        }
        // A pending countdown that wasn't changed keeps running from when it was set.
        let restart = countdown != nil && countdown != pending?.countdown
        // One save at a time: Save is off until this one has finished. What needs permission
        // goes first, so when notifications aren't allowed nothing has been changed or
        // cleared yet.
        saving = true
        Task {
            defer { saving = false }
            do {
                if let daily {
                    guard try await Reminder.set(daily) else {
                        notAllowed()
                        return
                    }
                }
                if let countdown, restart {
                    guard try await Reminder.setCountdown(countdown) else {
                        notAllowed()
                        return
                    }
                }
                if daily == nil { Reminder.clear() }
                if countdown == nil { Reminder.clearCountdown() }
                dismiss()
            } catch {
                note = "The reminder couldn't be set. Try again."
            }
        }
    }

    private func notAllowed() {
        note = "Notifications are off for Zignal. Allow them in the Settings app under Notifications, then save again."
    }

    /// Today at the given time of day: the picker only uses the hour and minute.
    private static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
