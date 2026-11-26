import Foundation

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    let channelName: String
    let channelIcon: String?
    /// Saved with the login swapped for placeholders (see `RecordingLogin`);
    /// `RecordingManager.playableURL(for:)` puts it back when it's needed.
    var streamURL: String
    var hasArchive: Bool = false
    let startTime: Date
    let endTime: Date
    let createdAt: Date

    var programTitle: String? = nil
    var programDescription: String? = nil
    var customTitle: String? = nil

    var status: RecordingStatus
    var localFileName: String?
    var category: RecordingCategory = .other

    /// Actual recorded length in seconds, captured when the recording finishes
    /// (and refined from the remuxed MP4's real duration). Nil for legacy or
    /// still-in-progress recordings. A recording stopped early captures far
    /// less than its scheduled window, so using `endTime − startTime` there
    /// overstated the duration and let the scrubber seek past the end of the
    /// file — which hung the player. This value is the seekable truth.
    var recordedDuration: TimeInterval? = nil

    /// The playlist the channel came from, to fill the login back in.
    var accountID: UUID? = nil

    // MARK: - Computed

    var duration: TimeInterval {
        if let recorded = recordedDuration, recorded > 0 { return recorded }
        return endTime.timeIntervalSince(startTime)
    }

    var displayName: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        if let title = programTitle, !title.isEmpty { return title }
        return channelName
    }

    /// Reads the actual file size from disk (metadata only — fast).
    var fileSizeBytes: Int64 {
        guard let filename = localFileName else { return 0 }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(filename)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Enums

    enum RecordingStatus: String, Codable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }

    enum RecordingCategory: String, Codable, CaseIterable, Hashable {
        case sports
        case movies
        case tvShows
        case other

        var displayName: String {
            switch self {
            case .sports:  return "Sports"
            case .movies:  return "Movies"
            case .tvShows: return "TV"
            case .other:   return "Other"
            }
        }
    }
}

extension Recording.RecordingCategory {
    /// Best-guess category for a recording, pre-selected in the setup sheet
    /// (the user can still override). Program title wins when it clearly
    /// reads as a matchup; otherwise the channel's category (and finally its
    /// name) run through the home screen's genre classifier.
    static func guess(channel: StreamChannel, category: StreamCategory?, program: EPGProgram?) -> Recording.RecordingCategory {
        let title = (program?.title ?? "").lowercased()
        let sportsHints = [
            " vs ", " vs. ", " v ", " @ ", "matchday", "match day",
            "nba", "nfl", "mlb", "nhl", "ufc", "wwe", "boxing",
            "premier league", "champions league", "la liga", "serie a",
            "bundesliga", "grand prix", "motogp", "nascar", "postgame", "pregame"
        ]
        if sportsHints.contains(where: { title.contains($0) }) { return .sports }

        func map(_ group: HomeCategoryGroup) -> Recording.RecordingCategory? {
            switch group {
            case .sports: return .sports
            case .movies: return .movies
            case .news, .kids, .documentary, .lifestyle: return .tvShows
            case .international, .other: return nil
            }
        }

        if let category, let mapped = map(HomeCategoryGroup.classify(category)) {
            return mapped
        }
        // No usable category — classify the channel NAME the same way.
        let nameOnly = StreamCategory(id: -1, name: channel.name)
        return map(HomeCategoryGroup.classify(nameOnly)) ?? .other
    }
}

/// Saved recordings used to keep each channel's full stream address, which
/// for most providers has the username and password in it. They're stored
/// with placeholders instead, and filled in from the account when used.
nonisolated enum RecordingLogin {
    static let userToken = "__onside_user__"
    static let passToken = "__onside_pass__"

    /// The address with any path segment or query value that is exactly the
    /// username or password replaced by a placeholder.
    static func mask(_ address: String, user: String?, pass: String?) -> String {
        let user = user ?? "", pass = pass ?? ""
        guard !pass.isEmpty || !user.isEmpty, var parts = URLComponents(string: address) else { return address }
        func token(for value: String) -> String? {
            let plain = value.removingPercentEncoding ?? value
            if !pass.isEmpty && plain == pass { return passToken }
            if !user.isEmpty && plain == user { return userToken }
            return nil
        }
        let segments = parts.percentEncodedPath.components(separatedBy: "/")
        parts.percentEncodedPath = segments.map { token(for: $0) ?? $0 }.joined(separator: "/")
        if let items = parts.percentEncodedQueryItems {
            parts.percentEncodedQueryItems = items.map { item in
                guard let value = item.value, let t = token(for: value) else { return item }
                return URLQueryItem(name: item.name, value: t)
            }
        }
        return parts.string ?? address
    }

    static func isMasked(_ address: String) -> Bool {
        address.contains(userToken) || address.contains(passToken)
    }

    /// Puts the login back. Nil when it's needed and there isn't one.
    static func fill(_ address: String, user: String?, pass: String?) -> String? {
        guard isMasked(address) else { return address }
        guard var parts = URLComponents(string: address) else { return nil }
        let user = user ?? "", pass = pass ?? ""
        if address.contains(userToken) && user.isEmpty { return nil }
        if address.contains(passToken) && pass.isEmpty { return nil }
        let segments = parts.percentEncodedPath.components(separatedBy: "/")
        parts.percentEncodedPath = segments.map { segment in
            if segment == userToken { return ChannelViewModel.pathSegment(user) }
            if segment == passToken { return ChannelViewModel.pathSegment(pass) }
            return segment
        }.joined(separator: "/")
        let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
        if let items = parts.percentEncodedQueryItems {
            parts.percentEncodedQueryItems = items.map { item in
                if item.value == userToken { return URLQueryItem(name: item.name, value: user.addingPercentEncoding(withAllowedCharacters: queryValue)) }
                if item.value == passToken { return URLQueryItem(name: item.name, value: pass.addingPercentEncoding(withAllowedCharacters: queryValue)) }
                return item
            }
        }
        return parts.string
    }
}
