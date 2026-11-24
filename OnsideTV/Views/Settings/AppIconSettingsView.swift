import SwiftUI
import UIKit

/// Settings → App Icon. The default icon and the twelve glass-set alternates.
///
/// Each alternate is an app icon set in the asset catalog, listed in the
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` build setting so actool
/// bundles it and writes it into the Info.plist. An app can't load its own
/// icon sets as images, so every option also has a small `IconPreview-` image
/// for this list.
struct AppIconSettingsView: View {
    struct Option: Identifiable {
        /// The alternate icon's name, or nil for the default.
        let iconName: String?
        let title: String
        let detail: String
        let preview: String
        var id: String { iconName ?? "default" }
    }

    static let options: [Option] = [
        Option(iconName: nil, title: "Default", detail: "The original Onside TV icon.",
               preview: "IconPreview-Default"),
        Option(iconName: "AppIcon-GP1", title: "Centre Circle",
               detail: "Green tile. The halfway line through the centre circle.",
               preview: "IconPreview-GP1"),
        Option(iconName: "AppIcon-GP2", title: "Goal Mouth",
               detail: "Black tile. The goal and the spot in front of it.",
               preview: "IconPreview-GP2"),
        Option(iconName: "AppIcon-GP3", title: "Half Way",
               detail: "Green tile. A pitch split down the middle.",
               preview: "IconPreview-GP3"),
        Option(iconName: "AppIcon-GP4", title: "Full Pitch",
               detail: "Black tile. The whole pitch, end to end.",
               preview: "IconPreview-GP4"),
        Option(iconName: "AppIcon-GK1", title: "Live Kickoff",
               detail: "Green tile. The centre mark with a live-red spot.",
               preview: "IconPreview-GK1"),
        Option(iconName: "AppIcon-GK2", title: "Live Spot",
               detail: "Black tile. A bold ring around a live-red spot.",
               preview: "IconPreview-GK2"),
        Option(iconName: "AppIcon-GK3", title: "On Air",
               detail: "Green tile. A live-red spot broadcasting out.",
               preview: "IconPreview-GK3"),
        Option(iconName: "AppIcon-GK4", title: "Two Halves",
               detail: "Black tile. Two halves meeting at a live-red spot.",
               preview: "IconPreview-GK4"),
        Option(iconName: "AppIcon-GS1", title: "Score Link",
               detail: "Green tile. Two scores, one of them live red.",
               preview: "IconPreview-GS1"),
        Option(iconName: "AppIcon-GS2", title: "Score Link Dark",
               detail: "Black tile. Two scores joined in red.",
               preview: "IconPreview-GS2"),
        Option(iconName: "AppIcon-GS3", title: "Stacked",
               detail: "Green tile. Two stacked bars with live-red marks.",
               preview: "IconPreview-GS3"),
        Option(iconName: "AppIcon-GS4", title: "Live Toggle",
               detail: "Black tile. A live switch, switched on.",
               preview: "IconPreview-GS4"),
    ]

    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var failed = false

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(Self.options.enumerated()), id: \.element.id) { index, option in
                        Button { choose(option) } label: { row(option) }
                            .buttonStyle(.plain)
                        if index < Self.options.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 0.5)
                                .padding(.leading, 92)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NuvioTheme.card))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 100)
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
        .alert("Couldn't Change Icon", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS didn't allow the icon change. Try again in a moment.")
        }
    }

    private func row(_ option: Option) -> some View {
        HStack(spacing: 14) {
            Image(option.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(option.detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if current == option.iconName {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func choose(_ option: Option) {
        guard option.iconName != current, UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            DispatchQueue.main.async {
                if error == nil {
                    current = option.iconName
                } else {
                    failed = true
                }
            }
        }
    }
}
