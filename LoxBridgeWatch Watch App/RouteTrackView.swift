import SwiftUI

/// Draws a GPS track as a purple line with orienteering-style markers:
///   ▲  filled triangle at the start point
///   ◎  two concentric circles at the finish point
struct RouteTrackView: View {
    /// Raw [[lat, lon]] pairs from WatchRoutePayload
    let points: [[Double]]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }

            let cgPoints = normalized(points: points, in: size)

            // MARK: Track line
            var trackPath = Path()
            trackPath.move(to: cgPoints[0])
            for pt in cgPoints.dropFirst() {
                trackPath.addLine(to: pt)
            }
            context.stroke(
                trackPath,
                with: .color(.purple),
                style: StrokeStyle(lineWidth: 2, lineJoin: .round)
            )

            // MARK: Start — filled upward triangle (▲)
            let start = cgPoints[0]
            let side: CGFloat = 9
            let h = side * sqrt(3) / 2      // equilateral triangle height
            var triangle = Path()
            triangle.move(to: CGPoint(x: start.x, y: start.y - h * 2 / 3))
            triangle.addLine(to: CGPoint(x: start.x - side / 2, y: start.y + h / 3))
            triangle.addLine(to: CGPoint(x: start.x + side / 2, y: start.y + h / 3))
            triangle.closeSubpath()
            context.stroke(triangle, with: .color(.purple), lineWidth: 1.5)

            // MARK: Finish — double circle (◎)
            let finish = cgPoints[cgPoints.count - 1]
            let r1: CGFloat = 5     // inner radius
            let r2: CGFloat = 9     // outer radius
            context.stroke(
                Path(ellipseIn: CGRect(x: finish.x - r1, y: finish.y - r1,
                                       width: r1 * 2, height: r1 * 2)),
                with: .color(.purple), lineWidth: 1.5
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: finish.x - r2, y: finish.y - r2,
                                       width: r2 * 2, height: r2 * 2)),
                with: .color(.purple), lineWidth: 1.5
            )
        }
    }

    // MARK: - Coordinate normalisation

    /// Converts [[lat, lon]] geographic pairs to CGPoints scaled and centered
    /// to fit `size`, preserving aspect ratio with 10% padding on each edge.
    ///
    /// Uses a simple equirectangular projection with cosine-latitude correction
    /// so tracks in Scandinavia (~60° N) aren't stretched east-west.
    private func normalized(points: [[Double]], in size: CGSize) -> [CGPoint] {
        let lats = points.map { $0[0] }
        let lons = points.map { $0[1] }

        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }

        let latSpan = maxLat - minLat
        let lonSpan = maxLon - minLon

        // Single-point degenerate input
        guard latSpan > 0 || lonSpan > 0 else {
            return points.map { _ in CGPoint(x: size.width / 2, y: size.height / 2) }
        }

        // Cosine correction: at latitude φ, 1° of longitude ≈ cos(φ) × 1° of latitude
        let midLat = (minLat + maxLat) / 2.0
        let cosLat = cos(midLat * .pi / 180.0)

        let effectiveLatSpan = max(latSpan, 1e-9)
        let effectiveLonSpan = max(lonSpan * cosLat, 1e-9)

        // 10% padding on each side
        let padding = 0.10
        let drawW = size.width  * (1 - 2 * padding)
        let drawH = size.height * (1 - 2 * padding)

        let scale = min(drawW / CGFloat(effectiveLonSpan),
                        drawH / CGFloat(effectiveLatSpan))

        // Center the scaled track in the canvas
        let renderedW = CGFloat(effectiveLonSpan) * scale
        let renderedH = CGFloat(effectiveLatSpan) * scale
        let offsetX = (size.width  - renderedW) / 2
        let offsetY = (size.height - renderedH) / 2

        return points.map { pair in
            let lat = pair[0], lon = pair[1]
            let x = offsetX + CGFloat((lon - minLon) * cosLat) * scale
            // Invert Y: latitude increases northward but screen Y increases downward
            let y = offsetY + CGFloat(maxLat - lat) * scale
            return CGPoint(x: x, y: y)
        }
    }
}
