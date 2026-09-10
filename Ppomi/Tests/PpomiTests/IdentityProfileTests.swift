import XCTest
import Security
@testable import Ppomi

final class IdentityProfileTests: XCTestCase {
    private final class Memory {
        var items: [String: Data] = [:]
        var error: Error?
        var writes = 0
        var storage: IdentityProfileStore.Storage {
            .init(all: { if let error = self.error { throw error }; return self.items.map { .init(account: $0.key, data: $0.value) } },
                  read: { if let error = self.error { throw error }; return self.items[$0] },
                  write: { if let error = self.error { throw error }; self.writes += 1; self.items[$0] = $1 },
                  remove: { if let error = self.error { throw error }; self.items.removeValue(forKey: $0) })
        }
    }

    func testNormalizePartialProfilesAndRejectMalformedOrFutureDates() throws {
        let value = try IdentityProfile(id: " FAMILY_1 ", label: " 가족 ", name: " 테스트 사람 ", birthDate: "2000-02-29",
                                        phone: "010-1234-5678", carrier: " KT_MVNO ").validated()
        XCTAssertEqual(value.id, "family_1"); XCTAssertEqual(value.label, "가족"); XCTAssertEqual(value.name, "테스트 사람")
        XCTAssertEqual(value.phone, "01012345678"); XCTAssertEqual(value.carrier, "kt_mvno")
        XCTAssertEqual(try IdentityProfile(name: " ", phone: "", carrier: " ").validated(), IdentityProfile())
        for date in ["2001-02-29", "2000-13-01", "2000-00-10", "2000-01-32", "2000-2-1", "0000-01-01", "2999-01-01"] {
            XCTAssertThrowsError(try IdentityProfile(birthDate: date).validated(), date)
        }
    }

    func testInvalidFieldsAreRejectedBeforeStorageAndErrorsDoNotEchoValues() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        let privateValue = "synthetic-private-field"
        let invalid = [IdentityProfile(id: "../other"), IdentityProfile(id: String(repeating: "a", count: 49)),
                       IdentityProfile(label: ""), IdentityProfile(label: "one\ntwo"), IdentityProfile(name: "123456-1234567"),
                       IdentityProfile(phone: "010abc12345678"), IdentityProfile(phone: "01112345678"), IdentityProfile(phone: "010123456789"),
                       IdentityProfile(carrier: privateValue)]
        for profile in invalid {
            XCTAssertThrowsError(try store.save(profile)) { XCTAssertFalse($0.localizedDescription.contains(privateValue)) }
        }
        XCTAssertEqual(memory.writes, 0)
        for id in ["", "../self", "self\nother", "1234567890", "phone-01012345678"] {
            XCTAssertThrowsError(try store.profile(id: id)); XCTAssertThrowsError(try store.delete(id: id))
        }
    }

    func testNamesAcceptRealNameCharactersAndRejectCredentialLikePayloads() throws {
        for name in ["홍길동", "김·테스트", "Anne-Marie O'Neill", "J. R. Test", "D’Arcy", "Jose\u{301} Test"] {
            XCTAssertEqual(try IdentityProfile(name: name).validated().name, name)
        }
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        for name in ["홍길동 123456-1234567", "테스트 1234 5678 1234 5678", "이름: 비밀번호", "Name\nCard", "Name\tPassword", "테스트=secret", "테스트🔑", "...---"] {
            XCTAssertThrowsError(try store.save(IdentityProfile(name: name))) { XCTAssertFalse($0.localizedDescription.contains(name)) }
        }
        XCTAssertTrue(memory.items.isEmpty); XCTAssertEqual(memory.writes, 0)
    }

    func testBusinessFieldsNormalizeFormattingWithoutChangingOrVerifyingTheSuppliedNumber() throws {
        let profile = try IdentityProfile(businessName: " 합성 R&D (2호점) ", businessRegistrationNumber: "123-45-67890").validated()
        XCTAssertEqual(profile.businessName, "합성 R&D (2호점)")
        XCTAssertEqual(profile.businessRegistrationNumber, "1234567890")
        // All supplied check digits are preserved. Storage makes no claim about tax registration or eligibility.
        for digit in 0...9 {
            let supplied = "123456789\(digit)"
            XCTAssertEqual(try IdentityProfile(businessRegistrationNumber: supplied).validated().businessRegistrationNumber, supplied)
        }
        XCTAssertEqual(try IdentityProfile(businessName: " ", businessRegistrationNumber: " ").validated(), IdentityProfile())
        XCTAssertEqual(try IdentityProfile(businessName: String(repeating: "가", count: 100)).validated().businessName?.count, 100)
        XCTAssertThrowsError(try IdentityProfile(name: "합성 R&D (2호점)").validated(), "personal-name validation must remain separate")
    }

    func testBusinessValidationRejectsMalformedValuesWithoutWritingOrEchoingThem() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        let malformedNumbers = ["123456789", "12345678901", "123-4-567890", "123 45 67890", "123456789x",
                                "１２３４５６７８９０", "١٢٣٤٥٦٧٨٩٠", "123456-1234567", "1234567890\n", "123\t4567890"]
        for number in malformedNumbers {
            XCTAssertThrowsError(try store.save(IdentityProfile(businessRegistrationNumber: number))) {
                XCTAssertFalse($0.localizedDescription.contains(number))
            }
        }
        for name in ["합성\n상호", "\t상호", "합성\u{0000}상호", "합성\u{202E}상호", String(repeating: "가", count: 101)] {
            XCTAssertThrowsError(try store.save(IdentityProfile(businessName: name))) {
                XCTAssertFalse($0.localizedDescription.contains(name))
            }
        }
        XCTAssertEqual(memory.writes, 0); XCTAssertTrue(memory.items.isEmpty)
    }

    func testLegacyPayloadAndBusinessProfilesRemainCompatibleAndIsolated() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        memory.items["self"] = Data(#"{"id":"self","label":"나","name":"합성 본인","birthDate":"2000-01-01","phone":"01012345678","carrier":"skt"}"#.utf8)
        var own = try XCTUnwrap(store.profile(id: "self"))
        XCTAssertNil(own.businessName); XCTAssertNil(own.businessRegistrationNumber)
        own.businessName = "합성 A 상호"; own.businessRegistrationNumber = "1234567890"
        let family = IdentityProfile(id: "family", label: "가족", businessName: "합성 B 상호", businessRegistrationNumber: "9876543210")
        try store.save(own); try store.save(family)
        XCTAssertEqual(try store.profile(id: "self"), own)
        XCTAssertEqual(try store.profile(id: "family"), family)
        try store.delete(id: "self")
        XCTAssertEqual(try store.list(), [family])
    }

    func testBankIdentifiersPreserveSuppliedDigitsAndKeepCustomerNamesSeparate() throws {
        let bank = try IdentityBankProfile(customerName: " 합성 R&D (통장명) ", accountNumber: " 0012-3456 7890 ").validated()
        XCTAssertEqual(bank.customerName, "합성 R&D (통장명)")
        XCTAssertEqual(bank.accountNumber, "001234567890")
        for count in [6, 20] {
            let number = String(repeating: "0", count: count - 1) + "1"
            XCTAssertEqual(try IdentityBankProfile(accountNumber: number).validated().accountNumber, number)
        }
        let profile = try IdentityProfile(name: "합성 본인", businessName: "합성 상호",
                                          bankProfiles: ["kb": IdentityBankProfile(accountNumber: "001234567890")]).validated()
        XCTAssertNil(profile.bankProfiles?["kb"]?.customerName, "the bank's customer name must not be inferred from other names")
        XCTAssertEqual(try IdentityBankProfile(customerName: " ", accountNumber: " ").validated(), IdentityBankProfile())
        XCTAssertNil(try IdentityProfile(bankProfiles: [:]).validated().bankProfiles)
    }

    func testBankValidationRejectsMalformedDataWithoutOverwritingOrEchoingIt() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        try store.save(IdentityProfile(bankProfiles: ["kb": .init(customerName: "합성 통장명", accountNumber: "001234567890")]))
        let before = memory.items, writesBefore = memory.writes
        let badNumbers = ["12345", "123456789012345678901", "123456x", "１２３４５６", "١٢٣٤٥٦", "1234/5678",
                          "1234.5678", "1234\t5678", "123456\n", "123456\u{00a0}", "-- --"]
        var invalid = badNumbers.map { IdentityProfile(bankProfiles: ["kb": .init(accountNumber: $0)]) }
        invalid += [" 합성\n통장명", "합성\u{0000}통장명", "합성\u{202E}통장명", String(repeating: "가", count: 101)].map {
            IdentityProfile(bankProfiles: ["kb": .init(customerName: $0)])
        }
        invalid += ["", "KB", "kb\n", " kb", "kb/other", "0kb", String(repeating: "a", count: 33)].map {
            IdentityProfile(bankProfiles: [$0: .init(customerName: "synthetic-private-bank-name")])
        }
        for profile in invalid {
            let forbidden = (profile.bankProfiles ?? [:]).flatMap { [$0.key, $0.value.customerName, $0.value.accountNumber].compactMap { $0 } }.filter { !$0.isEmpty }
            XCTAssertThrowsError(try store.save(profile)) { error in
                for value in forbidden { XCTAssertFalse(error.localizedDescription.contains(value), "errors must not include rejected values") }
            }
            XCTAssertEqual(memory.items, before)
        }
        XCTAssertEqual(memory.writes, writesBefore)
    }

    func testLegacyBankDataAndLocalBankEditsRemainIsolatedAcrossProfiles() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        memory.items["self"] = Data(#"{"id":"self","label":"나","businessName":"합성 기존 상호","businessRegistrationNumber":"1234567890"}"#.utf8)
        var own = try XCTUnwrap(store.profile(id: "self"))
        XCTAssertNil(own.bankProfiles)
        own.bankProfiles = ["kb": .init(customerName: "합성 본인 통장", accountNumber: "001234567890"),
                            "other-bank": .init(customerName: "합성 다른 은행", accountNumber: "009876543210")]
        let family = IdentityProfile(id: "family", label: "가족", bankProfiles: ["kb": .init(customerName: "합성 가족 통장", accountNumber: "007654321098")])
        try store.save(own); try store.save(family)
        XCTAssertEqual(try store.profile(id: "self"), own)
        XCTAssertEqual(try store.profile(id: "family"), family)
        own.bankProfiles?["kb"]?.accountNumber = nil
        try store.save(own)
        XCTAssertNil(try store.profile(id: "self")?.bankProfiles?["kb"]?.accountNumber)
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles?["other-bank"]?.accountNumber, "009876543210")
        XCTAssertEqual(try store.profile(id: "self")?.businessRegistrationNumber, "1234567890")
        XCTAssertEqual(try store.profile(id: "family"), family)
        own.bankProfiles?.removeValue(forKey: "kb")
        try store.save(own)
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles?.keys.sorted(), ["other-bank"])
        try store.delete(id: "self")
        XCTAssertEqual(try store.list(), [family])
    }

    func testBankCountAndEncodedSizeLimitsPreventUnreadableStoredProfiles() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        let sixteen = Dictionary(uniqueKeysWithValues: (0..<16).map { ("bank-\($0)", IdentityBankProfile(accountNumber: "001234567890")) })
        try store.save(IdentityProfile(bankProfiles: sixteen))
        XCTAssertEqual(try store.profile(id: "self")?.bankProfiles?.count, 16)
        let before = memory.items, writesBefore = memory.writes
        var seventeen = sixteen; seventeen["another-bank"] = .init()
        XCTAssertThrowsError(try store.save(IdentityProfile(bankProfiles: seventeen)))
        // A short displayed name can still have many combining scalars, so character counts do not bound encoded bytes.
        let largeName = String(repeating: "가" + String(repeating: "\u{0301}", count: 100), count: 100)
        let oversized = try IdentityProfile(bankProfiles: ["kb": .init(customerName: largeName)]).validated()
        XCTAssertGreaterThan(try JSONEncoder().encode(oversized).count, IdentityProfileStore.maximumEncodedBytes)
        XCTAssertThrowsError(try store.save(oversized)) { error in
            guard case IdentityProfileStore.Failure.tooLarge = error else { return XCTFail("expected an encoded-size failure") }
            XCTAssertFalse(error.localizedDescription.contains(largeName))
        }
        XCTAssertEqual(memory.items, before); XCTAssertEqual(memory.writes, writesBefore)
    }

    func testNativeBankCollectionMergesLatestDataAndBlankFieldsNeverDeleteIt() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        let existing = IdentityProfile(name: "합성 본인", phone: "01012345678", businessName: "합성 상호",
                                       bankProfiles: ["kb": .init(customerName: "합성 현재 통장명"),
                                                      "another-bank": .init(accountNumber: "007654321098")])
        let family = IdentityProfile(id: "family", label: "가족", bankProfiles: ["kb": .init(accountNumber: "009876543210")])
        try store.save(existing); try store.save(family)
        let updated = try store.updateBankProfile(id: "self", bankID: "kb", values: ["account_number": "0012-3456-7890"], onlyMissing: true)
        XCTAssertEqual(updated.bankProfiles?["kb"], .init(customerName: "합성 현재 통장명", accountNumber: "001234567890"))
        XCTAssertEqual(updated.name, existing.name); XCTAssertEqual(updated.phone, existing.phone)
        XCTAssertEqual(updated.businessName, existing.businessName)
        XCTAssertEqual(updated.bankProfiles?["another-bank"], existing.bankProfiles?["another-bank"])
        XCTAssertEqual(try store.profile(id: "family"), family)
        XCTAssertEqual(try store.updateBankProfile(id: "self", bankID: "kb", values: ["customer_name": "", "account_number": " "], onlyMissing: true), updated)
        XCTAssertEqual(try store.updateBankProfile(id: "self", bankID: "kb", values: [:]), updated)
        let new = try store.updateBankProfile(id: "new-profile", bankID: "kb", values: ["customer_name": "합성 신규 통장명"])
        XCTAssertEqual(new.id, "new-profile"); XCTAssertEqual(new.label, "new-profile")
        XCTAssertEqual(new.bankProfiles?["kb"]?.customerName, "합성 신규 통장명")
        XCTAssertNil(new.bankProfiles?["kb"]?.accountNumber)
    }

    func testNativeCollectionRejectsStaleFieldsAndSecretsWithoutPartialWrite() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        try store.save(IdentityProfile(bankProfiles: ["kb": .init(customerName: "합성 먼저 등록된 통장명")]))
        let before = memory.items, writesBefore = memory.writes
        XCTAssertThrowsError(try store.updateBankProfile(id: "self", bankID: "kb",
                                                        values: ["customer_name": "합성 오래된 입력창 통장명", "account_number": "001234567890"],
                                                        onlyMissing: true)) { error in
            guard case IdentityProfileStore.Failure.bankAlreadyRegistered = error else { return XCTFail("expected stale-field failure") }
            XCTAssertFalse(error.localizedDescription.contains("합성 먼저 등록된 통장명"))
            XCTAssertFalse(error.localizedDescription.contains("합성 오래된 입력창 통장명"))
        }
        for field in ["password", "resident_number", "bank_user_id", "otp", "business_name"] {
            XCTAssertThrowsError(try store.updateBankProfile(id: "self", bankID: "kb",
                                                            values: ["account_number": "001234567890", field: "synthetic-secret"])) {
                XCTAssertFalse($0.localizedDescription.contains("synthetic-secret"))
            }
        }
        XCTAssertThrowsError(try store.updateBankProfile(id: "self", bankID: "kb", values: ["account_number": "123456x"]))
        XCTAssertEqual(memory.items, before); XCTAssertEqual(memory.writes, writesBefore)
        // Explicit settings-style updates can still replace a field; the collection-card protection is opt-in.
        let replaced = try store.updateBankProfile(id: "self", bankID: "kb", values: ["customer_name": "합성 바꾼 통장명"])
        XCTAssertEqual(replaced.bankProfiles?["kb"]?.customerName, "합성 바꾼 통장명")
    }

    func testNativeCollectionReadFailuresDoNotReplaceAnUnreadableProfile() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        memory.items["self"] = Data("not-profile-data".utf8)
        let before = memory.items
        XCTAssertThrowsError(try store.updateBankProfile(id: "self", bankID: "kb", values: ["account_number": "001234567890"]))
        memory.error = IdentityProfileStore.Failure.keychain(errSecAuthFailed)
        XCTAssertThrowsError(try store.updateBankProfile(id: "self", bankID: "kb", values: ["account_number": "001234567890"]))
        XCTAssertEqual(memory.items, before); XCTAssertEqual(memory.writes, 0)
    }

    func testRoundTripOverwriteAndDeleteAreIsolatedByProfile() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        XCTAssertEqual(try store.list(), []); XCTAssertNil(try store.profile(id: "missing"))
        let own = IdentityProfile(name: "테스트 본인", birthDate: "2000-01-01", phone: "01012345678", carrier: "skt")
        let family = IdentityProfile(id: "family", label: "가족", name: "테스트 가족")
        try store.save(family); try store.save(own)
        XCTAssertEqual(try store.list(), [own, family]); XCTAssertEqual(try store.profile(id: " SELF "), own)
        var edited = own; edited.carrier = "kt"; try store.save(edited)
        XCTAssertEqual(memory.items.count, 2); XCTAssertEqual(try store.profile(id: "family"), family)
        try store.delete(id: "SELF"); try store.delete(id: "self")
        XCTAssertEqual(try store.list(), [family])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(memory.items["family"])) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "label", "name"])
    }

    func testCorruptOrMismatchedStoredProfileFailsInsteadOfReturningAnotherPerson() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        memory.items["self"] = try JSONEncoder().encode(IdentityProfile(id: "family", label: "가족"))
        XCTAssertThrowsError(try store.profile(id: "self")); XCTAssertThrowsError(try store.list())
        memory.items["self"] = Data("bad-json".utf8)
        XCTAssertThrowsError(try store.list())
    }

    func testLockedAndFailedStorageErrorsPropagateWithoutFallback() throws {
        let memory = Memory(), store = IdentityProfileStore(storage: memory.storage)
        memory.error = IdentityProfileStore.Failure.keychain(errSecInteractionNotAllowed)
        for operation in [{ _ = try store.list() }, { _ = try store.profile(id: "self") }, { try store.save(IdentityProfile()) }, { try store.delete(id: "self") }] {
            XCTAssertThrowsError(try operation()) { XCTAssertTrue($0.localizedDescription.contains("OSStatus")) }
        }
        XCTAssertEqual(memory.writes, 0); XCTAssertTrue(memory.items.isEmpty)
    }

    func testKeychainQueriesUseExplicitClassicKeychainCallingAppACLAndNoSynchronization() throws {
        var queries: [[String: Any]] = [], values: [[String: Any]] = []
        let api = IdentityProfileStore.KeychainAPI(copy: { query, _ in queries.append(query as! [String: Any]); return errSecItemNotFound },
                                                  add: { query, _ in queries.append(query as! [String: Any]); return errSecSuccess },
                                                  update: { query, value in queries.append(query as! [String: Any]); values.append(value as! [String: Any]); return errSecItemNotFound },
                                                  delete: { query in queries.append(query as! [String: Any]); return errSecItemNotFound })
        let store = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: api,
                                                                                      keychain: { "synthetic-keychain" }, access: { "synthetic-calling-app-acl" }))
        XCTAssertEqual(try store.list(), []); XCTAssertNil(try store.profile(id: "self"))
        try store.save(IdentityProfile()); try store.delete(id: "self")
        for query in queries {
            XCTAssertEqual(query[kSecAttrService as String] as? String, IdentityProfileStore.service)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
            XCTAssertNil(query[kSecAttrAccessible as String], "classic Keychain must not claim an unsupported accessibility guarantee")
        }
        let added = try XCTUnwrap(queries.first { $0[kSecValueData as String] != nil })
        XCTAssertEqual(added[kSecUseKeychain as String] as? String, "synthetic-keychain")
        XCTAssertEqual(added[kSecAttrAccess as String] as? String, "synthetic-calling-app-acl")
        XCTAssertNil(added[kSecMatchSearchList as String])
        XCTAssertEqual(added[kSecAttrAccount as String] as? String, "self")
        XCTAssertEqual(added[kSecAttrLabel as String] as? String, "Ppomi identity profile")
        XCTAssertEqual(Set(try XCTUnwrap(values.first).keys), [kSecValueData as String], "updates preserve the existing ACL without deleting the item")
    }

    func testKeychainAccessFailureNeverLooksLikeAnEmptyStoreOrRetriesAsAnAdd() throws {
        let api = IdentityProfileStore.KeychainAPI(copy: { _, _ in errSecInteractionNotAllowed },
                                                  add: { _, _ in XCTFail("failed update must not downgrade to add"); return errSecSuccess },
                                                  update: { _, _ in errSecAuthFailed }, delete: { _ in errSecAuthFailed })
        let store = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: api,
                                                                                      keychain: { "synthetic-keychain" }, access: { XCTFail("access creation is only needed for add"); return "unused" }))
        XCTAssertThrowsError(try store.list()); XCTAssertThrowsError(try store.profile(id: "self"))
        XCTAssertThrowsError(try store.save(IdentityProfile())); XCTAssertThrowsError(try store.delete(id: "self"))
    }

    func testKeychainListEnumeratesAttributesBeforeReadingEachPasswordSeparately() throws {
        let own = IdentityProfile(), family = IdentityProfile(id: "family", label: "가족")
        let payloads = ["self": try JSONEncoder().encode(own), "family": try JSONEncoder().encode(family)]
        var queries: [[String: Any]] = [], keychainCalls = 0
        let api = listingAPI { query, result in
            queries.append(query)
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                // Match the real classic-Keychain restriction that caused OSStatus -50.
                guard query[kSecReturnData as String] == nil else { return errSecParam }
                result?.pointee = [[kSecAttrAccount as String: "family"], [kSecAttrAccount as String: "self"]] as CFArray
            } else {
                guard let account = query[kSecAttrAccount as String] as? String,
                      let data = payloads[account] else { return errSecItemNotFound }
                result?.pointee = data as CFData
            }
            return errSecSuccess
        }
        let store = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: api,
            keychain: { keychainCalls += 1; return "synthetic-keychain" }))
        XCTAssertEqual(try store.list(), [own, family])
        XCTAssertEqual(keychainCalls, 1, "all entries must use the same selected Keychain")
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0][kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(queries[0][kSecAttrAccount as String]); XCTAssertNil(queries[0][kSecReturnData as String])
        XCTAssertEqual(Set(queries.dropFirst().compactMap { $0[kSecAttrAccount as String] as? String }), ["self", "family"])
        for query in queries {
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(query[kSecAttrService as String] as? String, IdentityProfileStore.service)
            XCTAssertEqual(query[kSecMatchSearchList as String] as? [String], ["synthetic-keychain"])
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
            XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        }
        for query in queries.dropFirst() {
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
            XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
            XCTAssertNil(query[kSecReturnAttributes as String])
        }
    }

    func testKeychainListPropagatesPerAccountAccessErrorsInsteadOfReturningPartialResults() throws {
        let data = try JSONEncoder().encode(IdentityProfile())
        for denied in [errSecInteractionNotAllowed, errSecAuthFailed, errSecParam] {
            let api = listingAPI { query, result in
                if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    result?.pointee = [[kSecAttrAccount as String: "self"], [kSecAttrAccount as String: "family"]] as CFArray
                    return errSecSuccess
                }
                if query[kSecAttrAccount as String] as? String == "self" {
                    result?.pointee = data as CFData
                    return errSecSuccess
                }
                return denied
            }
            let store = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: api, keychain: { "synthetic-keychain" }))
            XCTAssertThrowsError(try store.list()) { error in
                guard case IdentityProfileStore.Failure.keychain(let status) = error else { return XCTFail("expected Keychain failure") }
                XCTAssertEqual(status, denied)
            }
        }
    }

    func testKeychainListSkipsProfilesDeletedAfterEnumerationButRejectsMalformedResults() throws {
        let api = listingAPI { query, result in
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                result?.pointee = [[kSecAttrAccount as String: "self"]] as CFArray
                return errSecSuccess
            }
            return errSecItemNotFound
        }
        let store = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: api, keychain: { "synthetic-keychain" }))
        XCTAssertEqual(try store.list(), [])

        for attributes in [[[:]], [[kSecAttrAccount as String: "self"], [kSecAttrAccount as String: "self"]]] {
            var reads = 0
            let malformedAPI = listingAPI { query, result in
                if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    result?.pointee = attributes as CFArray
                } else { reads += 1 }
                return errSecSuccess
            }
            let malformed = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: malformedAPI, keychain: { "synthetic-keychain" }))
            XCTAssertThrowsError(try malformed.list())
            XCTAssertEqual(reads, 0)
        }

        let wrongDataAPI = listingAPI { query, result in
            result?.pointee = query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String
                ? [[kSecAttrAccount as String: "self"]] as CFArray : "not-password-data" as CFString
            return errSecSuccess
        }
        let wrongData = IdentityProfileStore(storage: IdentityProfileStore.keychainStorage(api: wrongDataAPI, keychain: { "synthetic-keychain" }))
        XCTAssertThrowsError(try wrongData.list())
    }

    private func listingAPI(_ copy: @escaping ([String: Any], UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) -> IdentityProfileStore.KeychainAPI {
        .init(copy: { query, result in copy(query as! [String: Any], result) },
              add: { _, _ in XCTFail("listing must not add items"); return errSecParam },
              update: { _, _ in XCTFail("listing must not update items"); return errSecParam },
              delete: { _ in XCTFail("listing must not delete items"); return errSecParam })
    }
}
