import SwiftUI
import MapKit

/// A non-interactive map that draws the GPS track, speed gradient and orienteering
/// symbols (△ start, ◎ finish) directly on the MKMapView, so there is no projection
/// mismatch between the route line and the map background.
struct StaticMapView: UIViewRepresentable {
    let points: [[Double]]
    var speeds: [Double]? = nil
    var satellite: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        map.isUserInteractionEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.mapType = satellite ? .hybridFlyover : .standard

        guard points.count >= 2 else { return }

        let coordinator = context.coordinator
        // Only rebuild overlays/annotations when the route data changes.
        guard coordinator.lastPoints != points else { return }
        coordinator.lastPoints = points
        coordinator.speeds = speeds

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let coords = points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }

        // Route polyline
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(polyline, level: .aboveRoads)

        // Start △ — angle in screen space (y increases downward, so negate dLat)
        let dLon = coords[1].longitude - coords[0].longitude
        let dLat = coords[1].latitude  - coords[0].latitude
        let startAngle = atan2(-dLat, dLon)

        map.addAnnotations([
            RouteEndAnnotation(coordinate: coords.first!, type: .start, angle: startAngle),
            RouteEndAnnotation(coordinate: coords.last!,  type: .finish, angle: 0),
        ])

        // Fit region with 50 % padding so symbols aren't clipped at the edges.
        let lats = coords.map(\.latitude);  let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude:  (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta:  max(maxLat - minLat, 0.001) * 1.5,
                longitudeDelta: max(maxLon - minLon, 0.001) * 1.5)),
            animated: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastPoints: [[Double]] = []
        var speeds: [Double]?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKGradientPolylineRenderer(polyline: polyline)
            if let sp = speeds, sp.count >= 2 {
                let n = sp.count
                let colors    = sp.map { speedUIColor($0) }
                let locations = (0 ..< n).map { CGFloat($0) / CGFloat(n - 1) }
                renderer.setColors(colors, locations: locations)
            } else {
                renderer.strokeColor = UIColor(red: 0.18, green: 0.50, blue: 0.12, alpha: 1)
            }
            renderer.lineWidth = 4
            renderer.lineCap  = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let end = annotation as? RouteEndAnnotation else { return nil }
            let view = RouteEndAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.pointType = end.type
            view.angle     = end.angle
            return view
        }

        private func speedUIColor(_ t: Double) -> UIColor {
            UIColor(hue: CGFloat(t / 3.0), saturation: 0.95, brightness: 0.82, alpha: 1)
        }
    }
}

// MARK: - Annotation model

final class RouteEndAnnotation: NSObject, MKAnnotation {
    enum PointType { case start, finish }
    let coordinate: CLLocationCoordinate2D
    let type: PointType
    let angle: Double

    init(coordinate: CLLocationCoordinate2D, type: PointType, angle: Double) {
        self.coordinate = coordinate; self.type = type; self.angle = angle
    }
}

// MARK: - Annotation view — draws △ or ◎ in Core Graphics

final class RouteEndAnnotationView: MKAnnotationView {
    var pointType: RouteEndAnnotation.PointType = .start
    var angle: Double = 0

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size: CGFloat = 22
        frame = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        backgroundColor = .clear
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.systemPurple.cgColor)
        ctx.setLineWidth(1.5)

        let cx = rect.midX, cy = rect.midY
        let R: CGFloat = 9

        switch pointType {
        case .start:
            let a = CGFloat(angle)
            ctx.move(to:    CGPoint(x: cx + R * cos(a),              y: cy + R * sin(a)))
            ctx.addLine(to: CGPoint(x: cx + R * cos(a + 2 * .pi / 3), y: cy + R * sin(a + 2 * .pi / 3)))
            ctx.addLine(to: CGPoint(x: cx + R * cos(a - 2 * .pi / 3), y: cy + R * sin(a - 2 * .pi / 3)))
            ctx.closePath()
            ctx.strokePath()

        case .finish:
            let r1: CGFloat = 5
            for r in [r1, R] {
                ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                ctx.strokePath()
            }
        }
    }
}
