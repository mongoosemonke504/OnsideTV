import ActivityKit
import AppIntents

/// The X on a game's Live Activity. Without it a finished game could stay on
/// the Lock Screen with no way to clear it: its card was gone from the app, so
/// its bell couldn't be turned off. The app and the widget each have a copy,
/// as iOS needs; it runs in the app.
struct EndGameActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Remove Live Activity"
    static let isDiscoverable = false

    @Parameter(title: "Game")
    var gameID: String

    init() {}

    init(gameID: String) {
        self.gameID = gameID
    }

    func perform() async throws -> some IntentResult {
        for activity in Activity<GameActivityAttributes>.activities where activity.attributes.gameID == gameID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
