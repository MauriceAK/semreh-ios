import SwiftUI

/// Cached template images let the native tab bar use matching outline/filled bird states.
@MainActor
enum BirdTabIcon {
    static let image = templateImage(for: BirdTabOutlineArtwork())
    static let selectedImage = templateImage(for: BirdTabFilledArtwork())

    private static func templateImage<Artwork: View>(for artwork: Artwork) -> UIImage {
        let renderer = ImageRenderer(content: artwork.frame(width: 25, height: 25))
        renderer.scale = 3
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysTemplate)
    }
}

/// Small, tintable outline variant for the inactive Bots tab.
private struct BirdTabOutlineArtwork: View {
    private let outlineStyle = StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
    private let detailStyle = StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 100
            ZStack {
                BirdArtworkGeometry.bodyPath
                    .stroke(Color.black, style: outlineStyle)

                BirdArtworkGeometry.wingPath
                    .stroke(Color.black, style: outlineStyle)

                BirdArtworkGeometry.eyePath(at: BirdArtworkGeometry.leftEyeCenter)
                    .stroke(Color.black, style: detailStyle)
                BirdArtworkGeometry.eyePath(at: BirdArtworkGeometry.rightEyeCenter)
                    .stroke(Color.black, style: detailStyle)
                BirdArtworkGeometry.beakPath
                    .stroke(Color.black, style: detailStyle)
            }
            .frame(width: 100, height: 100)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Filled selected-state silhouette, with the eyes and beak kept as negative-space details.
private struct BirdTabFilledArtwork: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            context.fill(
                BirdArtworkGeometry.filledPath.applying(transform),
                with: .color(.black),
                style: FillStyle(eoFill: true)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Shared artwork geometry keeps avatars and native tab-bar variants source-faithful.
enum BirdArtworkGeometry {
    static let leftEyeCenter = CGPoint(x: 65.5, y: 43)
    static let rightEyeCenter = CGPoint(x: 79.5, y: 41)

    static var bodyPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: 39))
        path.addCurve(to: CGPoint(x: 38, y: 28), control1: CGPoint(x: 23, y: 48), control2: CGPoint(x: 31, y: 37))
        path.addCurve(to: CGPoint(x: 65, y: 16), control1: CGPoint(x: 45, y: 18), control2: CGPoint(x: 56, y: 16))
        path.addCurve(to: CGPoint(x: 94, y: 40), control1: CGPoint(x: 80, y: 16), control2: CGPoint(x: 91, y: 20))
        path.addCurve(to: CGPoint(x: 86, y: 78), control1: CGPoint(x: 99, y: 57), control2: CGPoint(x: 95, y: 70))
        path.addCurve(to: CGPoint(x: 52, y: 89), control1: CGPoint(x: 78, y: 88), control2: CGPoint(x: 65, y: 90))
        path.addCurve(to: CGPoint(x: 24, y: 74), control1: CGPoint(x: 39, y: 90), control2: CGPoint(x: 30, y: 87))
        featherTips(&path)
        path.closeSubpath()
        return path
    }

    static var wingPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: 39))
        path.addCurve(to: CGPoint(x: 35, y: 45), control1: CGPoint(x: 17, y: 47), control2: CGPoint(x: 28, y: 45))
        path.addCurve(to: CGPoint(x: 46, y: 55), control1: CGPoint(x: 44, y: 44), control2: CGPoint(x: 48, y: 48))
        path.addCurve(to: CGPoint(x: 24, y: 74), control1: CGPoint(x: 46, y: 66), control2: CGPoint(x: 36, y: 73))
        featherTips(&path)
        path.closeSubpath()
        return path
    }

    static var beakPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 71.5, y: 47))
        path.addQuadCurve(to: CGPoint(x: 80, y: 45), control: CGPoint(x: 81, y: 43))
        path.addLine(to: CGPoint(x: 78.5, y: 52))
        path.addQuadCurve(to: CGPoint(x: 76, y: 53), control: CGPoint(x: 78, y: 55))
        path.closeSubpath()
        return path
    }

    static func eyePath(at center: CGPoint) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(
                x: center.x - 2.85,
                y: center.y - 5.85,
                width: 5.7,
                height: 11.7
            ),
            cornerSize: CGSize(width: 2.85, height: 2.85)
        )
        let rotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -.pi * 14 / 180)
            .translatedBy(x: -center.x, y: -center.y)
        return path.applying(rotation)
    }

    static var filledPath: Path {
        var path = bodyPath
        path.addPath(eyePath(at: leftEyeCenter))
        path.addPath(eyePath(at: rightEyeCenter))
        path.addPath(beakPath)
        return path
    }

    private static func featherTips(_ path: inout Path) {
        path.addCurve(to: CGPoint(x: 8, y: 64), control1: CGPoint(x: 16, y: 75), control2: CGPoint(x: 9, y: 68))
        path.addQuadCurve(to: CGPoint(x: 17, y: 61), control: CGPoint(x: 6, y: 60))
        path.addCurve(to: CGPoint(x: 4, y: 43), control1: CGPoint(x: 8, y: 58), control2: CGPoint(x: 4, y: 51))
        path.addQuadCurve(to: CGPoint(x: 8, y: 39), control: CGPoint(x: 3, y: 35))
    }
}

/// Static approved companion. Shared vector geometry stays crisp in rows and headers.
struct BirdAvatarView: View {
    let identity: BirdAvatarIdentity

    var body: some View {
        BirdArtwork(palette: BirdPalette.assignment(for: identity))
            .accessibilityHidden(true)
    }
}

enum BirdPalette: CaseIterable, Equatable {
    case sky, violet, mint, pink, orange, yellow, teal, lavender

    /// The standard server profile and its onboarding preview use sky/white/light blue.
    /// Decorative and named profiles retain their deterministic hash-bucket assignments.
    static func assignment(for identity: BirdAvatarIdentity) -> Self {
        if identity.profileID == "default" || identity.profileID == "appearance-preview" {
            return .sky
        }
        let assigned: [Self] = [.yellow, .orange, .mint, .pink, .sky, .violet]
        return assigned[identity.presetIndex]
    }

    var colors: (UInt32, UInt32, UInt32) {
        switch self {
        case .sky: (0xF6F8FF, 0xBDD3FF, 0x82ACF5)
        case .violet: (0xDCC0FF, 0xA06AEE, 0x8953DC)
        case .mint: (0xCEFFF0, 0x78DDC4, 0x51C9AE)
        case .pink: (0xFFCCE5, 0xF587B9, 0xE568A3)
        case .orange: (0xFFD1A6, 0xFF966B, 0xED8054)
        case .yellow: (0xFFF1B3, 0xF5D16F, 0xEAC05A)
        case .teal: (0xB7F6F4, 0x52CDE0, 0x31BACE)
        case .lavender: (0xF4DFFF, 0xC59AE9, 0xAB79D5)
        }
    }
}

private struct BirdArtwork: View {
    let palette: BirdPalette

    var body: some View {
        let (top, bottom, wing) = palette.colors
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 100
            ZStack {
                BirdArtworkGeometry.bodyPath
                    .fill(LinearGradient(colors: [color(top), color(bottom)], startPoint: .top, endPoint: .bottomTrailing))

                // Swept left wing with the reference's two feather tips.
                BirdArtworkGeometry.wingPath
                    .fill(LinearGradient(colors: [color(bottom), color(wing)], startPoint: .topLeading, endPoint: .bottomTrailing))

                Capsule().fill(color(0x191933)).frame(width: 5.7, height: 11.7)
                    .rotationEffect(.degrees(-14)).position(BirdArtworkGeometry.leftEyeCenter)
                Capsule().fill(color(0x191933)).frame(width: 5.7, height: 11.7)
                    .rotationEffect(.degrees(-14)).position(BirdArtworkGeometry.rightEyeCenter)
                BirdArtworkGeometry.beakPath.fill(color(wing))
            }
            .frame(width: 100, height: 100)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}

#Preview("Approved bird · light and dark") {
    VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { dark in
            VStack(spacing: 16) {
                ForEach([CGFloat(24), CGFloat(48)], id: \.self) { size in
                    HStack(spacing: 8) {
                        ForEach(BirdPalette.allCases, id: \.self) { palette in
                            BirdArtwork(palette: palette).frame(width: size, height: size)
                        }
                    }
                }
            }
            .padding(20)
            .background(dark ? Color(red: 0.10, green: 0.09, blue: 0.16) : Color(red: 0.98, green: 0.97, blue: 0.94))
        }
    }
}

#if DEBUG
/// Server-free visual comparison surface for the approved bird artwork.
/// Keep this beside the private renderer so the lab cannot drift into a replica.
struct BirdPaletteVisualLabView: View {
    private let sizes: [CGFloat] = [24, 48, 52]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Bird palette visual lab")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Server-free · native BirdArtwork geometry and gradients · 8 palettes × 24 / 48 / 52 pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach([false, true], id: \.self) { isDark in
                    let appearance = isDark ? "Dark" : "Light"
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(appearance) appearance")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 10) {
                            ForEach(Array(BirdPalette.allCases.enumerated()), id: \.offset) { index, palette in
                                HStack(spacing: 12) {
                                    Text(palette.visualLabName)
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 64, alignment: .leading)

                                    Spacer(minLength: 0)

                                    ForEach(sizes, id: \.self) { size in
                                        BirdArtwork(palette: palette)
                                            .frame(width: size, height: size)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(
                                    "bird-palette-lab-\(isDark ? "dark" : "light")-\(index)"
                                )
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isDark
                            ? Color(red: 0.10, green: 0.09, blue: 0.16)
                            : Color(red: 0.98, green: 0.97, blue: 0.94),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .environment(\.colorScheme, isDark ? .dark : .light)
                    .accessibilityIdentifier("bird-palette-lab-\(isDark ? "dark" : "light")")
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("bird-palette-visual-lab")
    }
}

private extension BirdPalette {
    var visualLabName: String {
        switch self {
        case .sky: "Sky"
        case .violet: "Violet"
        case .mint: "Mint"
        case .pink: "Pink"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .teal: "Teal"
        case .lavender: "Lavender"
        }
    }
}
#endif
