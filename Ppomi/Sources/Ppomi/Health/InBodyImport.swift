import Foundation
import AppKit
import Vision

struct InBodyReading: Equatable {
    var date: Date
    var metrics: [LifeMetric]
    var device: String?
    // A hidden device label on a list must not create a second identity on detail.
    var sourceID: String { "screen:\(LifeJSON.timestamp(date))" }
}

/// Reads dated result lists and result details. Missing labels, dates and values are never inferred.
enum InBodyImport {
    static let fields: [(label: String, code: String, title: String, unit: String)] = [
        ("체중", "weight", "체중", "kg"), ("골격근량", "skeletalMuscleMass", "골격근량", "kg"),
        ("체지방량", "bodyFatMass", "체지방량", "kg"), ("체지방률", "bodyFatPercent", "체지방률", "%"),
        ("세포외수분비", "extracellularWaterRatio", "세포외수분비", "ratio"),
        ("BMI", "bmi", "BMI", "kg/m2"), ("내장지방레벨", "visceralFatLevel", "내장지방레벨", "level")
    ]

    static func parse(_ raw: String) throws -> [InBodyReading] {
        let text = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
        guard text.range(of: "인바디|InBody", options: [.regularExpression, .caseInsensitive]) != nil else {
            throw LifeError.validation("인바디 결과 화면 아님 · 결과관리 목록·측정 상세 열기")
        }
        let datePattern = #"(?<!\d)(\d{4}|\d{2})[.\-/]\s*(\d{1,2})[.\-/]\s*(\d{1,2})\s*(?:\([^)\n]{1,5}\))?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d:])"#
        let re = try NSRegularExpression(pattern: datePattern)
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { throw LifeError.validation("측정 날짜·시각 없음 · 날짜 있는 상세 열기") }
        var readings: [InBodyReading] = []
        for (i, match) in matches.enumerated() {
            let parts = (1...5).map { Int(ns.substring(with: match.range(at: $0)))! }
            let year = parts[0] < 100 ? 2000 + parts[0] : parts[0]
            let seconds = match.range(at: 6).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 6)))!
            let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d+09:00", year, parts[1], parts[2], parts[3], parts[4], seconds)
            guard let date = LifeJSON.parseTimestamp(stamp) else { throw LifeError.validation("유효하지 않은 측정 날짜입니다: \(stamp)") }
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let section = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
            var metrics: [LifeMetric] = []
            for f in fields {
                let label = f.label.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
                let pattern = label + #"\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)(?![0-9.,])"#
                let mr = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                let sub = section as NSString
                let values = mr.matches(in: section, range: NSRange(location: 0, length: sub.length))
                    .compactMap { Double(sub.substring(with: $0.range(at: 1))) }
                guard let value = values.first else { continue }
                guard Set(values).count == 1 else { throw LifeError.validation("\(f.title) 값 불일치 · 측정 1건 상세 열기") }
                let metric = LifeMetric(code: f.code, title: f.title, value: value, unit: f.unit)
                try metric.validate(); metrics.append(metric)
            }
            guard !metrics.isEmpty else { continue }
            let deviceRE = try NSRegularExpression(pattern: #"(?:인바디\s*(?:다이얼\s*)?|InBody\s*(?:Dial\s*)?)(H\d{2}[A-Za-z0-9]*|\d{3}[A-Za-z]?)"#, options: .caseInsensitive)
            let sub = section as NSString
            let device = deviceRE.firstMatch(in: section, range: NSRange(location: 0, length: sub.length))
                .map { "InBody " + sub.substring(with: $0.range(at: 1)).uppercased() }
            readings.append(.init(date: date, metrics: metrics, device: device))
        }
        guard !readings.isEmpty else { throw LifeError.validation("날짜 연결 수치 없음") }
        return readings
    }

    static func recognize(_ url: URL) throws -> String {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LifeError.validation("읽을 수 있는 결과지 이미지가 필요합니다.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let words = (request.results ?? []).compactMap { item -> OCR.Word? in
            guard let text = item.topCandidates(1).first?.string else { return nil }
            let box = item.boundingBox
            return OCR.Word(x: box.minX, y: 1 - box.maxY, w: box.width, h: box.height, text: text)
        }
        return OCR.rows(words).joined(separator: "\n")
    }

    /// The app calls this only after an explicit import button. It captures no other Mac window.
    static func capture(to store: LifeStore) throws -> String {
        let folder = try prepareCaptureDirectory(for: store)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Phone.run(["capture", file.path])
        try protectCaptureFile(file)
        return try importImage(file, to: store)
    }

    static func prepareCaptureDirectory(for store: LifeStore) throws -> URL {
        let folder = URL(fileURLWithPath: store.path).deletingLastPathComponent().appendingPathComponent("capture-staging")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder
    }

    static func protectCaptureFile(_ file: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func importImage(_ file: URL, to store: LifeStore) throws -> String {
        let raw = try recognize(file)
        let readings = try parse(raw)
        return try save(readings, to: store) { [try store.addEvidence(from: file).id] }
    }

    static func save(_ readings: [InBodyReading], evidenceIDs: [String], to store: LifeStore) throws -> String {
        try save(readings, to: store) { evidenceIDs }
    }

    private static func save(_ readings: [InBodyReading], to store: LifeStore,
                             evidence: () throws -> [String]) throws -> String {
        let person = try store.ensureSelfEntity()
        var inserted = 0, enriched = 0, duplicates = 0, conflicts = 0
        var evidenceIDs: [String]?
        func evidenceForChange() throws -> [String] {
            if let evidenceIDs { return evidenceIDs }
            let value = try evidence(); evidenceIDs = value; return value
        }
        for reading in readings {
            let matches = try store.allRecords().filter {
                $0.subjectID == person.id && $0.sourceName == "InBody" && $0.kind == .measurement &&
                ($0.sourceRecordID == reading.sourceID ||
                 ($0.occurredAt == reading.date && $0.sourceRecordID?.hasPrefix(reading.sourceID + ":") == true))
            }
            // Existing ambiguous source identities need human reconciliation, never an arbitrary first match.
            guard matches.count <= 1 else { conflicts += 1; continue }
            if var previous = matches.first {
                let expectedPrevious = previous
                guard previous.occurredAt == reading.date else { conflicts += 1; continue }
                if let old = previous.device, let new = reading.device,
                   normalizeDevice(old) != normalizeDevice(new) { conflicts += 1; continue }
                let old = Dictionary(uniqueKeysWithValues: previous.metrics.map { ($0.code, $0) })
                if reading.metrics.contains(where: { new in old[new.code].map { $0.value != new.value || $0.unit != new.unit } ?? false }) {
                    conflicts += 1; continue
                }
                let added = reading.metrics.filter { old[$0.code] == nil }
                let addsDevice = previous.device == nil && reading.device != nil
                if added.isEmpty && !addsDevice { duplicates += 1; continue }
                previous.metrics += added
                if addsDevice { previous.device = reading.device }
                previous.evidenceIDs = Array(Set(previous.evidenceIDs + (try evidenceForChange()))).sorted()
                previous.review = .unreviewed
                try store.revise(previous, reason: "같은 인바디 측정의 추가 항목을 화면에서 읽음", expectedPrevious: expectedPrevious)
                enriched += 1
            } else {
                let record = LifeRecord(subjectID: person.id, kind: .measurement, occurredAt: reading.date,
                    sourceName: "InBody", sourceRecordID: reading.sourceID, method: .ocr,
                    metrics: reading.metrics, note: "앱에 표시된 측정 시각을 Asia/Seoul로 해석. 원본과 수치를 확인해 주세요.",
                    device: reading.device, evidenceIDs: try evidenceForChange())
                _ = try store.save(record); inserted += 1
            }
        }
        return "새 측정 \(inserted)건 · 항목 보완 \(enriched)건 · 기존 기록 \(duplicates)건" + (conflicts > 0 ? " · 값 충돌 \(conflicts)건 유지" : "")
    }

    private static func normalizeDevice(_ device: String) -> String {
        device.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
    }
}
