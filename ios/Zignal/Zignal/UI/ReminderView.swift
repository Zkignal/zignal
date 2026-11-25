import SwiftUI

/// The optional daily reminder (see `Reminder`). It's kept by iOS, not in a profile, so this
/// screen is the same for both profiles and shows nothing about either.
struct ReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var time = ReminderView.date(hour: 21, minute: 0)
    @State private var loaded = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $enabled)
                    if enabled {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Zignal can't check for messages while it's locked, and no server watches for you. This reminder is made by your iPhone at the time you pick. It always says \"\(Reminder.title): \(Reminder.body)\", never whether anything arrived. Anyone who can see your lock screen sees it too.")
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
                        .disabled(!loaded)
                }
            }
            .task {
                if let current = await Reminder.current() {
                    enabled = true
                    time = ReminderView.date(hour: current.hour, minute: current.minute)
                }
                loaded = true
            }
        }
    }

    private func save() {
        guard enabled else {
            Reminder.clear()
            dismiss()
            return
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard let picked = Reminder.Time(hour: parts.hour ?? -1, minute: parts.minute ?? -1) else { return }
        Task {
            do {
                if try await Reminder.set(picked) {
                    dismiss()
                } else {
                    note = "Notifications are off for Zignal. Allow them in the Settings app under Notifications, then save again."
                }
            } catch {
                note = "The reminder couldn't be set. Try again."
            }
        }
    }

    /// Today at the given time of day: the picker only uses the hour and minute.
    private static func date(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
