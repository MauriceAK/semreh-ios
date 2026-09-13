import SwiftUI

/// Static vector companion. No row timers, image decoding, or animation state.
struct BirdAvatarView: View {
    let identity: BirdAvatarIdentity

    private static let shells: [Color] = [
        Color(red: 1, green: 0.87, blue: 0.53),
        Color(red: 0.80, green: 0.65, blue: 0.49),
        Color(red: 0.68, green: 0.81, blue: 0.57),
        Color(red: 1, green: 0.72, blue: 0.57),
        Color(red: 0.51, green: 0.66, blue: 0.88),
        Color(red: 0.76, green: 0.63, blue: 0.87)
    ]

    var body: some View {
        let preset = identity.presetIndex
        let shell = Self.shells[preset]
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 100
            ZStack {
                ZStack {
                    // Each wing is independent so a future approved animation
                    // can pivot it without changing the static construction.
                    Ellipse().fill(shell).frame(width: 18, height: 30)
                        .rotationEffect(.degrees(-25)).position(x: 23, y: 61)
                    Ellipse().fill(shell).frame(width: 18, height: 30)
                        .rotationEffect(.degrees(preset == 0 ? -30 : 25))
                        .position(x: 77, y: preset == 0 ? 53 : 61)
                    Ellipse().fill(shell).frame(width: 65, height: 69)
                        .position(x: 50, y: 56)
                    Capsule().fill(shell).frame(width: 11, height: 20)
                        .rotationEffect(.degrees(-22)).position(x: 48, y: 23)
                    if preset == 4 {
                        Ellipse().fill(Color(red: 1, green: 0.96, blue: 0.84))
                            .frame(width: 49, height: 38).position(x: 50, y: 51)
                    }
                    eyes(preset: preset)
                    Path { path in
                        path.move(to: CGPoint(x: 43, y: 60))
                        path.addQuadCurve(to: CGPoint(x: 57, y: 60), control: CGPoint(x: 50, y: 53))
                        path.addQuadCurve(to: CGPoint(x: 50, y: 68), control: CGPoint(x: 56, y: 64))
                        path.addQuadCurve(to: CGPoint(x: 43, y: 60), control: CGPoint(x: 44, y: 64))
                    }.fill(Color(red: 0.89, green: 0.46, blue: 0.20))
                }
                .frame(width: 100, height: 100)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func eyes(preset: Int) -> some View {
        let ink = Color(red: 0.21, green: 0.17, blue: 0.16)
        return HStack(spacing: 15) {
            ForEach(0..<2) { eye in
                if preset == 5 || (preset == 3 && eye == 0) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 6))
                        path.addQuadCurve(to: CGPoint(x: 8, y: 6), control: CGPoint(x: 4, y: -1))
                    }.stroke(ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 8, height: 10)
                } else {
                    Capsule().fill(ink).frame(width: 7, height: preset == 1 ? 5 : 11)
                }
            }
        }.position(x: 50, y: 48)
    }
}
