// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Christmas decorations: snow falling over the tabs, snow resting on cards and icons, and a lit tree in the
/// Home header. Purely decoration -- nothing here takes touches -- and one switch in Appearance turns it off.
enum Holiday {
    static let key = "holiday.decorations"
}

/// One flake's fixed properties. A function of its seed and nothing else, so
/// the snow is the same on every launch and on every device.
private struct SnowFlake {
    let x, speed, size, sway, phase, alpha: Double
    init(seed: Int) {
        // a small deterministic hash per flake, so the snow looks the same on every launch
        func r(_ k: Int) -> Double { let v = sin(Double(seed * 92821 + k * 68917)) * 43758.5453; return v - floor(v) }
        x = r(1); speed = 0.035 + r(2) * 0.06; size = 1.6 + r(3) * 3.2; sway = 6 + r(4) * 18; phase = r(5) * 6.28; alpha = 0.45 + r(6) * 0.5
    }
}

/// Snow falling over the whole screen.
///
/// TimelineView and Canvas are both iOS 15 and neither has a SwiftUI equivalent
/// below them -- they are the drawing primitives this is written in, not
/// spellings of something older. So the same drawing is done directly: a UIView
/// whose draw(_:) is the loop that was in the Canvas, told to redraw by a
/// CADisplayLink at the 30 Hz the TimelineView asked for.
///
/// The flake arithmetic is unchanged, and every flake is still a function of the
/// clock alone, so nothing needs to be kept or simulated between frames.
struct Snowfall: UIViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    private let flakes: [SnowFlake] = (0..<70).map { SnowFlake(seed: $0) }

    func makeUIView(context: Context) -> SnowView {
        let v = SnowView(flakes: flakes)
        // Decoration: it takes no touches, and it is not read aloud.
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ uiView: SnowView, context: Context) {
        uiView.tint = scheme == .dark
            ? UIColor.white
            : UIColor(red: 0.66, green: 0.76, blue: 0.88, alpha: 1)
        uiView.start()
    }

    static func dismantleUIView(_ uiView: SnowView, coordinator: ()) { uiView.stop() }

    final class SnowView: UIView {
        private let flakes: [SnowFlake]
        var tint: UIColor = .white { didSet { if tint != oldValue { setNeedsDisplay() } } }
        private var link: CADisplayLink?

        init(flakes: [SnowFlake]) {
            self.flakes = flakes
            super.init(frame: .zero)
            // Nothing to show until there is a size to lay flakes out in.
            isOpaque = false
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            let t = Date().timeIntervalSinceReferenceDate
            let b = bounds
            guard let ctx = UIGraphicsGetCurrentContext(), b.width > 0, b.height > 0 else { return }
            for f in flakes {
                let fall = (t * f.speed + f.phase).truncatingRemainder(dividingBy: 1.0)
                let y = fall * (b.height + 20) - 10
                let x = f.x * b.width + sin(t * 0.6 + f.phase) * f.sway
                ctx.setFillColor(tint.withAlphaComponent(f.alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: f.size, height: f.size))
            }
        }

        func start() {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFramesPerSecond = 30
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() { setNeedsDisplay() }
    }
}

/// The lumpy top edge of a layer of snow: flat on top, scalloped underneath.
private struct SnowCapShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let bumps = max(3, Int(r.width / 22))
        let w = r.width / CGFloat(bumps)
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35))
        p.addQuadCurve(to: CGPoint(x: r.minX + r.height * 0.6, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.height * 0.6, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.35), control: CGPoint(x: r.maxX, y: r.minY))
        for i in (0..<bumps).reversed() {
            let x0 = r.minX + CGFloat(i) * w, deep = (i % 2 == 0) ? 1.0 : 0.72
            p.addQuadCurve(to: CGPoint(x: x0, y: r.minY + r.height * 0.35),
                           control: CGPoint(x: x0 + w / 2, y: r.minY + r.height * deep * 1.25))
        }
        p.closeSubpath()
        return p
    }
}

private struct SnowCap: ViewModifier {
    @AppStorage(Holiday.key) private var on = true
    var height: CGFloat
    func body(content: Content) -> some View {
        // .overlay(alignment:content:) is iOS 15; huskOverlay carries the
        // alignment in a ZStack instead.
        content.huskOverlay(alignment: .top) {
            if on {
                SnowCapShape()
                    .fill(Color.white)
                    .frame(height: height)
                    .padding(.horizontal, -1)
                    .offset(y: -height * 0.3)
                    .shadow(color: .black.opacity(0.14), radius: 1.2, y: 0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// Snow resting on the top edge of a card or icon (when decorations are on).
    func snowCap(height: CGFloat = 9) -> some View { modifier(SnowCap(height: height)) }
}

/// A small tree with a star and lights that twinkle, for the Home header.
struct ChristmasTree: View {
    var size: CGFloat = 30
    private let lights: [(CGFloat, CGFloat, Color)] = [
        (0.47, 0.34, .red), (0.58, 0.44, .yellow), (0.38, 0.52, .blue), (0.62, 0.60, .orange),
        (0.44, 0.66, .pink), (0.30, 0.76, .yellow), (0.55, 0.78, .red), (0.70, 0.80, .blue), (0.40, 0.86, .orange),
    ]
    /// Advances every 0.45 s, which is what TimelineView(.periodic) did.
    /// Timer.publish is iOS 13 and LogView already uses it.
    private let clock = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()
    @State private var tick = 0

    var body: some View {
        ZStack {
        Rectangle().fill(Color(red: 0.45, green: 0.28, blue: 0.16))
            .frame(width: size * 0.14, height: size * 0.14).offset(y: size * 0.44)
        tier(width: 1.0, top: 0.42, bottom: 0.93)
        tier(width: 0.78, top: 0.24, bottom: 0.68)
        tier(width: 0.56, top: 0.07, bottom: 0.45)
        Image(systemName: "star.fill").font(.system(size: size * 0.24)).foregroundColor(.yellow)
            .offset(y: -size * 0.44)
        ForEach(lights.indices, id: \.self) { i in
            let (x, y, c) = lights[i]
            let lit = (i + tick) % 3 != 0
            Circle().fill(c.opacity(lit ? 1 : 0.25))
                .frame(width: size * 0.09, height: size * 0.09)
                .shadow(color: lit ? c : .clear, radius: size * 0.08)
                .position(x: x * size, y: y * size)
        }
        }
        .frame(width: size, height: size)
        .onReceive(clock) { _ in tick &+= 1 }
        .accessibilityHidden(true)
    }

    private func tier(width: CGFloat, top: CGFloat, bottom: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: size / 2, y: top * size))
            p.addLine(to: CGPoint(x: size / 2 + width * size / 2, y: bottom * size))
            p.addLine(to: CGPoint(x: size / 2 - width * size / 2, y: bottom * size))
            p.closeSubpath()
        }
        .fill(Color(red: 0.13, green: 0.55, blue: 0.27))
        .frame(width: size, height: size)
    }
}
