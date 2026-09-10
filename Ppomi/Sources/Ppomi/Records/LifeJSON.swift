// ISO8601 with a zone, for every shared archive. Moved out of LifeModel.swift so the iPad reads the same JSON.
import Foundation

enum LifeJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer(); try c.encode(timestamp(date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(); let raw = try c.decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO8601 시각에 시간대가 필요합니다: 2026-09-06T08:00:00+09:00")
            }
            return date
        }
        return decoder
    }
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func parseTimestamp(_ raw: String) -> Date? {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        if raw.contains(".") { f.formatOptions.insert(.withFractionalSeconds) }
        guard let date = f.date(from: raw) else { return nil }
        let offset: Int
        if raw.hasSuffix("Z") { offset = 0 }
        else {
            let suffix = String(raw.suffix(6)); let hours = Int(suffix.dropFirst().prefix(2)) ?? 99
            let minutes = Int(suffix.suffix(2)) ?? 99
            guard hours <= 14, minutes <= 59, hours < 14 || minutes == 0 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (suffix.first == "-" ? -1 : 1)
        }
        let verify = DateFormatter(); verify.locale = Locale(identifier: "en_US_POSIX")
        verify.calendar = Calendar(identifier: .gregorian); verify.timeZone = TimeZone(secondsFromGMT: offset)
        verify.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard verify.string(from: date) == String(raw.prefix(19)) else { return nil }
        return date
    }
}
