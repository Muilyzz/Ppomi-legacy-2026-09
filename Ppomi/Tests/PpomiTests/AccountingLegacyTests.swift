import XCTest
@testable import Ppomi

final class AccountingLegacyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_825_600)

    func testBundledJournalPreservesCollectorCasesAndRulePriority() throws {
        let rules = try LegacyAccountingRules.loadBundled()
        let bank = "카카오뱅크 AI 관련 지출 통장"
        let rows = [
            transaction("approval", .approval, "openai"),
            transaction("default", .withdrawal, "일반 상점"),
            transaction("card-refund", .deposit, "APPLE 이자", tag: "체크카드"),
            transaction("cash-in", .deposit, "ATM입금"),
            transaction("interest", .deposit, "예금 이자"),
            transaction("own-in", .deposit, "Owner"),
            transaction("income", .deposit, "기타 입금"),
            transaction("cash-out", .withdrawal, "축의", tag: "ATM"),
            transaction("own-out", .withdrawal, "Owner Amazon"),
            transaction("no-inference", .withdrawal, "openai", tag: "ATM"),
            transaction("cancel", .cancel, "택시")
        ]
        let expected = [
            line("approval", dr: "역량", cr: bank, memo: " openai"),
            line("default", dr: "유지", cr: bank, memo: " 일반 상점"),
            line("card-refund", dr: bank, cr: "역량", memo: "체크카드 APPLE 이자 환불", reversed: true),
            line("cash-in", dr: bank, cr: "현금(수중)", memo: " ATM입금"),
            line("interest", dr: bank, cr: "이자수입", memo: " 예금 이자"),
            line("own-in", dr: bank, cr: "내 다른 계좌(미확인)", memo: " Owner"),
            line("income", dr: bank, cr: "수입(미분류)", memo: " 기타 입금"),
            line("cash-out", dr: "현금(수중)", cr: bank, memo: "ATM 축의"),
            line("cash-out", dr: "관계", cr: "현금(수중)", memo: "↳ 축의 (메모에서 추정)", index: 1, inferred: true),
            line("own-out", dr: "현금(수중)", cr: bank, memo: " Owner Amazon"),
            line("own-out", dr: "역량", cr: "현금(수중)", memo: "↳ Owner Amazon (메모에서 추정)", index: 1, inferred: true),
            line("no-inference", dr: "현금(수중)", cr: bank, memo: "ATM openai"),
            line("cancel", dr: bank, cr: "시간", memo: " 택시 취소", reversed: true)
        ]
        XCTAssertEqual(rules.journal(rows, me: "Owner"), expected)
        XCTAssertEqual(Rules.journal(rows, me: "Owner"), expected)
        XCTAssertEqual(Rules.title("UNKNOWN"), "UNKNOWN")
        XCTAssertEqual(Rules.account["KB"]?.pattern, "ONE통장")
        XCTAssertEqual(rules.journal([transaction("literal", .approval, "merchant", tag: "{merchant}")], me: "").first?.memo,
                       "{merchant} merchant", "Template expansion must preserve the literal source tag.")
    }

    func testArchivePreservesExpensesRefundsIncomeTransfersAndSkipsInference() throws {
        let ledger = Ledger(
            accounts: [Account(id: "은행 A", app: "SOURCE", title: "원본"), Account(id: "은행 B", app: "SOURCE", title: "원본")],
            lines: [
                line("spend", dr: "시간", cr: "은행 A", amount: 100),
                line("refund", dr: "은행 A", cr: "시간", amount: 20, reversed: true),
                line("income", dr: "은행 A", cr: "수입(미분류)", amount: 200),
                line("transfer", dr: "은행 B", cr: "은행 A", amount: 50),
                line("inferred", dr: "역량", cr: "현금(수중)", amount: 90, inferred: true)
            ], defaultLens: Lens(name: "경계", inside: ["은행 A", "은행 B"]))
        let archive = try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "database-A")
        XCTAssertEqual(archive.books.count, 1)
        let book = try XCTUnwrap(archive.books.first)
        XCTAssertEqual(book.id, "legacy:database-A")
        XCTAssertEqual(book.ownerID, "legacy:database-A")
        XCTAssertTrue(book.name.contains("소유 미확인"))
        XCTAssertEqual(book.kind, .financial)
        XCTAssertEqual(book.unit.id, "KRW")
        XCTAssertEqual(book.unit.dimension, .currency, "The label 시간 does not turn monetary spending into a time resource.")
        XCTAssertEqual(book.unit.scale, 0)
        XCTAssertEqual(archive.entries.count, 4)
        XCTAssertEqual(archive.entries.compactMap(\.sourceRecordID), ["spend#0", "refund#0", "income#0", "transfer#0"])
        XCTAssertTrue(archive.entries.allSatisfy { $0.layer == .recorded && $0.assessment == nil && $0.source == "legacy-ledger" })
        XCTAssertTrue(archive.entries.allSatisfy { $0.recordedAt == date && $0.occurredAt == date })
        let balances = try AccountingEngine.balances(in: archive, bookID: book.id, includeAdjustments: false)
        let accounts = Dictionary(uniqueKeysWithValues: archive.accounts.map { ($0.name, $0) })
        XCTAssertEqual(accounts["시간"]?.kind, .expense)
        XCTAssertEqual(accounts["수입(미분류)"]?.kind, .income)
        XCTAssertEqual(accounts["은행 A"]?.kind, .asset)
        XCTAssertEqual(balances[try XCTUnwrap(accounts["시간"]).id], 80)
        XCTAssertEqual(balances[try XCTUnwrap(accounts["은행 A"]).id], 70)
        XCTAssertEqual(balances[try XCTUnwrap(accounts["은행 B"]).id], 50)
        XCTAssertEqual(balances.values.reduce(0, +), 0)
        XCTAssertNil(accounts["역량"], "An inferred memo must not create an imported asset or expense.")
    }

    func testIDsAreStableNamespacedAndDistinctTransactionsAreNeverMerged() throws {
        let ledger = Ledger(lines: [line("uid-1", dr: "custom", cr: "bank"), line("uid-2", dr: "custom", cr: "bank")],
                            defaultLens: Lens(name: "scope", inside: ["bank"]))
        let first = try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "same")
        XCTAssertEqual(first, try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "same"))
        let other = try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "other")
        XCTAssertTrue(Set(first.accounts.map(\.id)).isDisjoint(with: other.accounts.map(\.id)))
        XCTAssertTrue(Set(first.entries.map(\.id)).isDisjoint(with: other.entries.map(\.id)))
        XCTAssertEqual(Set(first.entries.map(\.eventID)).count, 2)
        XCTAssertEqual(first.entries.count, 2)
        XCTAssertEqual(first.accounts.first { $0.name == "custom" }?.kind, .expense)
        XCTAssertEqual(first.accounts.first { $0.name == "bank" }?.kind, .asset)
        XCTAssertThrowsError(try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "  "))
        var duplicate = ledger
        duplicate.lines.append(ledger.lines[0])
        XCTAssertThrowsError(try AccountingLegacyAdapter.archive(ledger: duplicate, namespace: "same"), "Duplicate IDs fail explicitly rather than silently removing transactions.")
        var multipleLines = ledger
        multipleLines.lines.append(line("uid-1", dr: "custom", cr: "bank", index: 1))
        let multiple = try AccountingLegacyAdapter.archive(ledger: multipleLines, namespace: "same")
        XCTAssertEqual(multiple.entries.count, 3, "Distinct observed line IDs on one source UID remain separate postings.")
        XCTAssertEqual(Set(multiple.entries.map(\.eventID)).count, 2)
    }

    func testNewCategoriesAndSourceAccountsAreOnlyConfiguration() throws {
        let rules = try configuration { object in
            var categories = object["capitals"] as! [[String: String]]
            categories.insert(["pattern": "CUSTOM-LESSON", "capital": "전문 역량 준비"], at: 0)
            object["capitals"] = categories
            var kinds = object["accountKinds"] as! [String: String]
            kinds["전문 역량 준비"] = "expense"
            kinds["새 기본 비용"] = "expense"
            object["accountKinds"] = kinds
            object["defaultCapital"] = "새 기본 비용"
            var accounts = object["accounts"] as! [String: [String: String]]
            accounts["CUSTOM"] = ["pattern": "입출금", "name": "사용자 계좌"]
            object["accounts"] = accounts
        }
        let rows = [transaction("custom", .approval, "CUSTOM-LESSON", app: "CUSTOM"),
                    transaction("default", .approval, "no match", app: "CUSTOM")]
        let lines = rules.journal(rows, me: "")
        XCTAssertEqual(lines.map(\.dr), ["전문 역량 준비", "새 기본 비용"])
        XCTAssertEqual(lines.map(\.cr), ["사용자 계좌", "사용자 계좌"])
        let ledger = Ledger(lines: lines, defaultLens: Lens(name: "경계", inside: ["사용자 계좌"]))
        let archive = try AccountingLegacyAdapter.archive(ledger: ledger, namespace: "custom", rules: rules)
        XCTAssertEqual(archive.accounts.first { $0.name == "전문 역량 준비" }?.kind, .expense)
        XCTAssertEqual(archive.accounts.first { $0.name == "새 기본 비용" }?.kind, .expense)
        XCTAssertEqual(archive.books.first?.unit.dimension, .currency)
    }

    func testInvalidClassificationDataFailsBeforeJournalGeneration() throws {
        XCTAssertThrowsError(try configuration { $0["formatVersion"] = 99 })
        XCTAssertThrowsError(try configuration { $0["capitals"] = [["pattern": "[", "capital": "유지"]] })
        XCTAssertThrowsError(try configuration { $0["journalRules"] = [] })
        XCTAssertThrowsError(try configuration { $0["defaultCapital"] = "missing-kind" })
        XCTAssertThrowsError(try configuration { $0["defaultSpendingCategory"] = "missing-category" })
        XCTAssertThrowsError(try configuration { $0["spendingRules"] = [["pattern": "", "capital": "카페"]] })
        XCTAssertThrowsError(try configuration { $0["spendingRules"] = [["pattern": "x", "capital": "missing-category"]] })
        XCTAssertThrowsError(try configuration { object in
            var rules = object["journalRules"] as! [[String: Any]]
            rules[0]["debit"] = ["source": "named"]
            object["journalRules"] = rules
        })
    }

    private func transaction(_ uid: String, _ kind: Transaction.Kind, _ merchant: String,
                             tag: String = "", app: String = "KAKAO") -> Transaction {
        Transaction(id: 1, ts: date, kind: kind, amount: 100, merchant: merchant, tag: tag,
                    cumulative: nil, app: app, uid: uid)
    }

    private func line(_ uid: String, dr: String, cr: String, amount: Int = 100, memo: String = "same transaction",
                      index: Int = 0, reversed: Bool = false, inferred: Bool = false) -> JournalLine {
        JournalLine(id: "\(uid)#\(index)", ts: date, memo: memo, dr: dr, cr: cr, amount: amount,
                    rev: reversed, inferred: inferred, uid: uid)
    }

    private func configuration(_ change: (inout [String: Any]) -> Void) throws -> LegacyAccountingRules {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Ppomi/AccountingData/legacy-rules.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&object)
        return try LegacyAccountingRules.decode(data: JSONSerialization.data(withJSONObject: object))
    }
}
