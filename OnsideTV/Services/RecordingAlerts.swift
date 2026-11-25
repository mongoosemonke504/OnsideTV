import Foundation
import UserNotifications

/// Local notifications for when a recording needs the app and the app may not
/// be there. iOS gives no way to wake a closed app at a set time, so these are
/// set ahead and taken back by the running app: they only ever reach someone
/// whose app isn't doing its job.
enum RecordingAlerts {
    /// How long before the start the heads-up comes.
    static let headsUpLead: TimeInterval = 120

    private static func id(_ kind: String, _ recording: UUID) -> String { "rec_\(kind)_\(recording.uuidString)" }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Set when a recording is scheduled.
    static func schedule(for recording: Recording) {
        let name = recording.displayName
        add(id("soon", recording.id), title: "Recording starts in 2 minutes",
            body: "Open Onside TV so it can record \(name).",
            at: recording.startTime.addingTimeInterval(-headsUpLead))
        add(id("late", recording.id), title: "Recording hasn't started",
            body: "Open Onside TV to record the rest of \(name).",
            at: recording.startTime.addingTimeInterval(60))
    }

    /// The app is up and will start it itself.
    static func clearHeadsUp(_ recording: UUID) { remove([id("soon", recording)]) }

    static func recordingStarted(_ recording: Recording) {
        remove([id("soon", recording.id), id("late", recording.id)])
        stillRecording(recording)
    }

    /// Pushed back for as long as video keeps arriving. Comes through if the
    /// app is closed or the stream goes dead.
    static func stillRecording(_ recording: Recording) {
        let at = Date().addingTimeInterval(180)
        guard at < recording.endTime else { return remove([id("stalled", recording.id)]) }
        add(id("stalled", recording.id), title: "Recording may have stopped",
            body: "Open Onside TV to keep recording \(recording.displayName).", at: at)
    }

    static func storageFull(_ recording: Recording) {
        add(id("full", recording.id), title: "Recording stopped",
            body: "There's no storage left for \(recording.displayName). What it got so far is saved.",
            at: Date().addingTimeInterval(1))
    }

    /// Finished, deleted or missed: nothing more to say about it.
    static func clear(_ recording: UUID) {
        remove(["soon", "late", "stalled"].map { id($0, recording) })
    }

    private static func remove(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    private static func add(_ id: String, title: String, body: String, at date: Date) {
        let delay = date.timeIntervalSinceNow
        guard delay > 0.5 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
