import XCTest

/// Scripted walkthroughs for the README demo GIFs.
///
/// Each test is one clip. They launch the app with `-demoMode`, which signs in
/// to a generated playlist of open-licence test streams (see `DemoMode.swift`),
/// so every take shows the same channels and guide.
///
/// `record-demos.sh` runs these one at a time and starts/stops the Simulator
/// recording when it sees the `DEMO_READY` / `DEMO_DONE` lines printed below,
/// so app launch and teardown never end up in the video.
///
/// Timing lives in the constants at the top: slow the gestures down or add
/// pauses there and rerun the script for a new take.
final class OnsideTVDemoTests: XCTestCase {

    // MARK: - Tuning

    /// Points per second for scrolls. Lower is slower and smoother on camera.
    private let scrollSpeed: CGFloat = 420
    /// A beat between actions so viewers can see what happened.
    private let beat: TimeInterval = 1.4

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-demoMode"]
        app.launch()
    }

    // MARK: - Clips

    /// Home: the hero carousel, then a slow scroll down through the shelves.
    func testDemo1_Home() throws {
        waitForHome()
        startClip()

        pause(3)                          // let the hero carousel breathe
        scroll(.up, distance: 0.55)       // content moves up = scrolling down
        pause(beat)
        scroll(.up, distance: 0.55)
        pause(beat)
        scroll(.up, distance: 0.55)
        pause(beat)
        scroll(.down, distance: 0.9, speed: scrollSpeed * 1.8)
        pause(2)

        endClip()
    }

    /// Watch: open a channel's guide card, play it, swipe to the next channel,
    /// then swipe down into the mini player.
    func testDemo2_Watch() throws {
        waitForHome()
        startClip()

        pause(1.5)
        let card = channelCard("Open Movie Channel")
        bringIntoView(card)
        pause(beat)
        card.tap()
        pause(2.5)                        // guide card: now + upcoming

        let play = app.buttons["previewPlayButton"]
        if play.waitForExistence(timeout: 5) { play.tap() }
        pause(7)                          // playback + info panel

        swipeOnVideo(.left)               // next channel
        pause(5)

        swipeOnVideo(.down)               // into the mini player
        pause(3)

        endClip()
    }

    /// Search: type a query and open the result.
    func testDemo3_Search() throws {
        waitForHome()
        startClip()

        pause(1.5)
        let searchTab = app.descendants(matching: .any)["tab_search"]
        if searchTab.waitForExistence(timeout: 5) { searchTab.tap() }
        pause(1)

        let field = app.textFields["Search"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            typeSlowly("wild", into: field)
        }
        pause(2.5)

        // Collapse the keyboard so the results are visible, then open one.
        let result = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Wild Planet")).firstMatch
        if result.waitForExistence(timeout: 3) {
            result.tap()
            pause(3)
        }

        endClip()
    }

    /// Sports: the score hub, then a game card with its stats.
    /// Live data, so what appears depends on the day it is recorded.
    func testDemo4_Sports() throws {
        waitForHome()
        startClip()

        pause(1.5)
        let sportsTab = app.buttons["tab_sports"]
        if sportsTab.waitForExistence(timeout: 5) { sportsTab.tap() }
        pause(3)                          // scores load in

        scroll(.up, distance: 0.4)
        pause(beat)
        scroll(.down, distance: 0.4)
        pause(beat)

        let game = app.buttons.matching(identifier: "gameCard").firstMatch
        if game.waitForExistence(timeout: 8) {
            game.tap()
            pause(3)
            scroll(.up, distance: 0.45)   // down through lineups / stats
            pause(beat)
            scroll(.up, distance: 0.45)
            pause(2)
        }

        endClip()
    }

    // MARK: - Recording markers

    /// Printed lines the recording script listens for.
    private func startClip() {
        print("DEMO_READY")
        pause(1)   // the recorder takes a moment to start
    }

    private func endClip() {
        pause(0.5)
        print("DEMO_DONE")
        pause(1.5) // keep the app alive until the recorder has stopped
    }

    // MARK: - Helpers

    private func waitForHome() {
        // The first shelf card appearing means the playlist and guide are in.
        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'channelCard_'")).firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 30), "Demo playlist never loaded — is -demoMode working?")
        pause(2) // logos and artwork settle
    }

    private func channelCard(_ name: String) -> XCUIElement {
        app.buttons["channelCard_\(name)"]
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private enum Direction { case up, down, left }

    /// A slow, even drag through the middle of the screen.
    /// `.up` moves content up (scrolls down the page); `.down` scrolls back.
    private func scroll(_ direction: Direction, distance: CGFloat, speed: CGFloat? = nil) {
        let window = app.windows.firstMatch
        let x: CGFloat = 0.5
        let (fromY, toY): (CGFloat, CGFloat) = {
            switch direction {
            case .up:   return (0.75, 0.75 - distance)
            case .down: return (0.2, 0.2 + distance)
            case .left: return (0.5, 0.5)
            }
        }()
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: fromY))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: max(0.05, min(0.95, toY))))
        from.press(forDuration: 0.05,
                   thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(speed ?? scrollSpeed),
                   thenHoldForDuration: 0.1)
    }

    /// Scrolls the home page until `element` is on screen (at most 8 tries).
    private func bringIntoView(_ element: XCUIElement) {
        var tries = 0
        while tries < 8 && !(element.exists && element.isHittable) {
            scroll(.up, distance: 0.35)
            pause(0.6)
            tries += 1
        }
    }

    /// Swipes inside the video area at the top of the portrait player —
    /// the player only takes channel and dismiss swipes there.
    private func swipeOnVideo(_ direction: Direction) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end: XCUICoordinate
        switch direction {
        case .left: end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2))
        case .down: end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        case .up:   end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        }
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0)
    }

    /// Types one character at a time so the query visibly builds up.
    private func typeSlowly(_ text: String, into field: XCUIElement) {
        for ch in text {
            field.typeText(String(ch))
            pause(0.25)
        }
    }
}
