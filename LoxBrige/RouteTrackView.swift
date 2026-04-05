import SwiftUI

/// Draws a GPS track as a purple line with orienteering-style markers:
///   △  hollow equilateral triangle at the start, apex rotated toward direction of travel
///   ◎  two concentric circles at the finish
///
/// Both symbols are inscribed in a circle of radius R so they appear the same visual size.
/// Supports pinch-to-zoom; double-tap resets to fit.
struct RouteTrackView: View {
    let points: [[Double]]

    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale:    CGFloat = 1.0

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let cg = normalized(points: points, in: size)
            let n  = cg.count

            let R:   CGFloat = 9
            let r1:  CGFloat = 5
            let gap: CGFloat = R + 2

            // MARK: Track
            let d0 = unit(cg[0], cg[1])
            let dN = unit(cg[n - 2], cg[n - 1])
            var track = Path()
            track.move(to: add(cg[0],     d0,  gap))
            for i in 1 ..< (n - 1) { track.addLine(to: cg[i]) }
            track.addLine(to: add(cg[n - 1], dN, -gap))
            context.stroke(track, with: .color(.purple),
                           style: StrokeStyle(lineWidth: 2, lineJoin: .round))

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
                .onEnded { value in
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

    // MARK: - Vector helpers

    private func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1e-6 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / len, y: dy / len)
    }

    private func add(_ p: CGPoint, _ d: CGPoint, _ dist: CGFloat) -> CGPoint {
        CGPoint(x: p.x + d.x * dist, y: p.y + d.y * dist)
    }

    // MARK: - Coordinate normalisation

    private func normalized(points: [[Double]], in size: CGSize) -> [CGPoint] {
        let lats = points.map { $0[0] }
        let lons = points.map { $0[1] }

        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }

        let latSpan = maxLat - minLat
        let lonSpan = maxLon - minLon

        guard latSpan > 0 || lonSpan > 0 else {
            return points.map { _ in CGPoint(x: size.width / 2, y: size.height / 2) }
        }

        let midLat  = (minLat + maxLat) / 2.0
        let cosLat  = cos(midLat * .pi / 180.0)

        let effectiveLatSpan = max(latSpan, 1e-9)
        let effectiveLonSpan = max(lonSpan * cosLat, 1e-9)

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
            let lat = pair[0], lon = pair[1]
            let x = offsetX + CGFloat((lon - minLon) * cosLat) * scale
            let y = offsetY + CGFloat(maxLat - lat) * scale
            return CGPoint(x: x, y: y)
        }
    }
}
