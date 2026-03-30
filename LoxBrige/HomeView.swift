import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // MARK: Logo + title
                VStack(spacing: 8) {
                    Image("LoxBridge_icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text("LoxBridge")
                        .font(.largeTitle)
                        .bold()
                }

                // MARK: Orienteering map snippet
                OrienteeringMapSnippet()

                // MARK: Description
                Text("Automatically bridge your orienteering runs to Livelox — whether you run with Apple Watch or iPhone. After each workout, LoxBridge extracts your GPS route and uploads it to Livelox with no cables and no manual exports. Just run, and your route appears in Livelox ready to replay and share.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)

                // MARK: Livelox link
                Button {
                    if let url = URL(string: "https://www.livelox.com") {
                        openURL(url)
                    }
                } label: {
                    Label("Open Livelox", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)

                // Recording hint
                Label("To record, open the **Workout** app on your Apple Watch and choose Outdoor Run", systemImage: "applewatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // MARK: Error banner
                if let error = model.lastError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            model.lastError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
        .navigationTitle("Home")
        .navigationBarHidden(true)
    }
}

// MARK: - Orienteering map snippet — season & time-of-day aware

/// Shows a randomly-cropped slice of the orienteering map image that matches the
/// current season (spring/summer/autumn/winter) and time of day (daylight/evening).
/// Asset names follow the pattern: `daylight_summer`, `evening_winter`, etc.
/// Falls back to a green gradient if none of the eight assets are present.
private struct OrienteeringMapSnippet: View {
    private static let frameHeight: CGFloat = 180

    @State private var imageName: String = Self.seasonalImageName()

    var body: some View {
        Group {
            if let uiImage = UIImage(named: imageName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.frameHeight)
                    .clipped()
            } else {
                // Placeholder — shown if no seasonal assets are found in Assets.xcassets
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.42, blue: 0.22),
                                 Color(red: 0.08, green: 0.25, blue: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Label("Expected asset: \(imageName)", systemImage: "photo.badge.plus")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.frameHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            imageName = Self.seasonalImageName()
        }
    }

    // MARK: Season + time-of-day logic

    /// Returns the asset name that best matches the current season and time of day.
    /// Format: `{period}_{season}` — e.g. `daylight_summer` or `evening_winter`.
    ///
    /// Seasons (Northern Hemisphere):
    ///   spring = Mar–May, summer = Jun–Aug, autumn = Sep–Nov, winter = Dec–Feb
    ///
    /// Daylight windows (approximate Scandinavian hours):
    ///   summer  05:00–22:00, spring/autumn 07:00–20:00, winter 08:30–16:00
    static func seasonalImageName() -> String {
        let now = Date()
        let cal = Calendar.current
        let month = cal.component(.month, from: now)
        let hour  = cal.component(.hour,  from: now)
        let min   = cal.component(.minute, from: now)
        let time  = hour * 60 + min   // minutes since midnight

        let season: String
        switch month {
        case 3, 4, 5:   season = "spring"
        case 6, 7, 8:   season = "summer"
        case 9, 10, 11: season = "autumn"
        default:         season = "winter"
        }

        let (dawnMin, duskMin): (Int, Int)
        switch season {
        case "summer":           (dawnMin, duskMin) = (5 * 60,      22 * 60)
        case "spring", "autumn": (dawnMin, duskMin) = (7 * 60,      20 * 60)
        default:                 (dawnMin, duskMin) = (8 * 60 + 30, 16 * 60)
        }

        let period = (time >= dawnMin && time < duskMin) ? "daylight" : "evening"
        return "\(period)_\(season)"
    }
}


#Preview {
    HomeView(model: AppViewModel())
}
