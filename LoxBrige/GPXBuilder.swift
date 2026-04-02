import Foundation
import CoreLocation

struct GPXBuilder {
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func buildGPX(locations: [CLLocation]) -> String {
        var gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"LoxBridge\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        gpx += "  <trk>\n"
        gpx += "    <name>Activity Route</name>\n"
        gpx += "    <trkseg>\n"

        for location in locations {
            let timeString = formatter.string(from: location.timestamp)
            gpx += "      <trkpt lat=\"\(location.coordinate.latitude)\" lon=\"\(location.coordinate.longitude)\">\n"
            if location.verticalAccuracy >= 0 {
                gpx += "        <ele>\(location.altitude)</ele>\n"
            }
            gpx += "        <time>\(timeString)</time>\n"
            gpx += "      </trkpt>\n"
        }

        gpx += "    </trkseg>\n"
        gpx += "  </trk>\n"
        gpx += "</gpx>\n"
        return gpx
    }
}
