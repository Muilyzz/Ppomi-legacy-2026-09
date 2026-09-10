import XCTest
@testable import Ppomi

final class AgentBankProfileRequestsTests: XCTestCase {
    private final class Memory {
        var entries: [String: Data] = [:]
        var writes = 0
        var storage: IdentityProfileStore.Storage {
            .init(all: { self.entries.map { .init(account: $0.key, data: $0.value) } },
                  read: { self.entries[$0] },
                  write: { self.entries[$0] = $1; self.writes += 1 },
                  remove: { self.entries.removeValue(forKey: $0) })
        }
    }

    func testCardReturnsOnlyPresenceAndSavesOnceWithoutReplacingOtherProfileFields() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        try store.save(IdentityProfile(name: "합성 사람", birthDate: "2000-01-02"))
        let cards = AgentBankProfileRequests(store: store)
        let request = try cards.begin(["profile_id": "self", "bank_id": "kb"])
        let id = try XCTUnwrap(request["request_id"] as? String)
        XCTAssertEqual(request["registered"] as? [String: Bool], ["customer_name": false, "account_number": false])
        let reply = try cards.submit(["request_id": id, "values": ["customer_name": "합성(테스트)", "account_number": "001-234-567890"]])
        let body = try ProfileTools.json(reply)
        XCTAssertFalse(body.contains("합성")); XCTAssertFalse(body.contains("001234567890"))
        XCTAssertEqual(reply["registered"] as? [String: Bool], ["customer_name": true, "account_number": true])
        let profile = try XCTUnwrap(store.profile(id: "self"))
        XCTAssertEqual(profile.name, "합성 사람"); XCTAssertEqual(profile.birthDate, "2000-01-02")
        XCTAssertEqual(profile.bankProfiles?["kb"]?.accountNumber, "001234567890")
        let writes = memory.writes
        XCTAssertThrowsError(try cards.submit(["request_id": id, "values": [:]]))
        XCTAssertEqual(memory.writes, writes)
    }

    func testTokenCannotChangePersonBankOrCollectCredentialsAndIncompleteInputDoesNotWrite() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        let cards = AgentBankProfileRequests(store: store)
        XCTAssertThrowsError(try cards.begin(["profile_id": "self", "bank_id": "unverified"]))
        let request = try cards.begin(["profile_id": "self", "bank_id": "kb"])
        let id = try XCTUnwrap(request["request_id"] as? String)
        for args: [String: Any] in [
            ["request_id": id, "profile_id": "family", "values": ["customer_name": "합성"]],
            ["request_id": id, "values": ["password": "synthetic-secret"]],
            ["request_id": id, "values": ["customer_name": "합성"]],
            ["request_id": id, "values": ["customer_name": "", "account_number": "001234567890"]]
        ] {
            XCTAssertThrowsError(try cards.submit(args)) { XCTAssertFalse($0.localizedDescription.contains("synthetic-secret")) }
        }
        XCTAssertEqual(memory.writes, 0)
    }

    func testRegisteredValueIsNotExposedOrRecollectedAndConcurrentEditWins() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        try store.save(IdentityProfile(bankProfiles: ["kb": .init(customerName: "기존 합성명")]))
        let cards = AgentBankProfileRequests(store: store)
        let request = try cards.begin(["profile_id": "self", "bank_id": "kb"])
        XCTAssertFalse(try ProfileTools.json(request).contains("기존 합성명"))
        let id = try XCTUnwrap(request["request_id"] as? String)
        XCTAssertThrowsError(try cards.submit(["request_id": id, "values": ["customer_name": "새 합성명", "account_number": "001234567890"]]))
        _ = try store.updateBankProfile(id: "self", bankID: "kb", values: ["account_number": "009876543210"])
        let writes = memory.writes
        XCTAssertThrowsError(try cards.submit(["request_id": id, "values": ["account_number": "001234567890"]]))
        XCTAssertEqual(memory.writes, writes)
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles?["kb"]?.accountNumber, "009876543210")
    }

    func testCancelExpiryAndSessionInvalidationPreventLateSubmission() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        var clock = Date(timeIntervalSince1970: 1000)
        let cards = AgentBankProfileRequests(store: store, now: { clock })
        for reason in ["cancel", "expire", "session"] {
            let request = try cards.begin(["profile_id": "self", "bank_id": "kb"])
            let id = try XCTUnwrap(request["request_id"] as? String)
            if reason == "cancel" { _ = try cards.cancel(["request_id": id]) }
            if reason == "expire" { clock = clock.addingTimeInterval(601) }
            if reason == "session" { cards.invalidate() }
            XCTAssertThrowsError(try cards.submit(["request_id": id, "values": ["customer_name": "합성", "account_number": "001234567890"]]))
        }
        XCTAssertEqual(memory.writes, 0)
    }
}
