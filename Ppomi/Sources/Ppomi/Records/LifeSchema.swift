import Foundation

extension LifeStore {
    /// Local export only. Schema.org supplies shared meaning; ppomi terms retain provenance and review.
    /// Observation: https://schema.org/Observation (one quantitative observation per metric).
    /// Acquisition by OCR/API is not a physical measurement method and is kept in our namespace.
    func exportJSONLD() throws -> Data {
        // A single locked archive snapshot prevents mixing record versions across calls.
        let archive = try LifeJSON.decoder().decode(LifeArchive.self, from: exportJSON())
        return try LifeSchema.export(archive)
    }
}

enum LifeSchema {
    static let vocabulary = "https://ppomi.muilyzz.com/vocab/"

    static func export(_ archive: LifeArchive) throws -> Data {
        var graph: [[String: Any]] = archive.entities.map { entity in
            let type: String
            switch entity.kind {
            case .person: type = "Person"
            case .organization: type = "Organization"
            case .property: type = "Place"
            case .account: type = "Thing"
            case .device: type = "Product"
            }
            return ["@id": id("entity", entity.id), "@type": type, "name": entity.name,
                    "ppomi:entityKind": entity.kind.rawValue]
        }
        graph += archive.evidence.map { evidence in
            ["@id": id("evidence", evidence.id), "@type": "CreativeWork", "name": evidence.originalName,
             "ppomi:sha256": evidence.sha256, "ppomi:recordedAt": LifeJSON.timestamp(evidence.recordedAt)]
        }
        for record in archive.records {
            let recordID = id("record", record.id)
            var node: [String: Any] = [
                "@id": recordID, "@type": "ppomi:Record", "ppomi:kind": record.kind.rawValue,
                "ppomi:subject": ["@id": id("entity", record.subjectID)],
                "ppomi:occurredAt": LifeJSON.timestamp(record.occurredAt),
                "ppomi:recordedAt": LifeJSON.timestamp(record.recordedAt),
                "ppomi:sourceName": record.sourceName, "ppomi:acquisitionMethod": record.method.rawValue,
                "ppomi:review": record.review.rawValue,
                "ppomi:evidence": record.evidenceIDs.map { ["@id": id("evidence", $0)] }
            ]
            if let sourceID = record.sourceRecordID { node["ppomi:sourceRecordID"] = sourceID }
            if let note = record.note { node["description"] = note }
            if let device = record.device { node["ppomi:deviceLabel"] = device }
            if record.kind == .habit {
                node["@type"] = ["ppomi:Record", "ppomi:HabitConfirmation"]
                node["ppomi:activityID"] = record.activityID
                node["ppomi:activityStatus"] = record.activityStatus?.rawValue
                node["ppomi:activityDay"] = record.activityDay
                node["ppomi:activityTimeZone"] = record.activityTimeZone
                node["ppomi:confirmationTime"] = LifeJSON.timestamp(record.occurredAt)
                // Confirmation time is not the time sunscreen was actually applied.
            }
            if record.kind == .meal || record.kind == .exercise {
                node["@type"] = ["ppomi:Record", record.kind == .meal ? "EatAction" : "ExerciseAction"]
                node["agent"] = ["@id": id("entity", record.subjectID)]
                node["startTime"] = LifeJSON.timestamp(record.occurredAt)
                if record.kind == .exercise,
                   let minutes = record.metrics.first(where: { $0.code == "duration" && $0.unit == "min" }) {
                    node["endTime"] = LifeJSON.timestamp(record.occurredAt.addingTimeInterval(minutes.value * 60))
                }
            }
            let observationIDs = record.metrics.map { recordID + ":metric:" + encoded($0.code) }
            node["ppomi:observations"] = observationIDs.map { ["@id": $0] }
            graph.append(node)
            for (metric, observationID) in zip(record.metrics, observationIDs) {
                let property = metric.code == "weight" ? "https://schema.org/weight" : vocabulary + "metric/" + encoded(metric.code)
                graph.append([
                    "@id": observationID, "@type": "Observation", "name": metric.title,
                    "observationAbout": ["@id": id("entity", record.subjectID)],
                    "observationDate": LifeJSON.timestamp(record.occurredAt),
                    "measuredProperty": ["@id": property], "value": metric.value, "unitText": metric.unit,
                    "ppomi:record": ["@id": recordID], "ppomi:acquisitionMethod": record.method.rawValue,
                    "ppomi:review": record.review.rawValue
                ])
            }
        }
        for revision in archive.revisions {
            let previous = try JSONSerialization.jsonObject(with: LifeJSON.encoder().encode(revision.previous))
            graph.append([
                "@id": id("revision", revision.id), "@type": "ppomi:Revision",
                "ppomi:record": ["@id": id("record", revision.recordID)],
                "ppomi:replacedAt": LifeJSON.timestamp(revision.replacedAt), "description": revision.reason,
                "ppomi:previousRecord": ["@value": previous, "@type": "@json"]
            ])
        }
        return try JSONSerialization.data(withJSONObject: [
            "@context": ["@vocab": "https://schema.org/", "ppomi": vocabulary], "@graph": graph
        ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    private static func id(_ kind: String, _ value: String) -> String { "urn:ppomi:\(kind):" + encoded(value) }
    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }
}

enum LifeExamples {
    /// Synthetic, never inserted automatically. The UI can save this as an import template.
    /// Required envelope: formatVersion, entities, records. Optional: evidence, revisions.
    /// Required record: id, subjectID, kind, occurredAt, recordedAt, sourceName, method,
    /// review, metrics, evidenceIDs. Optional: sourceRecordID, note, device.
    /// Dates must be ISO8601 with Z or an explicit offset; missing values omit their metric.
    /// A sourceRecordID must be unique within sourceName; changed source facts raise a conflict.
    static func importTemplate() throws -> Data {
        let subject = LifeEntity(id: "example-person", kind: .person, name: "예시 사용자 — 실제 자료 아님")
        let occurred = LifeJSON.parseTimestamp("2026-09-06T08:00:00+09:00")!
        let collected = LifeJSON.parseTimestamp("2026-09-06T08:05:00+09:00")!
        let record = LifeRecord(id: "example-measurement-001", subjectID: subject.id, kind: .measurement,
                                occurredAt: occurred, recordedAt: collected, sourceName: "인바디 결과지 예시",
                                sourceRecordID: "example-only-001", method: .manual,
                                metrics: [.init(code: "weight", title: "체중", value: 72.3, unit: "kg"),
                                          .init(code: "bodyFatPercent", title: "체지방률", value: 20.1, unit: "%"),
                                          .init(code: "skeletalMuscleMass", title: "골격근량", value: 31.2, unit: "kg")],
                                note: "가상의 예시입니다. 실제 값·측정 시각·대상 ID로 바꾸세요.", device: "예시 기기")
        return try LifeJSON.encoder().encode(LifeArchive(entities: [subject], records: [record]))
    }
}
