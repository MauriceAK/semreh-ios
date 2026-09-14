import SwiftUI

/// Static approved companion. Shared vector geometry stays crisp in rows and headers.
struct BirdAvatarView: View {
    let identity: BirdAvatarIdentity

    var body: some View {
        // Retain the six existing hash buckets and nearest approved color families.
        let assigned: [BirdPalette] = [.yellow, .orange, .mint, .pink, .sky, .violet]
        BirdArtwork(palette: assigned[identity.presetIndex])
            .accessibilityHidden(true)
    }
}

private enum BirdPalette: CaseIterable {
    case sky, violet, mint, pink, orange, yellow, teal, lavender

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
                Path { p in
                    p.move(to: CGPoint(x: 8, y: 39))
                    p.addCurve(to: CGPoint(x: 38, y: 24), control1: CGPoint(x: 23, y: 48), control2: CGPoint(x: 31, y: 37))
                    p.addCurve(to: CGPoint(x: 65, y: 9), control1: CGPoint(x: 44, y: 14), control2: CGPoint(x: 53, y: 8))
                    p.addCurve(to: CGPoint(x: 94, y: 40), control1: CGPoint(x: 82, y: 8), control2: CGPoint(x: 92, y: 22))
                    p.addCurve(to: CGPoint(x: 86, y: 78), control1: CGPoint(x: 99, y: 57), control2: CGPoint(x: 95, y: 70))
                    p.addCurve(to: CGPoint(x: 52, y: 89), control1: CGPoint(x: 78, y: 88), control2: CGPoint(x: 65, y: 90))
                    p.addCurve(to: CGPoint(x: 24, y: 74), control1: CGPoint(x: 39, y: 90), control2: CGPoint(x: 30, y: 87))
                    featherTips(&p)
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color(top), color(bottom)], startPoint: .top, endPoint: .bottomTrailing))

                // Swept left wing with the reference's two feather tips.
                Path { p in
                    p.move(to: CGPoint(x: 8, y: 39))
                    p.addCurve(to: CGPoint(x: 35, y: 45), control1: CGPoint(x: 17, y: 47), control2: CGPoint(x: 28, y: 45))
                    p.addCurve(to: CGPoint(x: 46, y: 55), control1: CGPoint(x: 44, y: 44), control2: CGPoint(x: 48, y: 48))
                    p.addCurve(to: CGPoint(x: 24, y: 74), control1: CGPoint(x: 46, y: 66), control2: CGPoint(x: 36, y: 73))
                    featherTips(&p)
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color(bottom), color(wing)], startPoint: .topLeading, endPoint: .bottomTrailing))

                Capsule().fill(color(0x191933)).frame(width: 5.7, height: 11.7)
                    .rotationEffect(.degrees(-14)).position(x: 65.5, y: 38.5)
                Capsule().fill(color(0x191933)).frame(width: 5.7, height: 11.7)
                    .rotationEffect(.degrees(-14)).position(x: 79.5, y: 36)
                Path { p in
                    p.move(to: CGPoint(x: 71.5, y: 47))
                    p.addQuadCurve(to: CGPoint(x: 80, y: 45), control: CGPoint(x: 81, y: 43))
                    p.addLine(to: CGPoint(x: 78.5, y: 52))
                    p.addQuadCurve(to: CGPoint(x: 76, y: 53), control: CGPoint(x: 78, y: 55))
                    p.closeSubpath()
                }.fill(color(wing))
            }
            .frame(width: 100, height: 100)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func featherTips(_ p: inout Path) {
        p.addCurve(to: CGPoint(x: 8, y: 64), control1: CGPoint(x: 16, y: 75), control2: CGPoint(x: 9, y: 68))
        p.addQuadCurve(to: CGPoint(x: 17, y: 61), control: CGPoint(x: 6, y: 60))
        p.addCurve(to: CGPoint(x: 4, y: 43), control1: CGPoint(x: 8, y: 58), control2: CGPoint(x: 4, y: 51))
        p.addQuadCurve(to: CGPoint(x: 8, y: 39), control: CGPoint(x: 3, y: 35))
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
