import SwiftUI

/// Draws a GPS track with orienteering-style markers:
///   △  hollow equilateral triangle at start, apex rotated toward direction of travel
///   ◎  two concentric circles at finish
///
/// Track segments are coloured by relative speed: red (slow) → yellow → green (fast).
/// Falls back to adaptive moss green when speed data is unavailable.
/// Supports pinch-to-zoom (1×–8×); double-tap resets.
struct RouteTrackView: View {
    let points: [[Double]]
    let speeds: [Double]?   // normalized 0…1, same count as points; nil = use fallback colour

    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale:    CGFloat = 1.0
    @Environment(\.colorScheme) private var colorScheme

    /// Moss green fallback for when speed data is absent.
    private var fallbackColor: Color {
        colorScheme == .dark
            ? Color(red: 0.42, green: 0.78, blue: 0.32)
            : Color(red: 0.18, green: 0.50, blue: 0.12)
    }

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let cg = normalized(points: points, in: size)
            let n  = cg.count

            let R:   CGFloat = 9
            let r1:  CGFloat = 5
            let gap: CGFloat = R * 2 + 2

            // MARK: Track — skip segments whose endpoints fall inside the symbol gap zone
            func nearSymbol(_ p: CGPoint) -> Bool {
                func sq(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
                    (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
                }
                return sq(p, cg[0]) < gap * gap || sq(p, cg[n - 1]) < gap * gap
            }

            for i in 0 ..< (n - 1) {
                let ptA = cg[i], ptB = cg[i + 1]
                guard !nearSymbol(ptA) && !nearSymbol(ptB) else { continue }

                let color: Color
                if let sp = speeds, i < sp.count {
                    let t = (sp[i] + sp[min(i + 1, sp.count - 1)]) / 2.0
                    color = speedColor(t)
                } else {
                    color = fallbackColor
                }

                var seg = Path()
                seg.move(to: ptA)
                seg.addLine(to: ptB)
                context.stroke(seg, with: .color(color),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // MARK: Start △
            let s = cg[0]
            let a = atan2(cg[1].y - cg[0].y, cg[1].x - cg[0].x)
            var tri = Path()
            tri.move(to:    CGPoint(x: s.x + R * cos(a),             y: s.y + R * sin(a)))
            tri.addLine(to: CGPoint(x: s.x + R * cos(a + 2 * .pi / 3), y: s.y + R * sin(a + 2 * .pi / 3)))
            tri.addLine(to: CGPoint(x: s.x + R * cos(a - 2 * .pi / 3), y: s.y + R * sin(a - 2 * .pi / 3)))
            tri.closeSubpath()
            context.stroke(tri, with: .color(.purple), lineWidth: 1.5)

            // MARK: Finish ◎
            let f = cg[n - 1]
            for r in [r1, R] {
                context.stroke(
                    Path(ellipseIn: CGRect(x: f.x - r, y: f.y - r, width: r * 2, height: r * 2)),
                    with: .color(.purple), lineWidth: 1.5)
            }
        }
        .scaleEffect(currentScale)
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    currentScale = max(1.0, min(baseScale * value, 8.0))
                }
                .onEnded { _ in
                    baseScale = currentScale
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(duration: 0.3)) {
                currentScale = 1.0
                baseScale    = 1.0
            }
        }
    }

    // MARK: - Colour helper

    private func speedColor(_ t: Double) -> Color {
        Color(hue: t / 3.0, saturation: 0.95, brightness: 0.82)
    }

    // MARK: - Vector helpers

    // MARK: - Coordinate normalisation

    private func normalized(points: [[Double]], in size: CGSize) -> [CGPoint] {
        let lats = points.map { $0[0] }
        let lons = points.map { $0[1] }

        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }

        guard maxLat - minLat > 0 || maxLon - minLon > 0 else {
            return points.map { _ in CGPoint(x: size.width / 2, y: size.height / 2) }
        }

        let midLat  = (minLat + maxLat) / 2.0
        let cosLat  = cos(midLat * .pi / 180.0)

        let effectiveLatSpan = max(maxLat - minLat, 1e-9)
        let effectiveLonSpan = max((maxLon - minLon) * cosLat, 1e-9)

        let padding  = 0.10
        let drawW    = size.width  * (1 - 2 * padding)
        let drawH    = size.height * (1 - 2 * padding)
        let scale    = min(drawW / CGFloat(effectiveLonSpan),
                           drawH / CGFloat(effectiveLatSpan))

        let renderedW = CGFloat(effectiveLonSpan) * scale
        let renderedH = CGFloat(effectiveLatSpan) * scale
        let offsetX   = (size.width  - renderedW) / 2
        let offsetY   = (size.height - renderedH) / 2

        return points.map { pair in
            CGPoint(
                x: offsetX + CGFloat((pair[1] - minLon) * cosLat) * scale,
                y: offsetY + CGFloat(maxLat - pair[0]) * scale
            )
        }
    }
}
