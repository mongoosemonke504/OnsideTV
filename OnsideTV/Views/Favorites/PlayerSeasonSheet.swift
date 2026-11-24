import SwiftUI

/// What a squad row opens: the player's season. Their average app rating
/// across the games they've played, the numbers that matter for their sport
/// and position, each recent game with its rating, and the full season line.
struct PlayerSeasonSheet: View {
    let player: TeamDetailService.Player
    let photo: String
    let teamName: String
    let sport: SportType
    let leagueLabel: String?

    @State private var season: PlayerSeasonService.Season?
    @State private var loading = true

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                header

                if loading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let season {
                    ratingCard(season)
                    if !season.highlights.isEmpty { highlightGrid(season.highlights) }
                    if !season.games.isEmpty { recentGames(season.games) }
                    if !season.stats.isEmpty { allStats(season) }
                } else {
                    Text("No stats for this player yet.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: player.id) {
            loading = true
            season = await PlayerSeasonService.fetch(sport: sport, leagueLabel: leagueLabel,
                                                     playerID: player.id, position: player.position)
            loading = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color(white: 0.15))
                if photo.isEmpty {
                    Text(initials)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    CachedAsyncImage(urlString: photo,
                                     size: CGSize(width: 68, height: 68),
                                     contentMode: .fill,
                                     decodeSize: CGSize(width: 204, height: 204))
                        .clipShape(Circle())
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(player.name)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var initials: String {
        player.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let jersey = player.jersey, !jersey.isEmpty { parts.append("#\(jersey)") }
        if let position = player.position, !position.isEmpty { parts.append(position) }
        parts.append(teamName)
        return parts.joined(separator: " · ")
    }

    // MARK: Rating

    private func ratingCard(_ season: PlayerSeasonService.Season) -> some View {
        HStack(spacing: 16) {
            Text(season.averageRating.map { String(format: "%.1f", $0) } ?? "–")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 84, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ratingColor(season.averageRating))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text("Average rating")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(season.ratedGames > 0
                     ? "From \(season.ratedGames) game\(season.ratedGames == 1 ? "" : "s") · \(season.competition)"
                     : "No rated games yet · \(season.competition)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NuvioTheme.card))
    }

    /// The game card's colours, on the 1–10 scale.
    private func ratingColor(_ rating: Double?) -> Color {
        guard let rating else { return Color(white: 0.22) }
        switch rating {
        case ..<5.0: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case ..<7.0: return Color(red: 0.95, green: 0.6, blue: 0.1)
        default: return Color(red: 0.2, green: 0.7, blue: 0.35)
        }
    }

    // MARK: Highlights

    private func highlightGrid(_ stats: [PlayerSeasonService.Stat]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(stats) { stat in
                VStack(spacing: 6) {
                    Text(stat.value)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, minHeight: 78)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NuvioTheme.card))
            }
        }
    }

    // MARK: Games

    private func recentGames(_ games: [PlayerSeasonService.Game]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent games")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            VStack(spacing: 0) {
                ForEach(Array(games.prefix(10).enumerated()), id: \.element.id) { index, game in
                    HStack(spacing: 12) {
                        Text(game.date.map { Self.dateFormat.string(from: $0) } ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 52, alignment: .leading)
                        if let logo = game.opponentLogo, !logo.isEmpty {
                            CachedAsyncImage(urlString: logo,
                                             size: CGSize(width: 22, height: 22),
                                             decodeSize: CGSize(width: 66, height: 66))
                        }
                        Text("\(game.atVs) \(game.opponent)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(game.result) \(game.score)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(resultColor(game.result))
                            .monospacedDigit()
                        RatingBadge(rating: game.rating, compact: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < min(games.count, 10) - 1 {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NuvioTheme.card))
        }
    }

    private func resultColor(_ result: String) -> Color {
        switch result {
        case "W": return Color(red: 0.3, green: 0.8, blue: 0.45)
        case "L": return Color(red: 0.95, green: 0.4, blue: 0.4)
        default: return .white.opacity(0.6)
        }
    }

    // MARK: Season

    private func allStats(_ season: PlayerSeasonService.Season) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(season.competition)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            VStack(spacing: 0) {
                ForEach(Array(season.stats.enumerated()), id: \.element.id) { index, stat in
                    HStack {
                        Text(stat.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 8)
                        Text(stat.value)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    if index < season.stats.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NuvioTheme.card))
        }
    }
}
