import Foundation

// Deterministic JSON encoding for stored values. Fact comparison
// ("did this entity's state change?") and dedupe both compare encoded
// text, so encoding must be byte-stable for equal values.

public enum CanonicalJSON {
    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
