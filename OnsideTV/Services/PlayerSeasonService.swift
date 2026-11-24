import Foundation

/// One player's season, for the sheet a squad row opens: their totals for the
/// competition, the handful of numbers that matter for their sport and
/// position, and the app's own match rating for every game they played,
/// averaged.
///
/// ESPN has two endpoints for this. `overview` gives season totals split by
/// competition ("2026-27 English Premier League", "Regular Season"), and ESPN
/// already shapes them to the player: a keeper gets saves and clean sheets, a
/// cornerback tackles and interceptions. `gamelog` gives the same kind of line
/// for each game, which is what the rating engine scores a match from.
nonisolated enum PlayerSeasonService {

    struct Stat: Identifiable, Sendable {
        /// ESPN's stat name ("passingYards"), unique within a season.
        let id: String
        let label: String
        let title: String
        let value: String
    }

    struct Game: Identifiable, Sendable {
        let id: String
        let date: Date?
        let opponent: String
        let opponentLogo: String?
        /// "vs" or "@".
        let atVs: String
        /// "W", "L" or "D".
        let result: String
        let score: String
        let rating: Double?
    }

    struct Season: Sendable {
        /// The competition these numbers are for.
        let competition: String
        let stats: [Stat]
        /// The numbers that matter for this sport and position.
        let highlights: [Stat]
        /// Newest first.
        let games: [Game]
        let averageRating: Double?
        let ratedGames: Int
    }

    static func fetch(sport: SportType, leagueLabel: String?, playerID: String, position: String?) async -> Season? {
        guard let path = LeagueDetailService.apiPath(sport: sport, leagueLabel: leagueLabel) else { return nil }
        let base = "https://site.web.api.espn.com/apis/common/v3/sports/\(path)/athletes/\(playerID)"
        async let overviewJSON = json(base + "/overview")
        async let gamelogJSON = json(base + "/gamelog")
        let (overview, gamelog) = await (overviewJSON, gamelogJSON)
        guard overview != nil || gamelog != nil else { return nil }

        let pos = (position ?? "").uppercased()
        let season = seasonStats(overview, sport: sport, leagueLabel: leagueLabel)
        let games = ratedGames(gamelog, sport: sport, leagueLabel: leagueLabel, position: pos)
        let ratings = games.compactMap(\.rating)
        let average = ratings.isEmpty ? nil
            : PlayerRatingEngine.clampRating(ratings.reduce(0, +) / Double(ratings.count))

        return Season(
            competition: season.competition ?? "This season",
            stats: season.stats,
            highlights: highlights(from: season.stats, sport: sport, position: pos),
            games: games,
            averageRating: average,
            ratedGames: ratings.count
        )
    }

    private static func json(_ string: String) async -> [String: Any]? {
        guard let url = URL(string: string),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] == nil
        else { return nil }
        return object
    }

    // MARK: Season totals

    /// Splits that are never "the season": a projection, a career total, a
    /// rolling window.
    private static let notASeason = ["projected", "career", "last 5"]

    private static func seasonStats(_ overview: [String: Any]?, sport: SportType, leagueLabel: String?)
        -> (competition: String?, stats: [Stat]) {
        guard let block = overview?["statistics"] as? [String: Any],
              let names = block["names"] as? [String],
              let splits = block["splits"] as? [[String: Any]], !splits.isEmpty
        else { return (nil, []) }
        let labels = block["labels"] as? [String] ?? names
        let titles = block["displayNames"] as? [String] ?? labels

        func title(of split: [String: Any]) -> String { split["displayName"] as? String ?? "" }
        let seasons = splits.filter { split in
            let t = title(of: split).lowercased()
            return !notASeason.contains { t.contains($0) }
        }
        // A footballer's splits are one per competition; the team page's own
        // league is the one that matters. Elsewhere it's the regular season.
        let chosen: [String: Any]? = {
            if sport.isSoccer, let league = leagueLabel, !league.isEmpty,
               let match = seasons.first(where: { sameCompetition(title(of: $0), league) }) {
                return match
            }
            if let regular = seasons.first(where: { title(of: $0).lowercased() == "regular season" }) {
                return regular
            }
            return seasons.first ?? splits.first
        }()
        guard let chosen, let values = chosen["stats"] as? [String] else { return (nil, []) }

        var stats: [Stat] = []
        var seen = Set<String>()
        for (i, name) in names.enumerated() where i < values.count && seen.insert(name).inserted {
            stats.append(Stat(id: name,
                              label: i < labels.count ? labels[i] : name,
                              title: i < titles.count ? titles[i] : name,
                              value: values[i]))
        }
        return (title(of: chosen), stats)
    }

    /// Whether ESPN's competition title is the app's league: "2026-27
    /// English Premier League" is the Premier League. Spaces are ignored,
    /// because ESPN writes La Liga as "LALIGA".
    private static func sameCompetition(_ title: String, _ league: String) -> Bool {
        func squash(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        return squash(title).contains(squash(league))
    }

    // MARK: Headline numbers

    /// What to lead with, best first, by sport and position. Names are ESPN's;
    /// whatever isn't in this player's line is skipped.
    static func highlightNames(sport: SportType, position pos: String) -> [String] {
        if sport.isSoccer {
            switch pos {
            case "G", "GK": return ["saves", "cleanSheet", "goalsConceded", "starts"]
            case "D": return ["starts", "totalGoals", "goalAssists", "foulsCommitted", "yellowCards"]
            case "M": return ["starts", "totalGoals", "goalAssists", "totalShots", "shotsOnTarget"]
            default: return ["totalGoals", "goalAssists", "shotsOnTarget", "totalShots", "starts"]
            }
        }
        switch sport {
        case .nfl, .cfb:
            switch pos {
            case "QB":
                return ["passingYards", "passingTouchdowns", "interceptions", "completionPct", "QBRating", "rushingYards"]
            case "RB", "FB":
                return ["rushingYards", "rushingTouchdowns", "yardsPerRushAttempt", "receptions", "receivingYards"]
            case "WR", "TE":
                return ["receptions", "receivingYards", "receivingTouchdowns", "yardsPerReception", "receivingTargets"]
            case "K", "PK":
                return ["fieldGoalsMade", "fieldGoalPct", "longFieldGoalMade", "extraPointsMade", "totalKickingPoints"]
            case "P":
                return ["punts", "grossAvgPuntYards", "netAvgPuntYards", "puntsInside20", "longPunt"]
            default:
                return ["totalTackles", "sacks", "interceptions", "passesDefended", "fumblesForced", "stuffs"]
            }
        case .nba, .wnba, .cbb:
            switch pos {
            case "C", "PF", "F-C", "C-F":
                return ["avgPoints", "avgRebounds", "avgBlocks", "fieldGoalPct", "avgMinutes"]
            case "G", "PG", "SG", "G-F":
                return ["avgPoints", "avgAssists", "threePointPct", "avgSteals", "avgMinutes"]
            default:
                return ["avgPoints", "avgRebounds", "avgAssists", "fieldGoalPct", "avgMinutes"]
            }
        case .nhl, .collegeHockey:
            switch pos {
            case "G": return ["wins", "savePct", "avgGoalsAgainst", "shutouts", "saves"]
            case "D": return ["points", "assists", "plusMinus", "timeOnIcePerGame", "shotsTotal"]
            default: return ["goals", "assists", "points", "plusMinus", "shotsTotal"]
            }
        case .mlb, .softball:
            if isPitcher(pos) {
                return ["ERA", "wins", "strikeouts", "WHIP", "innings", "saves"]
            }
            return ["avg", "homeRuns", "RBIs", "OPS", "hits", "stolenBases"]
        default:
            return []
        }
    }

    private static func highlights(from stats: [Stat], sport: SportType, position: String) -> [Stat] {
        var picked: [Stat] = []
        for name in highlightNames(sport: sport, position: position) {
            if let stat = stats.first(where: { $0.id.caseInsensitiveCompare(name) == .orderedSame }) {
                picked.append(stat)
            }
        }
        // A position the lists don't know, or a line with few of their
        // numbers: lead with ESPN's own order instead of showing nothing.
        if picked.count < 3 {
            for stat in stats where !picked.contains(where: { $0.id == stat.id }) {
                picked.append(stat)
                if picked.count >= 4 { break }
            }
        }
        return Array(picked.prefix(6))
    }

    private static func isPitcher(_ pos: String) -> Bool {
        ["P", "SP", "RP", "CP"].contains(pos)
    }

    // MARK: Game by game

    private static func ratedGames(_ gamelog: [String: Any]?, sport: SportType, leagueLabel: String?, position: String) -> [Game] {
        guard let log = gamelog,
              let names = log["names"] as? [String],
              let seasonTypes = log["seasonTypes"] as? [[String: Any]], !seasonTypes.isEmpty
        else { return [] }
        let labels = log["labels"] as? [String] ?? names
        let events = log["events"] as? [String: Any] ?? [:]
        let groups: [(name: String, count: Int)] = (log["categories"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String, let count = $0["count"] as? Int else { return nil }
            return (name, count)
        }

        // Same competition as the season totals, for a footballer.
        let seasonType: [String: Any] = {
            if sport.isSoccer, let league = leagueLabel, !league.isEmpty,
               let match = seasonTypes.first(where: {
                   sameCompetition($0["displayName"] as? String ?? "", league)
               }) {
                return match
            }
            return seasonTypes[0]
        }()

        var rows: [(eventID: String, values: [String])] = []
        for category in seasonType["categories"] as? [[String: Any]] ?? [] {
            for entry in category["events"] as? [[String: Any]] ?? [] {
                guard let id = entry["eventId"] as? String, let values = entry["stats"] as? [String] else { continue }
                rows.append((id, values))
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var games: [Game] = []
        var seen = Set<String>()
        for row in rows where seen.insert(row.eventID).inserted {
            let event = events[row.eventID] as? [String: Any] ?? [:]
            let dateString = event["gameDate"] as? String ?? ""
            let opponent = event["opponent"] as? [String: Any] ?? [:]
            games.append(Game(
                id: row.eventID,
                date: iso.date(from: dateString) ?? isoPlain.date(from: dateString),
                opponent: opponent["abbreviation"] as? String ?? opponent["displayName"] as? String ?? "",
                opponentLogo: opponent["logo"] as? String,
                atVs: event["atVs"] as? String ?? "",
                result: event["gameResult"] as? String ?? "",
                score: event["score"] as? String ?? "",
                rating: rating(sport: sport, position: position, names: names, labels: labels,
                               groups: groups, values: row.values)
            ))
        }
        return games.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The app's match rating for one game line, through the same engine the
    /// game cards use. The log's names and labels differ from a box score's
    /// in a few places, translated here.
    static func rating(sport: SportType, position: String, names: [String], labels: [String],
                       groups: [(name: String, count: Int)], values: [String]) -> Double? {
        if sport.isSoccer {
            let abbreviation: [String: String] = [
                "totalGoals": "G", "goalAssists": "A", "totalShots": "SHOT", "shotsOnTarget": "SOG",
                "foulsCommitted": "FC", "foulsSuffered": "FA", "offsides": "OF", "yellowCards": "YC",
                "redCards": "RC", "saves": "SV", "goalsConceded": "GA", "ownGoals": "OG"
            ]
            // A row in the log is an appearance.
            var stats = [GSPlayerStat(name: nil, abbreviation: "APP", displayValue: "1", value: 1)]
            for (i, name) in names.enumerated() where i < values.count {
                guard let key = abbreviation[name] else { continue }
                stats.append(GSPlayerStat(name: name, abbreviation: key, displayValue: values[i],
                                          value: Double(values[i]) ?? 0))
            }
            return PlayerRatingEngine.soccerRating(stats: stats, isGoalkeeper: position == "G" || position == "GK")
        }

        // Split the line into the box score's groups.
        var split: [(group: String, columns: [String: String])] = []
        if !groups.isEmpty {
            var start = 0
            for group in groups {
                let end = min(start + group.count, values.count, labels.count)
                guard start < end else { break }
                var columns: [String: String] = [:]
                for i in start..<end { columns[labels[i]] = values[i] }
                // The log files a defender's line under "tackles"; the engine
                // reads it as "defensive".
                let name = group.name == "tackles" ? "defensive" : group.name
                split.append((name, columns))
                start = end
            }
        } else {
            var columns: [String: String] = [:]
            for (i, label) in labels.enumerated() where i < values.count { columns[label] = values[i] }
            let name: String
            switch sport {
            case .mlb, .softball: name = isPitcher(position) ? "pitching" : "batting"
            case .nhl, .collegeHockey: name = names.contains("saves") ? "goalies" : "skaters"
            default: name = "stats"
            }
            split.append((name, columns))
        }

        for i in split.indices {
            var c = split[i].columns
            if let v = c["SACK"], c["SACKS"] == nil { c["SACKS"] = v }
            if let v = c["LST"], c["LOST"] == nil { c["LOST"] = v }
            if let v = c["TOI/G"], c["TOI"] == nil { c["TOI"] = v }
            if sport == .nhl || sport == .collegeHockey, let v = c["S"], c["SOG"] == nil { c["SOG"] = v }
            // The log has total rebounds only; split at the league's usual
            // quarter offensive, three quarters defensive.
            if let reb = c["REB"], c["OREB"] == nil, let total = Double(reb) {
                c["OREB"] = String(total * 0.25)
                c["DREB"] = String(total * 0.75)
            }
            split[i].columns = c
        }
        return PlayerRatingEngine.boxScoreRating(sport: sport, groups: split)
    }
}
