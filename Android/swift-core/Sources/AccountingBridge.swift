import Foundation

/// The bridge owns transport formatting only. Validation and arithmetic stay in AccountingEngine.
public enum SharedAccountingJSON {
    public static let maximumInputBytes = 4 * 1024 * 1024

    public static func report(_ input: Data) -> Data {
        do {
            guard input.count <= maximumInputBytes else {
                return failure("input_too_large", "회계 자료는 4 MiB까지 검증합니다.")
            }
            let archive = try LifeJSON.decoder().decode(AccountingArchive.self, from: input)
            try AccountingEngine.validate(archive)
            let reports = try archive.books.sorted { $0.id < $1.id }.map { book in
                BookReport(
                    book: book,
                    scope: book.effectiveScope,
                    accounts: archive.accounts.filter { $0.bookID == book.id }.sorted { $0.id < $1.id },
                    recordedBalances: try AccountingEngine.balances(in: archive, bookID: book.id, includeAdjustments: false),
                    adjustedBalances: try AccountingEngine.balances(in: archive, bookID: book.id, includeAdjustments: true),
                    recordedEntries: try AccountingEngine.entries(in: archive, bookID: book.id, includeAdjustments: false),
                    adjustedEntries: try AccountingEngine.entries(in: archive, bookID: book.id, includeAdjustments: true)
                )
            }
            return try LifeJSON.encoder().encode(Report(ok: true, core: "Swift", schemaVersion: 1,
                                                      sourceHashes: CanonicalSourceIdentity.hashes, books: reports))
        } catch let error as AccountingError {
            return failure("accounting_validation", error.localizedDescription)
        } catch let error as RecordScopeError {
            return failure("scope_validation", error.localizedDescription)
        } catch is DecodingError {
            return failure("invalid_archive_json", "회계 자료 JSON 형식, 정수 최소단위 또는 ISO8601 시각을 확인하세요.")
        } catch {
            return failure("report_error", "공통 회계 보고서를 만들 수 없습니다.")
        }
    }

    private struct BookReport: Encodable {
        var book: AccountingBook
        var scope: RecordScope
        var accounts: [AccountingAccount]
        var recordedBalances: [String: Int]
        var adjustedBalances: [String: Int]
        var recordedEntries: [AccountingEntry]
        var adjustedEntries: [AccountingEntry]
    }
    private struct Report: Encodable {
        var ok: Bool
        var core: String
        var schemaVersion: Int
        var sourceHashes: [String: String]
        var books: [BookReport]
    }
    private struct Failure: Encodable {
        var ok = false
        var core = "Swift"
        var code: String
        var error: String
    }
    private static func failure(_ code: String, _ message: String) -> Data {
        // Only finite strings and booleans are encoded; no error reaches the ABI boundary.
        (try? LifeJSON.encoder().encode(Failure(code: code, error: message)))
            ?? Data(#"{"ok":false,"core":"Swift","code":"encoding_error"}"#.utf8)
    }
}

/// Input is UTF-8 bytes, output is an owned, NUL-terminated UTF-8 string.
/// Java uses byte arrays at JNI so supplementary Unicode is not modified-UTF-8 encoded.
@_cdecl("ppomi_accounting_report")
public func ppomiAccountingReport(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> UnsafeMutablePointer<CChar>? {
    guard let bytes, count >= 0, count <= SharedAccountingJSON.maximumInputBytes else { return nil }
    let result = SharedAccountingJSON.report(Data(bytes: bytes, count: count))
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: result.count + 1)
    for (index, byte) in result.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[result.count] = 0
    return buffer
}

@_cdecl("ppomi_accounting_free")
public func ppomiAccountingFree(_ pointer: UnsafeMutablePointer<CChar>?) { pointer?.deallocate() }
