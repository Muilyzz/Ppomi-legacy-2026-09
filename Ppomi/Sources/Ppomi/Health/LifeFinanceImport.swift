import Foundation

/// A source-backed projection, not an ownership assertion or a replacement for the existing ledger.
enum LifeFinanceImport {
    static func run(to store: LifeStore, dbPath: String = AppSettings.dbPath) throws -> String {
        let sourceURL = URL(fileURLWithPath: dbPath).standardizedFileURL.resolvingSymlinksInPath()
        let original = try DB(path: sourceURL.path) // READONLY: no migration of the source ledger.
        let namespace = try store.sourceNamespace(for: "ledger:" + sourceURL.path)
        let existing = Dictionary(uniqueKeysWithValues: try store.allRecords().filter { $0.sourceName == "기존 금융 장부" }
            .compactMap { record in record.sourceRecordID.map { ($0, record) } })
        var inserted = 0, duplicates = 0, conflicts = 0, skipped = 0
        var cachedEvidence: [String: String] = [:]
        let tables = Set(try original.rows("SELECT name FROM sqlite_master WHERE type='table'", limit: Int.max).compactMap { $0.first as? String })

        func accountID(_ reference: [String]) throws -> String {
            let key = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
            return try store.sourceNamespace(for: "legacy-account:" + namespace + ":" + key)
        }
        func note(_ metadata: [String: String]) throws -> String {
            let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            return "기존 장부의 관측 기록입니다. 계좌 소유자와 실제 잔액은 별도 확인이 필요합니다. 원본 상태 confirmed도 사용자 검토를 의미하지 않습니다. 금액 부호는 원본 그대로이며 거래 종류를 함께 확인하세요.\n" + String(decoding: json, as: UTF8.self)
        }
        func save(_ value: LifeRecord, shot: String?) throws {
            var value = value
            let previous = value.sourceRecordID.flatMap { existing[$0] }
            if let previous { value.evidenceIDs = previous.evidenceIDs }
            else if let shot, let url = safeEvidenceURL(shot: shot, sourceURL: sourceURL) {
                if let id = cachedEvidence[url.path] { value.evidenceIDs = [id] }
                else {
                    let evidence = try store.addEvidence(from: url)
                    cachedEvidence[url.path] = evidence.id; value.evidenceIDs = [evidence.id]
                }
            }
            do {
                switch try store.save(value) {
                case .inserted: inserted += 1
                case .duplicate: duplicates += 1
                }
            } catch LifeError.conflict { conflicts += 1 }
        }

        if tables.contains("snapshots") {
            let columns = Set(try original.rows("PRAGMA table_info(snapshots)", limit: Int.max).compactMap { $0.count > 1 ? $0[1] as? String : nil })
            guard Set(["id", "ts", "app", "account", "balance"]).isSubset(of: columns) else { throw LifeError.validation("기존 잔액 장부의 필수 항목이 없습니다.") }
            let shotSQL = columns.contains("shot") ? "shot" : "NULL"
            for row in try original.rows("SELECT id,ts,app,account,balance,\(shotSQL) FROM snapshots ORDER BY id", limit: Int.max) {
                guard let id = row[0] as? Int, let timestamp = row[1] as? String, let date = parseLegacyTimestamp(timestamp),
                      let balance = number(row[4]), let app = row[2] as? String, !app.isEmpty,
                      let label = row[3] as? String, !label.isEmpty else { skipped += 1; continue }
                let subjectID = try accountID(["snapshot", app, label])
                try store.save(entity: LifeEntity(id: subjectID, kind: .account, name: "\(app) · \(label) (기존 장부)"))
                let shot = row[5] as? String
                let metadata = ["legacyNamespace": namespace, "legacyTable": "snapshots", "legacyRowID": String(id),
                                "legacyTimestamp": timestamp, "interpretedTimeZone": timeZoneDescription(timestamp), "app": app,
                                "rawAccountLabel": label, "originalShotName": safeShotLabel(shot), "ownership": "unverified"]
                let value = LifeRecord(subjectID: subjectID, kind: .financialSnapshot, occurredAt: date,
                    sourceName: "기존 금융 장부", sourceRecordID: "\(namespace):snapshots:\(id)", method: .legacyImport,
                    metrics: [.init(code: "balance", title: "원본 잔액", value: balance, unit: "KRW")], note: try note(metadata))
                try save(value, shot: shot)
            }
        }
        if tables.contains("transactions") {
            let columns = Set(try original.rows("PRAGMA table_info(transactions)", limit: Int.max).compactMap { $0.count > 1 ? $0[1] as? String : nil })
            guard Set(["id", "ts", "kind", "amount"]).isSubset(of: columns) else { throw LifeError.validation("기존 거래 장부의 필수 항목이 없습니다.") }
            let optional = ["merchant", "card", "source", "status", "uid"].map { columns.contains($0) ? $0 : "NULL" }.joined(separator: ",")
            for row in try original.rows("SELECT id,ts,kind,amount,\(optional) FROM transactions ORDER BY id", limit: Int.max) {
                guard let id = row[0] as? Int, let timestamp = row[1] as? String, let date = parseLegacyTimestamp(timestamp),
                      let kind = row[2] as? String, let amount = number(row[3]) else { skipped += 1; continue }
                let source = row[6] as? String ?? "미상"
                let app = source.hasPrefix("app:") && source.count > 4 ? String(source.dropFirst(4)) : "앱 미상"
                // Even matching snapshot/card labels do not establish a transaction's account.
                let subjectID = try accountID(["unassigned-transaction", app])
                try store.save(entity: LifeEntity(id: subjectID, kind: .account, name: "\(app) · 계좌 미지정 거래 (기존 장부)"))
                let metadata = ["legacyNamespace": namespace, "legacyTable": "transactions", "legacyRowID": String(id),
                                "legacyTimestamp": timestamp, "interpretedTimeZone": timeZoneDescription(timestamp), "app": app,
                                "source": source, "originalKind": kind, "originalAmount": String(amount),
                                "merchant": row[4] as? String ?? "", "rawCardLabel": row[5] as? String ?? "",
                                "originalStatus": row[7] as? String ?? "", "originalUID": row[8] as? String ?? "",
                                "ownership": "unverified", "accountAssignment": "unassigned"]
                let value = LifeRecord(subjectID: subjectID, kind: .financialTransaction, occurredAt: date,
                    sourceName: "기존 금융 장부", sourceRecordID: "\(namespace):transactions:\(id)", method: .legacyImport,
                    metrics: [.init(code: "amount", title: "원본 거래 금액", value: amount, unit: "KRW")], note: try note(metadata))
                try save(value, shot: nil)
            }
        }
        return "금융 관측 \(inserted)건 추가 · 기존 \(duplicates)건 · 값 충돌 \(conflicts)건 · 형식 미확인 \(skipped)건. 소유자·계좌 연결은 추정하지 않았습니다."
    }

    static func parseLegacyTimestamp(_ text: String) -> Date? {
        if let date = LifeJSON.parseTimestamp(text) { return date }
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let iso = text.replacingOccurrences(of: " ", with: "T") + (text.count == 16 ? ":00" : "") + "+09:00"
        return LifeJSON.parseTimestamp(iso)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Int { return Double(exactly: value) }
        if let value = value as? Double, value.isFinite { return value }
        return nil
    }
    private static func timeZoneDescription(_ text: String) -> String {
        LifeJSON.parseTimestamp(text) == nil ? "Asia/Seoul" : "원본의 명시된 시간대"
    }
    private static func safeShotLabel(_ shot: String?) -> String {
        guard let shot, shot == (shot as NSString).lastPathComponent, !shot.contains("\\"), !shot.contains("..") else { return "경로 미사용" }
        return shot
    }
    static func safeEvidenceURL(shot: String, sourceURL: URL) -> URL? {
        guard !shot.isEmpty, safeShotLabel(shot) == shot,
              ["png", "jpg", "jpeg", "pdf"].contains((shot as NSString).pathExtension.lowercased()) else { return nil }
        let folder = sourceURL.deletingLastPathComponent().appendingPathComponent("shots")
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: folder.path)[.type]) as? FileAttributeType == .typeDirectory else { return nil }
        let file = folder.appendingPathComponent(shot)
        guard let attrs = try? fm.attributesOfItem(atPath: file.path), attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= 32 * 1024 * 1024 else { return nil }
        return file
    }
}
