import Foundation
import CoreLocation

/// Lightweight XML parser that extracts `<trkpt>` elements from a GPX 1.1 file
/// and returns them as `CLLocation` objects.
///
/// Only latitude, longitude, elevation, and timestamp are read; all other elements
/// are ignored. This is intentionally minimal — no external dependencies required.
final class TrkptParser: NSObject, XMLParserDelegate {

    private var locations: [CLLocation] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentTime: Date?
    private var inTrkpt  = false
    private var inEle    = false
    private var inTime   = false
    private var buffer   = ""

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parse(data: Data) -> [CLLocation] {
        locations = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return locations
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "trkpt" {
            inTrkpt = true
            currentLat = attributes["lat"].flatMap { Double($0) }
            currentLon = attributes["lon"].flatMap { Double($0) }
            currentEle = nil
            currentTime = nil
        } else if inTrkpt && elementName == "ele" {
            inEle = true
            buffer = ""
        } else if inTrkpt && elementName == "time" {
            inTime = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEle || inTime {
            buffer += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "ele" && inEle {
            currentEle = Double(buffer.trimmingCharacters(in: .whitespaces))
            inEle = false
        } else if elementName == "time" && inTime {
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            currentTime = Self.isoFormatter.date(from: trimmed)
                ?? Self.isoFormatterNoFrac.date(from: trimmed)
            inTime = false
        } else if elementName == "trkpt" && inTrkpt {
            if let lat = currentLat, let lon = currentLon, let time = currentTime {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let alt = currentEle ?? 0
                // verticalAccuracy -1 means no altitude; set to -1 when no ele element.
                let vAcc: CLLocationAccuracy = currentEle != nil ? 5.0 : -1.0
                let loc = CLLocation(
                    coordinate: coord,
                    altitude: alt,
                    horizontalAccuracy: 5.0,
                    verticalAccuracy: vAcc,
                    timestamp: time
                )
                locations.append(loc)
            }
            inTrkpt = false
        }
    }
}
