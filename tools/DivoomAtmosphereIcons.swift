import SwiftUI

/// Small original vector reinterpretations of each Atmosphere background's
/// general visual theme (EQ bars / waveform / night scene / etc.), built
/// entirely from plain SwiftUI shapes and gradients -- not reproductions of
/// Divoom's actual bitmap artwork, since that's their IP. Index-to-visual
/// mapping is inferred from the *display order* of backgrounds in the
/// official app's grid (top-left to bottom-right, 3 columns, per the
/// screenshots this was designed against), not independently confirmed
/// against the real `Background` wire value for each slot via a fresh
/// capture. Corroborated (not proven) by the real on-device names in
/// `AtmosphereModel.backgroundNames`, which line up thematically with most
/// of these icons (e.g. index 2 "Sound Wave Ring", 7 "Bubbles", 9 "Vinyl",
/// 16 "Black Hole", 18 "Vaporware", 20 "Photo Album").
struct AtmosphereBackgroundIcon: View {
    let index: Int
    var size: CGFloat = 52
    // Every shape below is drawn against this fixed canvas and then scaled
    // as a whole to whatever `size` is requested, so none of the 21 cases
    // need their coordinates rewritten when the tile size changes.
    private let designSize: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.black)
            content.padding(6).scaleEffect(size / designSize)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        switch index {
        case 0: barsView(colors: [.green, .yellow, .orange])
        case 1: pixelBarsView(color: .green)
        case 2: ringView(colors: [.pink, .purple, .blue])
        case 3: waveView(colors: [.white])
        case 4: waveView(colors: [.teal, .pink])
        case 5: nightWindowView()
        case 6: astronautView()
        case 7: bubblesView()
        case 8: dockView()
        case 9: vinylView()
        case 10: villageView()
        case 11: skylineView()
        case 12: horizonView(top: .purple, bottom: .indigo, orb: .white)
        case 13: smokeView(colors: [.blue, .white, .gray])
        case 14: smokeView(colors: [.red, .orange, .teal, .purple, .pink])
        case 15: tunnelView()
        case 16: stardustView()
        case 17: mountainSpectrumView()
        case 18: synthwaveView()
        case 19: calmLakeView()
        case 20: photoTileView()
        default: EmptyView()
        }
    }

    // Fixed pattern (not random) so the icon looks identical every render.
    private static let barPattern: [CGFloat] = [0.45, 0.85, 0.6, 1.0, 0.4, 0.75, 0.55]

    private func barsView(colors: [Color]) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(gradient: Gradient(colors: colors), startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: 30 * Self.barPattern[i])
            }
        }
    }

    /// Mirrored top+bottom pixel bars, matching the reference screenshot's
    /// symmetric look (distinct from index 0's single bottom-up EQ bars).
    private func pixelBarsView(color: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                let lit = Int(Self.barPattern[i] * 4)
                VStack(spacing: 1) {
                    ForEach(0..<4, id: \.self) { row in
                        Rectangle().fill(row >= 4 - lit ? color : color.opacity(0.15)).frame(width: 3, height: 4)
                    }
                    Rectangle().fill(color.opacity(0.5)).frame(width: 3, height: 2)
                    ForEach(0..<4, id: \.self) { row in
                        Rectangle().fill(row < lit ? color : color.opacity(0.15)).frame(width: 3, height: 4)
                    }
                }
            }
        }
    }

    private func ringView(colors: [Color]) -> some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                Capsule()
                    .fill(colors[i % colors.count])
                    .frame(width: 2, height: 6)
                    .offset(y: -15)
                    .rotationEffect(.degrees(Double(i) / 14 * 300))
            }
        }
    }

    private func waveView(colors: [Color]) -> some View {
        ZStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { idx, color in
                WaveShape(phase: Double(idx) * .pi / 2)
                    .stroke(color, lineWidth: 1.5)
            }
        }
    }

    private func bubblesView() -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1).frame(width: 20, height: 20).offset(x: -8, y: -6)
            Circle().stroke(Color.blue.opacity(0.6), lineWidth: 1).frame(width: 12, height: 12).offset(x: 10, y: 4)
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1).frame(width: 8, height: 8).offset(x: -4, y: 12)
        }
    }

    private func vinylView() -> some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.25)).frame(width: 36, height: 36)
            Circle().stroke(Color.gray.opacity(0.6), lineWidth: 1).frame(width: 36, height: 36)
            Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1).frame(width: 26, height: 26)
            Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1).frame(width: 16, height: 16)
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Capsule().fill(Color.gray.opacity(0.9)).frame(width: 16, height: 2.5).rotationEffect(.degrees(-45)).offset(x: 11, y: -11)
            Circle().fill(Color.gray.opacity(0.9)).frame(width: 4, height: 4).offset(x: 17, y: -17)
        }
    }

    /// The generic "dreamy AI astronaut wallpaper" look common online: a
    /// colorful nebula backdrop, a ringed planet, lots of stars, and a
    /// small floating astronaut silhouette -- rather than a plain dark
    /// starfield with a bare figure.
    private func astronautView() -> some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.indigo.opacity(0.5), Color.purple.opacity(0.35), Color.black]), startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Circle().fill(Color.pink.opacity(0.35)).frame(width: 26, height: 26).blur(radius: 7).offset(x: -8, y: -6)
            Circle().fill(Color.blue.opacity(0.3)).frame(width: 22, height: 22).blur(radius: 7).offset(x: 8, y: 4)
            starsOverlay(count: 10)
            ZStack {
                Circle().fill(Color.orange.opacity(0.8)).frame(width: 10, height: 10)
                Ellipse().stroke(Color.white.opacity(0.7), lineWidth: 1).frame(width: 17, height: 5).rotationEffect(.degrees(-20))
            }
            .offset(x: 14, y: -15)
            VStack(spacing: -2) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.95)).frame(width: 14, height: 14)
                    Circle().stroke(Color.cyan.opacity(0.8), lineWidth: 1.5).frame(width: 9, height: 9)
                }
                Capsule().fill(Color.white.opacity(0.95)).frame(width: 14, height: 17)
                HStack(spacing: 9) {
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 3.5, height: 9)
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 3.5, height: 9)
                }
                .offset(y: -7)
            }
            .rotationEffect(.degrees(-8))
            .offset(x: -5, y: 4)
        }
    }

    /// Index 5: a glowing window, a small seated silhouette beneath it, and a
    /// thin waveform strip along the bottom edge.
    private func nightWindowView() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: 13, height: 13).offset(y: -10)
            RoundedRectangle(cornerRadius: 2).stroke(Color.gray.opacity(0.6), lineWidth: 1).frame(width: 17, height: 17).offset(y: -10)
            Ellipse().fill(Color.black.opacity(0.7)).frame(width: 12, height: 6).offset(y: 8)
            WaveShape(phase: 0).stroke(Color.white.opacity(0.5), lineWidth: 1).frame(height: 6).offset(y: 16)
        }
    }

    /// Index 8: a bench overlooking clouds and calm water.
    private func dockView() -> some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.15)]), startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            cloudShape().offset(x: -6, y: -13)
            cloudShape().scaleEffect(0.7).offset(x: 11, y: -9)
            Rectangle().fill(Color.white.opacity(0.4)).frame(height: 1).offset(y: 6)
            // Bench: seat + two legs, sitting on the horizon line.
            RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.75)).frame(width: 20, height: 2.5).offset(y: 3)
            Capsule().fill(Color.black.opacity(0.75)).frame(width: 1.5, height: 7).offset(x: -8, y: 8)
            Capsule().fill(Color.black.opacity(0.75)).frame(width: 1.5, height: 7).offset(x: 8, y: 8)
        }
    }

    private func cloudShape() -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.55)).frame(width: 9, height: 9).offset(x: -4)
            Circle().fill(Color.white.opacity(0.55)).frame(width: 12, height: 12)
            Circle().fill(Color.white.opacity(0.55)).frame(width: 8, height: 8).offset(x: 6, y: 1)
        }
    }

    private func villageView() -> some View {
        ZStack {
            starsOverlay(count: 6)
            Circle().stroke(Color.gray.opacity(0.6), lineWidth: 1).frame(width: 6, height: 6).offset(x: 13, y: -15)
            HStack(spacing: 2) {
                houseShape().frame(width: 12, height: 12)
                houseShape().frame(width: 17, height: 17)
                houseShape().frame(width: 10, height: 10)
            }
            .offset(y: 8)
        }
    }

    private func houseShape() -> some View {
        VStack(spacing: 0) {
            Triangle().fill(Color.white.opacity(0.85)).frame(height: 6)
            Rectangle().fill(Color.white.opacity(0.7))
        }
    }

    private func skylineView() -> some View {
        ZStack {
            starsOverlay(count: 6)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(Color.blue.opacity(0.5))
                        .frame(width: 5, height: [14, 22, 10, 26, 16][i])
                }
            }
            .offset(y: 6)
        }
    }

    // Fixed scatter positions spanning the whole tile (not clustered in one
    // corner) so this reads as random stars/dust, not a ring or vortex.
    private static let starOffsets: [(CGFloat, CGFloat)] = [
        (-18, -16), (-6, -19), (8, -14), (17, -8), (-15, -2), (-2, 3), (12, 6),
        (18, 14), (-11, 12), (2, -6), (-19, 8), (6, 17), (15, -18), (-8, -9),
        (0, 12), (-16, 17), (10, -2), (19, 2),
    ]

    private func starsOverlay(count: Int) -> some View {
        ZStack {
            ForEach(0..<min(count, Self.starOffsets.count), id: \.self) { i in
                Circle().fill(Color.white.opacity(0.8)).frame(width: 1.5, height: 1.5)
                    .offset(x: Self.starOffsets[i].0, y: Self.starOffsets[i].1)
            }
        }
    }

    private func horizonView(top: Color, bottom: Color, orb: Color) -> some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [top.opacity(0.6), bottom.opacity(0.6)]), startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Circle().fill(orb).frame(width: 14, height: 14).offset(y: -4)
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 14).offset(y: 11)
        }
    }

    /// A calm dusk/night lake: gradient sky, a soft glow at the horizon
    /// (no distinct sun/moon disc), and a faint reflection line -- distinct
    /// from index 12's prominent orb-over-water look.
    private func calmLakeView() -> some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.indigo.opacity(0.6), Color.blue.opacity(0.35)]), startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Ellipse().fill(Color.white.opacity(0.25)).frame(width: 26, height: 8).blur(radius: 3).offset(y: 2)
            Rectangle().fill(Color.black.opacity(0.3)).frame(height: 12).offset(y: 12)
            Rectangle().fill(Color.white.opacity(0.3)).frame(height: 1).offset(y: 6)
        }
    }

    /// Classic synthwave/retro sun: a banded circle over a hinted grid floor.
    /// Bands are drawn directly (not masked) and clipped with `.clipShape`,
    /// which is reliable at any tile size, unlike `.mask` combined with
    /// `.scaleEffect` on the whole icon (tried first, didn't clip cleanly).
    private func synthwaveView() -> some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.purple.opacity(0.7), Color.orange.opacity(0.6)]), startPoint: .top, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            ZStack {
                Circle().fill(Color.yellow.opacity(0.9))
                VStack(spacing: 3) {
                    Color.clear.frame(height: 3)
                    Rectangle().fill(Color.purple.opacity(0.6)).frame(height: 2)
                    Color.clear.frame(height: 3)
                    Rectangle().fill(Color.purple.opacity(0.6)).frame(height: 2)
                    Color.clear.frame(height: 3)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .offset(y: -5)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(Color.pink.opacity(0.6)).frame(width: 1, height: 9)
                }
            }
            .offset(y: 12)
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: 5).offset(y: 15)
        }
    }

    private func smokeView(colors: [Color]) -> some View {
        ZStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                Circle()
                    .fill(color.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .blur(radius: 6)
                    .offset(x: Self.smokeOffsets[i % Self.smokeOffsets.count].0, y: Self.smokeOffsets[i % Self.smokeOffsets.count].1)
            }
        }
    }

    private static let smokeOffsets: [(CGFloat, CGFloat)] = [(-8, -6), (7, -8), (0, 4), (9, 8), (-9, 9)]

    private func tunnelView() -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .stroke(i % 2 == 0 ? Color.red : Color.teal, lineWidth: 1)
                    .frame(width: 36 - CGFloat(i) * 8, height: 36 - CGFloat(i) * 8)
            }
        }
    }

    private func stardustView() -> some View {
        starsOverlay(count: 18)
    }

    /// A symmetric "mountain range" of EQ-style bars radiating from the
    /// center, taller in the middle -- distinct from the plain vertical
    /// bars/pixel-bars used for indices 0/1.
    private func mountainSpectrumView() -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(gradient: Gradient(colors: [.blue, .purple, .pink]), startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: 30 * [0.25, 0.5, 0.8, 1.0, 0.8, 0.5, 0.25][i])
            }
        }
    }

    /// Index 20 in the official app is a "use your own photo" tile, not a
    /// generated visual -- represented as a generic photo/picture glyph
    /// (frame + mountains + sun, the universal "this is an image" icon)
    /// rather than any specific photo.
    private func photoTileView() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5), lineWidth: 1.5).frame(width: 34, height: 28)
            Circle().fill(Color.yellow.opacity(0.8)).frame(width: 5, height: 5).offset(x: 9, y: -8)
            Path { p in
                p.move(to: CGPoint(x: -15, y: 8))
                p.addLine(to: CGPoint(x: -6, y: -4))
                p.addLine(to: CGPoint(x: 0, y: 2))
                p.addLine(to: CGPoint(x: 7, y: -8))
                p.addLine(to: CGPoint(x: 15, y: 8))
                p.closeSubpath()
            }
            .fill(Color.white.opacity(0.6))
        }
    }
}

private struct WaveShape: Shape {
    var phase: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.midY
        let amplitude = rect.height * 0.35
        p.move(to: CGPoint(x: rect.minX, y: midY))
        let steps = 40
        for i in 0...steps {
            let x = rect.minX + CGFloat(i) / CGFloat(steps) * rect.width
            let angle = Double(i) / Double(steps) * 2 * .pi * 2 + phase
            let y = midY + amplitude * CGFloat(sin(angle))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
