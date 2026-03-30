import Foundation
import OSLog

enum AppLogger {
    static let subsystem = "com.loxbrige"
    static let healthKit = Logger(subsystem: subsystem, category: "HealthKit")
    static let workout = Logger(subsystem: subsystem, category: "Workout")
    static let route = Logger(subsystem: subsystem, category: "Route")
    static let notification = Logger(subsystem: subsystem, category: "Notification")
    static let upload = Logger(subsystem: subsystem, category: "Upload")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
}
