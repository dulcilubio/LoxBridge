import Foundation

extension Dictionary where Key == String, Value == Any {
    /// Returns a copy of the dictionary with all values converted to their `String` representation.
    func normalizedStringValues() -> [String: String] {
        mapValues { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return "\(value)"
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// Returns the first non-empty value found for the given ordered list of keys.
    func firstValue(forKeys keys: [String]) -> String? {
        for key in keys {
            if let value = self[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
