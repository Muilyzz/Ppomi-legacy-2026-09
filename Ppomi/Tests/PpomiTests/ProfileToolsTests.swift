import XCTest
@testable import Ppomi

final class ProfileToolsTests: XCTestCase {
    private final class Memory {
        var values: [String: Data] = [:]
        var store: IdentityProfileStore {
            IdentityProfileStore(storage: .init(all: { self.values.map { .init(account: $0.key, data: $0.value) } },
                                                read: { self.values[$0] }, write: { self.values[$0] = $1 }, remove: { self.values.removeValue(forKey: $0) }))
        }
    }

    func testConversationSavePartialUpdateAndDeleteNeverEchoIdentityValues() throws {
        let memory = Memory(), store = memory.store
        let secretName = "합성 테스트", birth = "2000-01-02", phone = "01012345678"
        let response = try ProfileTools.save(["name": secretName, "birth_date": birth, "phone": phone, "carrier": "kt"], store: store)
        let list = try ProfileTools.list([:], store: store)
        for value in [secretName, birth, phone] { XCTAssertFalse(response.contains(value)); XCTAssertFalse(list.contains(value)) }
        XCTAssertTrue(response.contains("registered")); XCTAssertTrue(response.contains("saved"))
        _ = try ProfileTools.save(["carrier": "skt"], store: store)
        XCTAssertEqual(try store.profile(id: "self")?.name, secretName)
        XCTAssertEqual(try store.profile(id: "self")?.carrier, "skt")
        _ = try ProfileTools.save(["profile_id": "family", "label": "가족", "name": "합성 가족"], store: store)
        _ = try ProfileTools.save(["phone": ""], store: store)
        XCTAssertNil(try store.profile(id: "self")?.phone)
        _ = try ProfileTools.remove(["profile_id": "self"], store: store)
        XCTAssertEqual(try store.list().map(\.id), ["family"])
    }

    func testCredentialKeysBadTypesAndUnspecifiedDeletionAreRejected() throws {
        let memory = Memory(), store = memory.store
        for key in ["password", "resident_number", "card_number", "otp", "approved"] {
            XCTAssertThrowsError(try ProfileTools.save([key: "never-save-this"], store: store)) { XCTAssertFalse($0.localizedDescription.contains("never-save-this")) }
        }
        XCTAssertThrowsError(try ProfileTools.save(["phone": 1012345678], store: store))
        XCTAssertThrowsError(try ProfileTools.save([:], store: store))
        XCTAssertThrowsError(try ProfileTools.remove([:], store: store))
        XCTAssertTrue(memory.values.isEmpty)
    }

    func testBusinessConversationUpdatesClearFieldsAndReturnOnlyPresenceFlags() throws {
        let memory = Memory(), store = memory.store
        let ownName = "합성 대화 상호 (1호)", ownNumber = "1234567890", familyNumber = "9876543210"
        _ = try ProfileTools.save(["name": "합성 본인", "phone": "01012345678", "carrier": "skt"], store: store)
        let saved = try ProfileTools.save(["business_name": ownName, "business_registration_number": "123-45-67890"], store: store)
        _ = try ProfileTools.save(["profile_id": "family", "business_name": "합성 가족 상호", "business_registration_number": familyNumber], store: store)
        let listed = try ProfileTools.list([:], store: store)
        for secret in [ownName, ownNumber, familyNumber, "123-45-67890", "합성 본인", "01012345678", "합성 가족 상호"] {
            XCTAssertFalse(saved.contains(secret)); XCTAssertFalse(listed.contains(secret))
        }
        let status = ProfileTools.status(try XCTUnwrap(store.profile(id: "self")))
        XCTAssertEqual(Set(status.keys), ["profile_id", "label_hint", "registered", "bank_profiles"])
        let fields = try XCTUnwrap(status["registered"] as? [String: Bool])
        XCTAssertEqual(Set(fields.keys), ["name", "birth_date", "phone", "carrier", "business_name", "business_registration_number"])
        XCTAssertEqual(fields["business_name"], true); XCTAssertEqual(fields["business_registration_number"], true)
        _ = try ProfileTools.save(["carrier": "kt"], store: store)
        XCTAssertEqual(try store.profile(id: "self")?.businessName, ownName)
        XCTAssertEqual(try store.profile(id: "self")?.businessRegistrationNumber, ownNumber)
        _ = try ProfileTools.save(["business_name": "", "business_registration_number": NSNull()], store: store)
        let cleared = try XCTUnwrap(store.profile(id: "self"))
        XCTAssertNil(cleared.businessName); XCTAssertNil(cleared.businessRegistrationNumber)
        XCTAssertEqual(cleared.name, "합성 본인"); XCTAssertEqual(cleared.phone, "01012345678")
        XCTAssertEqual(try store.profile(id: "family")?.businessRegistrationNumber, familyNumber)
        let clearedFields = try XCTUnwrap(ProfileTools.status(cleared)["registered"] as? [String: Bool])
        XCTAssertEqual(clearedFields["business_name"], false); XCTAssertEqual(clearedFields["business_registration_number"], false)
        _ = try ProfileTools.remove(["profile_id": "family"], store: store)
        XCTAssertEqual(try store.list().map(\.id), ["self"])
    }

    func testInvalidBusinessUpdateCannotReplaceExistingProfileOrStoreCredentialKeys() throws {
        let memory = Memory(), store = memory.store
        _ = try ProfileTools.save(["business_name": "합성 기존 상호", "business_registration_number": "1234567890"], store: store)
        let before = memory.values
        let invalid: [[String: Any]] = [["business_registration_number": 1234567890],
                                       ["business_name": ["unexpected"]],
                                       ["business_name": "합성 변경 상호", "business_registration_number": "123456-1234567"],
                                       ["business_registration_number": "9876543210", "password": "synthetic-secret"],
                                       ["business_registration_number": "9876543210", "resident_number": "synthetic-secret"]]
        for arguments in invalid {
            XCTAssertThrowsError(try ProfileTools.save(arguments, store: store)) {
                XCTAssertFalse($0.localizedDescription.contains("synthetic-secret"))
            }
            XCTAssertEqual(memory.values, before)
        }
    }

    func testBankStatusReturnsOnlyPresenceAndConversationUpdatesPreserveLocalBankData() throws {
        let memory = Memory(), store = memory.store
        let own = IdentityProfile(name: "합성 본인", bankProfiles: [
            "kb": .init(customerName: "합성 본인 통장명", accountNumber: "001234567890"),
            "another-bank": .init(accountNumber: "009876543210")])
        let family = IdentityProfile(id: "family", label: "가족", bankProfiles: [
            "kb": .init(customerName: "합성 가족 통장명", accountNumber: "007654321098")])
        try store.save(own); try store.save(family)
        let changed = try ProfileTools.save(["carrier": "kt", "business_registration_number": "123-45-67890"], store: store)
        let listed = try ProfileTools.list([:], store: store)
        for secret in ["합성 본인", "합성 본인 통장명", "001234567890", "009876543210", "합성 가족 통장명", "007654321098"] {
            XCTAssertFalse(changed.contains(secret)); XCTAssertFalse(listed.contains(secret))
        }
        let profile = try XCTUnwrap(store.profile(id: "self"))
        XCTAssertEqual(profile.bankProfiles, own.bankProfiles)
        XCTAssertEqual(try store.profile(id: "family"), family)
        let bankStatuses = try XCTUnwrap(ProfileTools.status(profile)["bank_profiles"] as? [[String: Any]])
        XCTAssertEqual(bankStatuses.compactMap { $0["bank_id"] as? String }, ["another-bank", "kb"])
        for bank in bankStatuses { XCTAssertEqual(Set(bank.keys), ["bank_id", "registered"]) }
        XCTAssertEqual(bankStatuses[0]["registered"] as? [String: Bool], ["customer_name": false, "account_number": true])
        XCTAssertEqual(bankStatuses[1]["registered"] as? [String: Bool], ["customer_name": true, "account_number": true])
        _ = try ProfileTools.save(["business_registration_number": ""], store: store)
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles, own.bankProfiles)
        XCTAssertEqual(try XCTUnwrap(ProfileTools.status(IdentityProfile())["bank_profiles"] as? [[String: Any]]).count, 0)
    }

    func testConversationCannotStoreBankValuesPasswordsOrDiscoveredIDs() throws {
        let memory = Memory(), store = memory.store
        try store.save(IdentityProfile(bankProfiles: ["kb": .init(customerName: "합성 기존 통장명", accountNumber: "001234567890")]))
        let before = memory.values
        let unsupported: [[String: Any]] = [
            ["bank_id": "kb", "customer_name": "synthetic-private-name"],
            ["bank_customer_name": "synthetic-private-name"],
            ["account_number": "001234567890"],
            ["bank_profiles": ["kb": ["customer_name": "synthetic-private-name"]]],
            ["bankProfiles": ["kb": ["accountNumber": "001234567890"]]],
            ["bank_password": "synthetic-private-password"], ["bank_user_id": "synthetic-found-id"]]
        for arguments in unsupported {
            XCTAssertThrowsError(try ProfileTools.save(arguments, store: store)) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private"))
                XCTAssertFalse(error.localizedDescription.contains("001234567890"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-found-id"))
            }
            XCTAssertEqual(memory.values, before)
        }
    }

    func testMCPExposesProfileToolsAndGatePreventsFillWithoutReadingScreen() throws {
        for name in ["profile_save", "profile_status", "profile_delete", "profile_fill"] {
            XCTAssertTrue(MCPServer.tools.contains { $0.name == name })
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try Tools(db: DB(path: directory.appendingPathComponent("test.db").path, writable: true))
        let memory = Memory(); tools.identityStore = memory.store
        tools.currentText = "해줘"
        tools.windowsGateStatus = { (false, "READY") }
        tools.profileFiller.screen = { XCTFail("denied request must not capture"); return [] }
        let result = tools.execute("profile_fill", ["form": "eais_pass", "field": "name", "x": 0.75, "y": 0.335])
        XCTAssertTrue(result.contains("권한"))
        XCTAssertNil(tools.approval); XCTAssertNil(tools.lastPNG); XCTAssertTrue(tools.lastWords.isEmpty)
    }

    func testMobileFormUsesOnlyPhoneGateAndKeepsPrivateCapturesOutOfOrdinaryState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = try Tools(db: DB(path: directory.appendingPathComponent("test.db").path, writable: true))
        let memory = Memory(); tools.identityStore = memory.store
        try memory.store.save(.init(phone: "01012345678", businessRegistrationNumber: "1234567890"))
        tools.currentText = "진행해"
        tools.windowsGateStatus = { XCTFail("phone form must not use Windows gate"); return (false, "READY") }
        tools.profileFiller.screen = { XCTFail("phone form must not use Windows capture"); return [] }
        var captures = 0, wakes = 0
        tools.phoneProfileFiller.screen = { captures += 1; return [] }
        tools.wakePhone = { wakes += 1 }
        let args: [String: Any] = ["form": "kb_enterprise_certificate_info", "field": "phone", "x": 0.6, "y": 0.4]
        tools.phoneGateStatus = { (false, "CONNECTED") }
        XCTAssertTrue(tools.execute("profile_fill", args).contains("권한"))
        XCTAssertEqual(captures, 0); XCTAssertEqual(wakes, 0)
        tools.phoneGateStatus = { (true, "CONNECTED") }
        let result = tools.execute("profile_fill", args)
        XCTAssertEqual(wakes, 1); XCTAssertEqual(captures, 1)
        XCTAssertFalse(result.contains("01012345678")); XCTAssertFalse(result.contains("1234567890"))
        XCTAssertNil(tools.lastPNG); XCTAssertTrue(tools.lastWords.isEmpty)
        XCTAssertNil(tools.approval)
    }
}
