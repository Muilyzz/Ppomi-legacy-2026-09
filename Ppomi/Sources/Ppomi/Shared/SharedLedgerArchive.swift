// 서버의 ledger 기록 = 원본 스냅샷·거래의 버전 있는 보관본. Mac 이 담고(capture, SharedRecordsSource) 어느 기기든 같은 규칙으로 장부를 만든다(ledger()).
import Foundation

/// A versioned source archive, not a balance computed by a second accounting engine.
struct SharedLedgerArchive: Codable {
    struct Snapshot: Codable { let app: String; let account: String; let balance: Int; let ts: Date }
    var formatVersion = 1
    var snapshots: [Snapshot]
    var transactions: [Transaction]
    var me: String
    // Exact original rows retain stable source IDs, status, raw observations and provenance.
    var originalTables: Data
    var lenses: [Lens]?          // 계좌 그룹(없는 옛 기록은 nil)
    var nodes: [String: [Int]]?  // 그룹 밖 계좌 노드의 자리
    // Optional presentation from the common native ledger engine. Older readers
    // ignore it; browsers can use the exact Mac result without a second engine.
    var timelinePresentation: Data? = nil

    func ledger() throws -> Ledger {
        guard formatVersion == 1 else { throw SharedRecordError.invalid }
        return Ledger.load(snapshots: snapshots.map { ($0.app, $0.account, $0.balance, $0.ts) }, transactions: transactions, me: me, lenses: lenses ?? [], nodes: nodes ?? [:])
    }
}
