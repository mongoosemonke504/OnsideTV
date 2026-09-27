import Foundation
import UIKit

/// A self-contained, fully legal line-up for recording the README demos.
///
/// Launch with `-demoMode` (the UI tests in OnsideTVUITests do this) and the
/// app starts signed in to a generated M3U playlist of open-licence test
/// streams, with a guide that is always "on now" and channel logos drawn on
/// the device. Nothing from a real provider or a real network appears, so the
/// recordings are safe to publish.
///
/// Debug builds only: in a release build `prepareIfNeeded()` does nothing.
enum DemoMode {
    static var isOn: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demoMode")
        #else
        return false
        #endif
    }

    /// Must run before anything touches `AccountManager.shared` or
    /// `ChannelViewModel.shared` — i.e. first thing in `OnsideTVApp.init`.
    static func prepareIfNeeded() {
        guard isOn else { return }

        // Start from a clean slate every launch so each recording is identical:
        // no watch history, favourites, renames or cached guide from last time.
        let defaults = UserDefaults.standard
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        let folder = demoFolder()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // No donation prompt in the middle of a take.
        defaults.set(false, forKey: "showSupportPopup")

        // Playlist, logos and guide.
        var m3u = "#EXTM3U\n"
        var epg: [String: [EPGProgram]] = [:]
        var nameMap: [String: String] = [:]
        let now = Date()

        for (index, channel) in channels.enumerated() {
            let logoURL = folder.appendingPathComponent("logo_\(channel.id).png")
            if let png = renderLogo(for: channel).pngData() { try? png.write(to: logoURL) }

            m3u += "#EXTINF:-1 tvg-id=\"\(channel.id)\" tvg-name=\"\(channel.name)\" tvg-logo=\"\(logoURL.absoluteString)\" group-title=\"\(channel.group)\",\(channel.name)\n"
            m3u += channel.stream.rawValue + "\n"

            epg[channel.id] = schedule(for: channel, index: index, now: now, folder: folder)
            nameMap[channel.name.lowercased()] = channel.id
        }

        let playlistURL = folder.appendingPathComponent("demo.m3u")
        try? m3u.write(to: playlistURL, atomically: true, encoding: .utf8)

        // Seed the guide cache and mark it fresh, so the app never tries to
        // download a guide (there is no guide URL to download).
        EPGService().saveToDisk(epg: epg, map: nameMap)
        defaults.set(now.timeIntervalSince1970, forKey: "lastEPGUpdate")

        // Written straight to storage rather than through AccountManager, so
        // no "account added" reload fires and wipes the seeded guide.
        let account = Account(name: "Demo", type: .m3u, url: playlistURL.absoluteString,
                              username: nil, password: nil, isActive: true, stableID: 0)
        if let data = try? JSONEncoder().encode([account]) {
            defaults.set(data, forKey: "savedAccounts")
        }
        defaults.set(account.id.uuidString, forKey: "activeAccountID")
    }

    // MARK: - Line-up

    /// Open-licence test streams. Every film here is a Blender Foundation open
    /// movie (CC BY) or a published player test stream.
    enum Stream: String, CaseIterable {
        case bigBuckBunny = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
        case sintel       = "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8"
        case tearsOfSteel = "https://test-streams.mux.dev/tos_ismc/main.m3u8"
        case artOfMotion  = "https://bitdash-a.akamaihd.net/content/MI201109210084_1/m3u8s/f08e80da-bf1d-4e3d-8899-f0f6155f6efa.m3u8"
        case liveTest     = "https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8"
        case appleBipBop  = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"
    }

    struct Channel {
        let id: String
        let name: String
        let group: String
        let symbol: String
        let color: UIColor
        let stream: Stream
        let shows: [(title: String, blurb: String)]
    }

    static let channels: [Channel] = [
        // Sports
        Channel(id: "onside.sports1", name: "Onside Sports 1", group: "Sports", symbol: "sportscourt.fill",
                color: UIColor(red: 0.13, green: 0.62, blue: 0.36, alpha: 1), stream: .bigBuckBunny,
                shows: [("Matchday Live", "Every game, every goal, as it happens."),
                        ("The Pregame Show", "Team news, predictions and the big talking points."),
                        ("Highlights Tonight", "All of today's action in thirty minutes.")]),
        Channel(id: "onside.sports2", name: "Onside Sports 2", group: "Sports", symbol: "figure.run",
                color: UIColor(red: 0.95, green: 0.45, blue: 0.13, alpha: 1), stream: .sintel,
                shows: [("Track & Field Weekly", "The fastest times from meets around the world."),
                        ("Marathon Replay", "Every mile of Sunday's race."),
                        ("Training Ground", "Inside the sessions that win championships.")]),
        Channel(id: "racing.central", name: "Racing Central", group: "Sports", symbol: "flag.checkered",
                color: UIColor(red: 0.86, green: 0.16, blue: 0.2, alpha: 1), stream: .artOfMotion,
                shows: [("Grand Prix Qualifying", "Who takes pole? Every lap of the shootout."),
                        ("Pit Lane", "Strategy, tyres and team radio."),
                        ("Race Day Live", "Lights out and away we go.")]),
        Channel(id: "golf.weekend", name: "Golf Weekend", group: "Sports", symbol: "figure.golf",
                color: UIColor(red: 0.1, green: 0.55, blue: 0.55, alpha: 1), stream: .tearsOfSteel,
                shows: [("Final Round", "The leaders tee off on the back nine."),
                        ("Swing Clinic", "Fix your slice in ten minutes."),
                        ("Course Guide", "Hole by hole at this week's venue.")]),
        Channel(id: "fight.night", name: "Fight Night", group: "Sports", symbol: "figure.boxing",
                color: UIColor(red: 0.5, green: 0.25, blue: 0.85, alpha: 1), stream: .liveTest,
                shows: [("Main Card Live", "Five bouts, one title on the line."),
                        ("Weigh-In", "Face-offs ahead of Saturday."),
                        ("Classic Rounds", "The greatest fights, round by round.")]),

        // News
        Channel(id: "horizon.news", name: "Horizon News", group: "News", symbol: "globe.americas.fill",
                color: UIColor(red: 0.16, green: 0.42, blue: 0.9, alpha: 1), stream: .liveTest,
                shows: [("Horizon Tonight", "The day's headlines from around the world."),
                        ("Morning Briefing", "Everything you need to know before work."),
                        ("The Big Interview", "One guest, thirty minutes, no spin.")]),
        Channel(id: "metro.news24", name: "Metro News 24", group: "News", symbol: "building.2.fill",
                color: UIColor(red: 0.8, green: 0.13, blue: 0.2, alpha: 1), stream: .appleBipBop,
                shows: [("City Desk", "Local stories from across the metro area."),
                        ("Traffic & Weather", "Every ten minutes, on the tens."),
                        ("Evening Edition", "Tonight's top stories.")]),
        Channel(id: "world.report", name: "World Report", group: "News", symbol: "newspaper.fill",
                color: UIColor(red: 0.3, green: 0.3, blue: 0.75, alpha: 1), stream: .tearsOfSteel,
                shows: [("World Report", "Correspondents on five continents."),
                        ("Global Markets", "How the world's exchanges closed."),
                        ("Dispatches", "Long-form reporting from the field.")]),
        Channel(id: "market.watch", name: "Market Watch", group: "News", symbol: "chart.line.uptrend.xyaxis",
                color: UIColor(red: 0.12, green: 0.6, blue: 0.45, alpha: 1), stream: .artOfMotion,
                shows: [("Opening Bell", "The first hour of trading, live."),
                        ("Money Talk", "Your questions on saving and investing."),
                        ("Closing Numbers", "The day in markets.")]),

        // Movies
        Channel(id: "open.movies", name: "Open Movie Channel", group: "Movies", symbol: "film.fill",
                color: UIColor(red: 0.9, green: 0.62, blue: 0.1, alpha: 1), stream: .bigBuckBunny,
                shows: [("Big Buck Bunny", "A gentle giant rabbit takes on three bullies."),
                        ("Elephants Dream", "Two strangers explore an endless machine."),
                        ("Cosmos Laundromat", "A suicidal sheep meets a mysterious salesman.")]),
        Channel(id: "blender.cinema", name: "Blender Cinema", group: "Movies", symbol: "popcorn.fill",
                color: UIColor(red: 0.85, green: 0.25, blue: 0.35, alpha: 1), stream: .sintel,
                shows: [("Sintel", "A lone girl searches for the dragon she raised."),
                        ("Spring", "A shepherd girl and her dog face ancient spirits."),
                        ("Agent 327", "A secret agent goes undercover in a barbershop.")]),
        Channel(id: "short.film.club", name: "Short Film Club", group: "Movies", symbol: "movieclapper.fill",
                color: UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1), stream: .tearsOfSteel,
                shows: [("Tears of Steel", "Scientists fight robots to save the world."),
                        ("Caminandes", "A llama really wants to cross the road."),
                        ("Glass Half", "Two art critics, one gallery, no agreement.")]),
        Channel(id: "classic.frames", name: "Classic Frames", group: "Movies", symbol: "camera.fill",
                color: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1), stream: .artOfMotion,
                shows: [("Art of Motion", "Slow motion like you've never seen it."),
                        ("Frame by Frame", "How the classics were made."),
                        ("Late Show", "Tonight's feature presentation.")]),

        // Kids
        Channel(id: "cartoon.grove", name: "Cartoon Grove", group: "Kids", symbol: "face.smiling.fill",
                color: UIColor(red: 0.98, green: 0.75, blue: 0.1, alpha: 1), stream: .bigBuckBunny,
                shows: [("Meadow Friends", "Adventures in the big green meadow."),
                        ("Silly Songs", "Sing along with the whole grove."),
                        ("Bedtime Stories", "Winding down with a favourite tale.")]),
        Channel(id: "little.explorers", name: "Little Explorers", group: "Kids", symbol: "binoculars.fill",
                color: UIColor(red: 0.2, green: 0.7, blue: 0.85, alpha: 1), stream: .sintel,
                shows: [("Map Makers", "Where will the compass point today?"),
                        ("Bug Hunt", "Tiny creatures, big discoveries."),
                        ("Rainy Day Crafts", "Make something out of nothing.")]),
        Channel(id: "bunny.bay", name: "Bunny Bay", group: "Kids", symbol: "hare.fill",
                color: UIColor(red: 0.95, green: 0.45, blue: 0.65, alpha: 1), stream: .bigBuckBunny,
                shows: [("Hop to It", "The bunnies learn to share."),
                        ("Carrot Patch", "Growing the biggest carrot ever."),
                        ("Burrow Tales", "Stories from under the hill.")]),

        // Documentaries
        Channel(id: "wild.planet", name: "Wild Planet", group: "Documentaries", symbol: "pawprint.fill",
                color: UIColor(red: 0.35, green: 0.55, blue: 0.2, alpha: 1), stream: .artOfMotion,
                shows: [("Savanna", "One year on the plains of the Serengeti."),
                        ("Night Hunters", "What moves after dark."),
                        ("Frozen Worlds", "Life at the edge of the ice.")]),
        Channel(id: "deep.space", name: "Deep Space", group: "Documentaries", symbol: "sparkles",
                color: UIColor(red: 0.25, green: 0.2, blue: 0.6, alpha: 1), stream: .tearsOfSteel,
                shows: [("The Outer Planets", "A grand tour past Jupiter and beyond."),
                        ("Launch Window", "Countdown to the next mission."),
                        ("Star Stuff", "Where every atom in you came from.")]),
        Channel(id: "ocean.blue", name: "Ocean Blue", group: "Documentaries", symbol: "water.waves",
                color: UIColor(red: 0.05, green: 0.45, blue: 0.75, alpha: 1), stream: .sintel,
                shows: [("The Reef", "A city built by coral."),
                        ("Into the Deep", "Down to where the light runs out."),
                        ("Coastlines", "Where the land meets the sea.")]),

        // Lifestyle
        Channel(id: "kitchen.table", name: "Kitchen Table", group: "Lifestyle", symbol: "fork.knife",
                color: UIColor(red: 0.85, green: 0.4, blue: 0.2, alpha: 1), stream: .appleBipBop,
                shows: [("Weeknight Dinners", "Thirty minutes, one pan."),
                        ("Bake Off Basics", "Bread that actually rises."),
                        ("Street Food", "The best bites from night markets.")]),
        Channel(id: "wander.travel", name: "Wander Travel", group: "Lifestyle", symbol: "airplane",
                color: UIColor(red: 0.15, green: 0.6, blue: 0.7, alpha: 1), stream: .artOfMotion,
                shows: [("48 Hours In", "A whole city in one weekend."),
                        ("Off the Map", "Places the guidebooks skip."),
                        ("Rail Journeys", "The great train routes of the world.")]),
    ]

    // MARK: - Guide

    /// Twelve hours of programmes around `now`, staggered per channel so the
    /// progress bars on the home screen don't all sit at the same point.
    private static func schedule(for channel: Channel, index: Int, now: Date, folder: URL) -> [EPGProgram] {
        let slot: TimeInterval = 60 * 60
        // Offset the first start 10–50 minutes into the past.
        let offset = TimeInterval(10 + (index * 13) % 41) * 60
        var start = now.addingTimeInterval(-offset - slot)
        var programs: [EPGProgram] = []

        for i in 0..<12 {
            let show = channel.shows[i % channel.shows.count]
            let stillURL = folder.appendingPathComponent("still_\(channel.id)_\(i % channel.shows.count).png")
            if !FileManager.default.fileExists(atPath: stillURL.path),
               let png = renderStill(for: channel, title: show.title).pngData() {
                try? png.write(to: stillURL)
            }
            let stop = start.addingTimeInterval(slot)
            programs.append(EPGProgram(channelID: channel.id, title: show.title, description: show.blurb,
                                       start: start, stop: stop, image: stillURL.absoluteString))
            start = stop
        }
        return programs
    }

    // MARK: - Artwork

    private static func demoFolder() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DemoMode", isDirectory: true)
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        let image = UIImage(systemName: name, withConfiguration: config)
            ?? UIImage(systemName: "tv.fill", withConfiguration: config)!
        return image.withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    /// A badge in the channel's colour with a white glyph and wordmark, on a
    /// transparent background — reads like a real network logo on the cards.
    private static func renderLogo(for channel: Channel) -> UIImage {
        let size = CGSize(width: 600, height: 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let badge = CGRect(x: 20, y: 60, width: 180, height: 180)
            channel.color.setFill()
            UIBezierPath(roundedRect: badge, cornerRadius: 44).fill()

            let glyph = symbolImage(channel.symbol, pointSize: 96)
            let glyphRect = CGRect(x: badge.midX - glyph.size.width / 2,
                                   y: badge.midY - glyph.size.height / 2,
                                   width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)

            // "Onside" / "Sports 1": first word big, the rest underneath.
            let words = channel.name.split(separator: " ").map(String.init)
            let firstLine = words.first ?? channel.name
            let secondLine = words.dropFirst().joined(separator: " ")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let big: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 62, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: channel.color.withAlphaComponent(1).lighter(),
                .paragraphStyle: paragraph,
            ]
            (firstLine as NSString).draw(in: CGRect(x: 225, y: 72, width: 370, height: 80), withAttributes: big)
            (secondLine as NSString).draw(in: CGRect(x: 225, y: 152, width: 370, height: 70), withAttributes: small)
        }
    }

    /// A 16:9 programme still: the channel's colour as a diagonal gradient with
    /// its glyph large and faint, and the programme title set bottom-left.
    private static func renderStill(for channel: Channel, title: String) -> UIImage {
        let size = CGSize(width: 1280, height: 720)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [channel.color.cgColor, UIColor.black.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            let glyph = symbolImage(channel.symbol, pointSize: 420)
            glyph.draw(in: CGRect(x: size.width - glyph.size.width - 60,
                                  y: (size.height - glyph.size.height) / 2 - 40,
                                  width: glyph.size.width, height: glyph.size.height),
                       blendMode: .normal, alpha: 0.18)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 76, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            ]
            (title as NSString).draw(in: CGRect(x: 70, y: size.height - 200, width: size.width - 140, height: 100),
                                     withAttributes: attrs)
        }
    }
}

private extension UIColor {
    /// A lighter tint of the colour, for the wordmark's second line.
    func lighter() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s * 0.55, brightness: min(1, b + 0.35), alpha: a)
    }
}
