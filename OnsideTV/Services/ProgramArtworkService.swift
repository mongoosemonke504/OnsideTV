import Foundation

/// Finds a photograph for a programme the guide gave us no still for.
///
/// TMDB was the obvious candidate and it's the wrong shape for live TV: it
/// catalogues films and scripted series, so a news hour, a golf major or a
/// regional sports show returns nothing. These two are keyless, and between
/// them they cover what actually runs on a live channel:
///
///   • **TVmaze** — a TV database with proper show posters. Strong on series
///     and returning shows, including news and talk formats. Its full result
///     list is searched, and a show is used only when its name IS the
///     programme's title: same words, ignoring case, accents and punctuation.
///     This used to ask `singlesearch`, which always answers with its best
///     fuzzy guess, and a station's "Sign Off" came back as a game show called
///     "Sing Your Face Off".
///   • **Wikipedia** — for what TVmaze doesn't list, films especially. The
///     summary endpoint only follows an exact title or a redirect an editor
///     made, and the article is used only when it's about a TV programme or a
///     film. "Sign Off" is a real article, about station closedowns. Those
///     redirects also give a show's full name, "SNL" → "Saturday Night Live",
///     which is then looked up on TVmaze, exactly, for its poster.
///
/// Placeholder guide entries ("Sign Off", "Paid Programming", "To Be
/// Announced") are never looked up at all.
///
/// A show that's still going wears its latest season's poster, not whatever it
/// was first listed with.
///
/// Answers are cached on disk, but not forever: a poster is checked again
/// after a week and a miss after a day. A lookup that FAILED (no connection,
/// TVmaze's rate limit) isn't cached at all. Caching those as misses is what
/// left some channels without artwork for good.
actor ProgramArtworkService {
    static let shared = ProgramArtworkService()

    private nonisolated struct Entry: Codable, Sendable {
        let url: String?
        let checked: Date
    }

    private nonisolated enum Lookup: Sendable {
        case found(String)
        /// Looked, and nothing matches exactly.
        case none
        /// Couldn't look: offline, rate-limited, a server error. Not cached.
        case failed
    }

    private static let hitLifetime: TimeInterval = 7 * 24 * 60 * 60
    private static let missLifetime: TimeInterval = 24 * 60 * 60
    /// Entries this old are dropped on load, so the file doesn't grow forever.
    private static let pruneAge: TimeInterval = 30 * 24 * 60 * 60

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]
    private var loaded = false

    /// TVmaze allows 20 requests every 10 seconds from one address, and a home
    /// screen asks for a dozen titles at once. Fired together, some were
    /// refused and those channels went without, so requests queue for a slot.
    private var nextTVmazeSlot = Date.distantPast
    private static let tvmazeSpacing: TimeInterval = 0.55

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("program-artwork-v2.json")
    }()
    /// The first version's cache: fuzzy matches, kept forever. Thrown away.
    private static let legacyCacheURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("program-artwork.json")
    }()

    /// Artwork for a programme title, or nil when nothing matches it exactly.
    func artwork(for rawTitle: String) async -> String? {
        loadIfNeeded()
        let title = Self.normalise(rawTitle)
        let key = Self.matchKey(title)
        guard key.count >= 2, !Self.isPlaceholder(key) else { return nil }

        let cached = cache[key]
        if let cached, Self.isFresh(cached) { return cached.url }

        let task: Task<Lookup, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { await Self.lookup(title, pacer: self) }
            inFlight[key] = task
        }
        let result = await task.value
        inFlight[key] = nil

        switch result {
        case .found(let url):
            store(url, for: key)
            return url
        case .none:
            store(nil, for: key)
            return nil
        case .failed:
            // Whatever was known before still stands (a week-old poster beats
            // none), and the title is tried again next time it's on screen.
            return cached?.url
        }
    }

    // MARK: Looking up

    private nonisolated static func lookup(_ title: String, pacer: ProgramArtworkService) async -> Lookup {
        let names = candidates(for: title)
        for name in names {
            switch await lookupTVmaze(name, pacer: pacer) {
            case .found(let url): return .found(url)
            // TVmaze couldn't be asked. Better to try again later than settle
            // for Wikipedia's answer and keep it for a week.
            case .failed: return .failed
            case .none: continue
            }
        }
        var failed = false
        for name in names {
            switch await lookupWikipedia(name) {
            case .failed:
                failed = true
            case .none:
                continue
            case .article(let alias, let image):
                // An editor's redirect gives the show's full name, "Law & Order:
                // SVU" → "Law & Order: Special Victims Unit", and TVmaze may
                // know it by that name when it didn't by the guide's. Its
                // poster beats the article's picture, which is often a logo.
                if let alias {
                    switch await lookupTVmaze(alias, pacer: pacer) {
                    case .found(let url): return .found(url)
                    case .failed: return .failed
                    case .none: break
                    }
                }
                if let image { return .found(image) }
            }
        }
        return failed ? .failed : .none
    }

    private nonisolated static func lookupTVmaze(_ title: String, pacer: ProgramArtworkService) async -> Lookup {
        // TVmaze's search finds nothing for "Late Show w/ Stephen Colbert"
        // and the show for "…with Stephen Colbert".
        let spelled = title.replacingOccurrences(of: "\\bw/\\s*", with: "with ",
                                                 options: [.regularExpression, .caseInsensitive])
        guard let query = spelled.addingPercentEncoding(withAllowedCharacters: queryValueAllowed),
              let url = URL(string: "https://api.tvmaze.com/search/shows?q=\(query)")
        else { return .none }
        let data: Data
        switch await tvmazeGET(url, pacer: pacer) {
        case .ok(let body): data = body
        case .notFound: return .none
        case .failed: return .failed
        }
        guard let results = try? JSONDecoder().decode([TVmazeResult].self, from: data) else { return .failed }

        let wanted = matchKey(title)
        // Several shows can share a name, like the American and Australian
        // "Survivor". The one still on the air wins, then the more watched.
        guard let show = results.map(\.show)
            .filter({ matchKey(normalise($0.name)) == wanted })
            .max(by: { rank($0) < rank($1) })
        else { return .none }

        // A finished show's main poster is its last word; only one that's
        // still going can have a newer season poster worth the extra request.
        if show.status == "Running",
           let seasonsURL = URL(string: "https://api.tvmaze.com/shows/\(show.id)/seasons"),
           case .ok(let body) = await tvmazeGET(seasonsURL, pacer: pacer),
           let seasons = try? JSONDecoder().decode([TVmazeSeason].self, from: body),
           let poster = latestSeasonPoster(seasons) {
            return .found(poster)
        }
        if let poster = show.image?.original ?? show.image?.medium { return .found(poster) }
        return .none
    }

    private nonisolated enum Fetch: Sendable { case ok(Data), notFound, failed }

    /// One GET in its turn, retried when TVmaze asks us to slow down.
    private nonisolated static func tvmazeGET(_ url: URL, pacer: ProgramArtworkService) async -> Fetch {
        for attempt in 0..<3 {
            let wait = await pacer.reserveTVmazeSlot()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { return .failed }
            switch status {
            case 200: return .ok(data)
            case 404: return .notFound
            case 429:
                // Holds every queued request back, not just this one.
                await pacer.holdTVmaze(for: 2 * Double(attempt + 1))
            default:
                return .failed
            }
        }
        return .failed
    }

    private func reserveTVmazeSlot() -> TimeInterval {
        let now = Date()
        let slot = max(now, nextTVmazeSlot)
        nextTVmazeSlot = slot.addingTimeInterval(Self.tvmazeSpacing)
        return slot.timeIntervalSince(now)
    }

    private func holdTVmaze(for seconds: TimeInterval) {
        nextTVmazeSlot = max(nextTVmazeSlot, Date().addingTimeInterval(seconds))
    }

    private nonisolated enum WikiResult: Sendable {
        /// A TV programme's or film's article. `alias` is the full name when
        /// an editor's redirect led to a TV programme under another title.
        case article(alias: String?, image: String?)
        case none
        case failed
    }

    private nonisolated static func lookupWikipedia(_ title: String) async -> WikiResult {
        // Guide titles are often in capitals, and Wikipedia's titles are
        // case-sensitive after the first letter.
        let page = title.rangeOfCharacter(from: .lowercaseLetters) == nil ? title.capitalized : title
        var failed = false
        // The "(TV series)" article first: when it exists it's the show by that
        // exact name, even where the plain title is about something else.
        for name in ["\(page) (TV series)", page] {
            guard let escaped = name.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed),
                  let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(escaped)?redirect=true")
            else { continue }
            var request = URLRequest(url: url)
            // Wikimedia asks API clients to identify themselves.
            request.setValue("OnsideTV/3.0 (https://github.com/mongoosemonke504/OnsideTV)",
                             forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode
            else { failed = true; continue }
            guard status == 200 else {
                if status != 404 { failed = true }
                continue
            }
            guard let summary = try? JSONDecoder().decode(WikiSummary.self, from: data),
                  summary.type != "disambiguation",
                  let kind = screenWork(summary.description)
            else { continue }
            let image = summary.originalimage?.source ?? summary.thumbnail?.source
            // Worth asking TVmaze by the article's name only for a TV
            // programme whose title is plain and different. One carrying a
            // disambiguator, "Survivor (Australian TV series)", would lose it
            // and come back as the wrong country's show.
            let canonical = (summary.title ?? "").replacingOccurrences(of: "_", with: " ")
            let plain = normalise(canonical) == canonical.trimmingCharacters(in: .whitespaces)
            let alias = kind == .tv && plain && !canonical.isEmpty
                && matchKey(canonical) != matchKey(title) ? canonical : nil
            guard alias != nil || image != nil else { continue }
            return .article(alias: alias, image: image)
        }
        return failed ? .failed : .none
    }

    // MARK: Matching

    /// Strips the decoration guide titles carry, like "(NEW)", "[HD]",
    /// "LIVE: …", "Movie: …" and "S02E05", so what's left is the show's name.
    nonisolated static func normalise(_ title: String) -> String {
        var t = title
        let decorations = [
            "\\([^)]*\\)",
            "\\[[^\\]]*\\]",
            // A label in front. Needs its colon or dash: "Live with Kelly and
            // Mark" is a show, "LIVE: NFL Football" is a label.
            "^\\s*(live|new|premiere|season premiere|series premiere|new episode|all new|encore|replay|rerun|movie|film|feature film)\\s*[:\\-–—|]\\s*",
            // Episode numbering, and whatever follows it.
            "\\s*\\bS\\d{1,2}\\s*E\\d{1,3}\\b.*$",
            "\\s*[-–—:|,]\\s*Season\\s+\\d+\\b.*$",
            "\\s*\\b(Episode|Ep\\.)\\s*\\d+\\b.*$",
        ]
        for pattern in decorations {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:|,")))
    }

    /// A title reduced to what has to match: lower case, no accents, no
    /// punctuation, "&" read as "and", "w/" as "with", no leading "The".
    nonisolated static func matchKey(_ title: String) -> String {
        var t = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                              locale: Locale(identifier: "en_US_POSIX"))
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "\\bw/", with: "with ", options: .regularExpression)
        t = t.replacingOccurrences(of: "['’‘`]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return t
    }

    /// The title, then the show's name alone when the guide has run an episode
    /// title onto it with a dash: "Friends - The One Where…". Not a colon.
    /// "Law & Order: SVU" cut there is a different show.
    nonisolated static func candidates(for title: String) -> [String] {
        var names = [title]
        let cut = [" - ", " – ", " — ", " | "]
            .compactMap { title.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let cut {
            let show = title[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
            let key = matchKey(show)
            if key.count >= 3, !isPlaceholder(key) { names.append(show) }
        }
        return names
    }

    /// Guide filler that names no programme. Matched against `matchKey`.
    private nonisolated static let placeholders: Set<String> = [
        "sign off", "signoff", "sign on", "off air", "off the air", "close down", "closedown",
        "station closed", "end of transmission", "end of broadcast", "test card", "test pattern",
        "paid programming", "paid program", "paid programme", "infomercial", "infomercials",
        "to be announced", "tba", "tbd", "to be determined", "no information",
        "no information available", "no program information", "no programme information",
        "no epg", "no epg data", "no data", "not available", "unknown", "n a",
        "programming", "local programming", "regional programming", "network programming",
        "various", "various programs", "various programmes", "overnight programming",
        "station id", "intermission", "break", "commercial break", "coming up", "up next",
        "movie", "movies", "film", "feature film", "news", "local news", "weather", "sports",
        "program", "programme", "show", "series", "special", "live", "encore", "replay",
        "highlights", "channel info", "info",
    ]

    nonisolated static func isPlaceholder(_ key: String) -> Bool {
        placeholders.contains(key)
    }

    nonisolated enum ScreenWork: Sendable { case tv, film }

    /// What a Wikipedia short description says the article is: a TV programme
    /// ("American television sitcom"), a film ("1999 film by the Wachowskis"),
    /// or nil for a channel, a person or anything else that shares the name.
    nonisolated static func screenWork(_ description: String?) -> ScreenWork? {
        guard let d = description?.lowercased(), !d.isEmpty else { return nil }
        let elsewhere = ["channel", "network", "station", "broadcaster", "company", "studio",
                         "actor", "actress", "presenter", "journalist", "director", "producer",
                         "filmmaker", "screenwriter", "(born", "character", "festival", "award",
                         "genre", "album", "song", "novel", "book", "video game"]
        if elsewhere.contains(where: d.contains) { return nil }
        let tv = ["television", "tv series", "tv program", "tv show", "talk show", "game show",
                  "sitcom", "soap opera", "news program", "miniseries", "docuseries"]
        if tv.contains(where: d.contains) { return .tv }
        return d.contains("film") ? .film : nil
    }

    /// Still on the air first, then the more watched, then the newer.
    private nonisolated static func rank(_ show: TVmazeShow) -> (Int, Int, String) {
        (show.status == "Running" ? 1 : 0, show.weight ?? 0, show.premiered ?? "")
    }

    /// The newest season that has started and has a poster: this year's
    /// artwork for a show that's still going.
    private nonisolated static func latestSeasonPoster(_ seasons: [TVmazeSeason]) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return seasons
            .filter { ($0.premiereDate ?? "9999-12-31") <= today && $0.image != nil }
            .max { ($0.number ?? 0) < ($1.number ?? 0) }
            .flatMap { $0.image?.original ?? $0.image?.medium }
    }

    /// For a query value: "&", "+" and "=" escaped, or "Law & Order" goes out
    /// as a search for "Law ".
    private nonisolated static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()

    /// For one path segment: "/" escaped, or "20/20" becomes two segments.
    private nonisolated static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()

    // MARK: Disk cache

    private static func isFresh(_ entry: Entry) -> Bool {
        let age = Date().timeIntervalSince(entry.checked)
        return age < (entry.url == nil ? missLifetime : hitLifetime)
    }

    private func store(_ url: String?, for key: String) {
        cache[key] = Entry(url: url, checked: Date())
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.removeItem(at: Self.legacyCacheURL)
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.pruneAge)
        cache = stored.filter { $0.value.checked > cutoff }
    }

    private func persist() {
        let snapshot = cache
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    // MARK: Wire models

    private nonisolated struct TVmazeResult: Decodable, Sendable {
        let show: TVmazeShow
    }

    private nonisolated struct TVmazeShow: Decodable, Sendable {
        let id: Int
        let name: String
        let status: String?
        let premiered: String?
        let weight: Int?
        let image: TVmazeImage?
    }

    private nonisolated struct TVmazeSeason: Decodable, Sendable {
        let number: Int?
        let premiereDate: String?
        let image: TVmazeImage?
    }

    private nonisolated struct TVmazeImage: Decodable, Sendable {
        let medium: String?
        let original: String?
    }

    private nonisolated struct WikiSummary: Decodable, Sendable {
        nonisolated struct Image: Decodable, Sendable { let source: String? }
        let title: String?
        let type: String?
        let description: String?
        let originalimage: Image?
        let thumbnail: Image?
    }
}
