// Details the owner explicitly saves for form preparation, including business and bank form identifiers.
// No passwords, personal government IDs, or payment credentials.
// Each profile is one nonsynchronizing item in the user's default macOS Keychain, with a calling-app ACL.
// Classic Keychain is intentional for this app's existing signing setup; no device-lock/ThisDeviceOnly promise is made.
// This store never writes to files or UserDefaults and never downgrades after a Keychain error.
import Foundation
import Security

/// Customer and account identifiers the user supplies in the local editor. These do not prove account ownership.
/// Passwords, authentication codes and discovered login IDs have no storage field here.
struct IdentityBankProfile: Codable, Equatable {
    var customerName: String?
    var accountNumber: String?

    init(customerName: String? = nil, accountNumber: String? = nil) {
        self.customerName = customerName; self.accountNumber = accountNumber
    }

    enum ValidationError: Error, LocalizedError {
        case customerName, accountNumber
        var errorDescription: String? {
            switch self {
            case .customerName: return "은행 고객명은 제어문자 없이 문자·숫자·문장부호·기호·공백으로 100자 이내로 입력하세요."
            case .accountNumber: return "계좌번호는 숫자 6~20자리로 입력하세요. 표시용 하이픈과 공백만 함께 사용할 수 있습니다."
            }
        }
    }

    func validated() throws -> IdentityBankProfile {
        if let customerName, customerName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw ValidationError.customerName
        }
        let trimmedName = customerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerName = trimmedName?.isEmpty == false ? trimmedName : nil
        if let customerName {
            let characters = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
                .union(.punctuationCharacters).union(.symbols).union(CharacterSet(charactersIn: " "))
            guard customerName.count <= 100, customerName.unicodeScalars.allSatisfy(characters.contains) else {
                throw ValidationError.customerName
            }
        }
        // Validate before stripping presentation characters. Never salvage malformed identifiers or infer digits.
        var accountNumber: String?
        if let raw = self.accountNumber {
            guard raw.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789- ").contains) else {
                throw ValidationError.accountNumber
            }
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                let digits = raw.filter { $0 >= "0" && $0 <= "9" }
                guard (6...20).contains(digits.count) else { throw ValidationError.accountNumber }
                accountNumber = digits
            }
        }
        return IdentityBankProfile(customerName: customerName, accountNumber: accountNumber)
    }
}

struct IdentityProfile: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var name: String?
    var birthDate: String?
    var phone: String?
    var carrier: String?
    var businessName: String?
    var businessRegistrationNumber: String?
    var bankProfiles: [String: IdentityBankProfile]?

    static let carriers: Set<String> = ["skt", "kt", "lgu", "skt_mvno", "kt_mvno", "lgu_mvno"]

    init(id: String = "self", label: String = "나", name: String? = nil, birthDate: String? = nil,
         phone: String? = nil, carrier: String? = nil, businessName: String? = nil,
         businessRegistrationNumber: String? = nil, bankProfiles: [String: IdentityBankProfile]? = nil) {
        self.id = id; self.label = label; self.name = name; self.birthDate = birthDate; self.phone = phone; self.carrier = carrier
        self.businessName = businessName; self.businessRegistrationNumber = businessRegistrationNumber
        self.bankProfiles = bankProfiles
    }

    enum ValidationError: Error, LocalizedError {
        case id, label, name, birthDate, phone, carrier, businessName, businessRegistrationNumber, bankProfiles, bankID
        var errorDescription: String? {
            switch self {
            case .id: return "프로필 ID는 영문 소문자로 시작하고 영문·숫자·밑줄·하이픈만 쓰는 1~48자여야 하며, 10자리 이상 연속 숫자는 넣을 수 없습니다."
            case .label: return "프로필 표시 이름을 줄바꿈 없이 1~40자로 입력하세요."
            case .name: return "이름은 글자를 포함한 100자 이내로, 문자·공백·하이픈·작은따옴표·가운뎃점·마침표만 입력하세요."
            case .birthDate: return "생년월일은 미래가 아닌 실제 날짜를 YYYY-MM-DD 형식으로 입력하세요."
            case .phone: return "휴대폰 번호는 010으로 시작하는 11자리여야 합니다."
            case .carrier: return "지원하는 통신사를 선택하세요."
            case .businessName: return "상호는 제어문자 없이 문자·숫자·문장부호·기호·공백으로 100자 이내로 입력하세요."
            case .businessRegistrationNumber: return "사업자등록번호는 숫자 10자리 또는 000-00-00000 형식으로 입력하세요."
            case .bankProfiles: return "은행 폼 정보는 프로필마다 최대 16개까지 저장할 수 있습니다."
            case .bankID: return "은행 ID는 영문 소문자로 시작하고 영문 소문자·숫자·밑줄·하이픈만 쓰는 1~32자여야 합니다."
            }
        }
    }

    func validated() throws -> IdentityProfile {
        let id = try Self.normalizedID(id)
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(label.count), !Self.hasControls(label) else { throw ValidationError.label }
        let name = Self.optional(name)
        if let name {
            let nameCharacters = CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " -'’·."))
            guard name.count <= 100, name.unicodeScalars.allSatisfy(nameCharacters.contains),
                  name.unicodeScalars.contains(where: CharacterSet.letters.contains) else { throw ValidationError.name }
        }
        let birthDate = Self.optional(birthDate)
        if let birthDate {
            guard birthDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw ValidationError.birthDate }
            let parts = birthDate.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] > 0 else { throw ValidationError.birthDate }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components,
                  date <= calendar.startOfDay(for: Date()) else { throw ValidationError.birthDate }
        }
        var phone = Self.optional(phone)
        if let raw = phone {
            // Accept ordinary presentation formatting, but never drop arbitrary characters to salvage an invalid value.
            guard raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789- ()").contains($0) }) else { throw ValidationError.phone }
            phone = raw.filter { $0 >= "0" && $0 <= "9" }
            guard phone?.range(of: #"^010[0-9]{8}$"#, options: .regularExpression) != nil else { throw ValidationError.phone }
        }
        let carrier = Self.optional(carrier)?.lowercased()
        if let carrier, !Self.carriers.contains(carrier) { throw ValidationError.carrier }
        // Business names have a different vocabulary from personal names, such as digits and parentheses.
        // Reject raw controls before trimming so tabs/newlines cannot silently become an accepted value.
        if let businessName, Self.hasControls(businessName) { throw ValidationError.businessName }
        let businessName = Self.optional(businessName)
        if let businessName {
            let characters = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
                .union(.punctuationCharacters).union(.symbols).union(CharacterSet(charactersIn: " "))
            guard businessName.count <= 100, businessName.unicodeScalars.allSatisfy(characters.contains) else {
                throw ValidationError.businessName
            }
        }
        if let businessRegistrationNumber, Self.hasControls(businessRegistrationNumber) { throw ValidationError.businessRegistrationNumber }
        var businessRegistrationNumber = Self.optional(businessRegistrationNumber)
        if let raw = businessRegistrationNumber {
            guard raw.range(of: #"^(?:[0-9]{10}|[0-9]{3}-[0-9]{2}-[0-9]{5})$"#, options: .regularExpression) != nil else {
                throw ValidationError.businessRegistrationNumber
            }
            // Format validation is not an official registration check. Never repair or reject a supplied checksum.
            businessRegistrationNumber = raw.replacingOccurrences(of: "-", with: "")
        }
        var validatedBanks: [String: IdentityBankProfile]?
        if let bankProfiles, !bankProfiles.isEmpty {
            guard bankProfiles.count <= 16 else { throw ValidationError.bankProfiles }
            var banks: [String: IdentityBankProfile] = [:]
            for (bankID, bankProfile) in bankProfiles {
                _ = try Self.validatedBankID(bankID)
                banks[bankID] = try bankProfile.validated()
            }
            validatedBanks = banks
        }
        return IdentityProfile(id: id, label: label, name: name, birthDate: birthDate, phone: phone, carrier: carrier,
                               businessName: businessName, businessRegistrationNumber: businessRegistrationNumber,
                               bankProfiles: validatedBanks)
    }

    static func normalizedID(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.range(of: #"^[a-z][a-z0-9_-]{0,47}$"#, options: .regularExpression) != nil,
              id.range(of: #"[0-9]{10,}"#, options: .regularExpression) == nil else { throw ValidationError.id }
        return id
    }

    static func validatedBankID(_ bankID: String) throws -> String {
        guard bankID.range(of: #"\A[a-z][a-z0-9_-]{0,31}\z"#, options: .regularExpression) != nil else {
            throw ValidationError.bankID
        }
        return bankID
    }

    private static func optional(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
    private static func hasControls(_ value: String) -> Bool { value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
}

final class IdentityProfileStore {
    static let shared = IdentityProfileStore()
    static let service = "com.muilyzz.ppomi.identity.v1"
    static let maximumEncodedBytes = 16_384

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus), corrupt, tooLarge, bankFields, bankAlreadyRegistered, locked
        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                    return "개인정보 키체인이 잠겨 있거나 접근이 허용되지 않았습니다(OSStatus \(status)). Mac에서 잠금과 뽀미 접근 권한을 확인하세요."
                }
                return "개인정보 키체인 작업에 실패했습니다(OSStatus \(status)). 다른 저장소로 우회하지 않았습니다."
            case .corrupt: return "키체인의 프로필 데이터를 읽지 못했습니다. 프로필을 확인해 다시 저장하세요."
            case .locked: return "개인정보는 지문(또는 Mac 암호) 확인 뒤에 읽습니다. Mac 에서 확인해 주세요."
            case .tooLarge: return "프로필 정보가 저장 가능한 크기를 넘었습니다. 일부 내용을 줄여 다시 저장하세요."
            case .bankFields: return "이 입력창에는 은행 고객명과 출금계좌번호만 저장할 수 있습니다."
            case .bankAlreadyRegistered: return "일부 항목이 이미 등록되어 변경하지 않았습니다. 입력창을 새로 열어 필요한 항목을 확인하세요."
            }
        }
    }

    struct Entry { var account: String; var data: Data }
    struct Storage {
        var all: () throws -> [Entry]
        var read: (String) throws -> Data?
        var write: (String, Data) throws -> Void
        var remove: (String) throws -> Void
        static var keychain: Storage { IdentityProfileStore.keychainStorage() }
    }

    private let storage: Storage
    private let lock = NSLock()
    init(storage: Storage = .keychain) { self.storage = storage }

    func list() throws -> [IdentityProfile] {
        lock.lock(); defer { lock.unlock() }
        let entries = try storage.all()
        guard Set(entries.map(\.account)).count == entries.count else { throw Failure.corrupt }
        return try entries.map { try decode($0.data, account: $0.account) }.sorted {
            if $0.id == "self" { return $1.id != "self" }
            if $1.id == "self" { return false }
            return $0.id < $1.id
        }
    }

    func profile(id: String) throws -> IdentityProfile? {
        let account = try IdentityProfile.normalizedID(id)
        lock.lock(); defer { lock.unlock() }
        guard let data = try storage.read(account) else { return nil }
        return try decode(data, account: account)
    }

    func save(_ profile: IdentityProfile) throws {
        let value = try profile.validated()
        let data = try Self.encoded(value)
        lock.lock(); defer { lock.unlock() }
        try storage.write(value.id, data)
        rememberOwnName(value)
    }
    /// 장부의 "내 이름"(본인 명의 입금 = 이체)은 지문 없이도 필요한 값: 저장 때 따로 적어 둔다(AppSettings.me).
    /// 앱의 금고(shared)만 적는다 — 테스트의 메모리 저장소가 UserDefaults 를 오염시켜 장부 테스트의 이름을 바꿔 놓았던 적이 있다.
    private func rememberOwnName(_ value: IdentityProfile) {
        guard self === Self.shared, value.id == "self", let name = value.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: "me")
    }
    /// 잠금 해제 뒤 한 번: 예전 평문 항목을 금고 형식으로 다시 저장한다.
    func migrateToVault() throws {
        guard IdentityVault.shared.isAvailable else { return }
        for profile in try list() { try save(profile) }
    }

    /// The native collection card passes its values directly here, without routing them through agent tool arguments.
    /// Blank or omitted fields preserve existing values; the settings editor remains the path for explicit deletion.
    func updateBankProfile(id: String, bankID: String, values: [String: String], onlyMissing: Bool = false) throws -> IdentityProfile {
        guard Set(values.keys).isSubset(of: ["customer_name", "account_number"]) else { throw Failure.bankFields }
        let account = try IdentityProfile.normalizedID(id)
        let bankID = try IdentityProfile.validatedBankID(bankID)
        let incoming = try IdentityBankProfile(customerName: values["customer_name"], accountNumber: values["account_number"]).validated()
        lock.lock(); defer { lock.unlock() }
        var profile: IdentityProfile
        if let data = try storage.read(account) {
            profile = try decode(data, account: account)
        } else {
            profile = IdentityProfile(id: account, label: account == "self" ? "나" : account)
        }
        if incoming.customerName != nil || incoming.accountNumber != nil {
            var banks = profile.bankProfiles ?? [:]
            var bank = banks[bankID] ?? IdentityBankProfile()
            if onlyMissing && ((incoming.customerName != nil && bank.customerName != nil) ||
                               (incoming.accountNumber != nil && bank.accountNumber != nil)) {
                throw Failure.bankAlreadyRegistered
            }
            if let customerName = incoming.customerName { bank.customerName = customerName }
            if let accountNumber = incoming.accountNumber { bank.accountNumber = accountNumber }
            banks[bankID] = bank
            profile.bankProfiles = banks
        }
        let value = try profile.validated()
        try storage.write(account, Self.encoded(value))
        rememberOwnName(value)
        return value
    }

    func delete(id: String) throws {
        let account = try IdentityProfile.normalizedID(id)
        lock.lock(); defer { lock.unlock() }
        try storage.remove(account)
    }

    private func decode(_ data: Data, account: String) throws -> IdentityProfile {
        guard data.count <= Self.maximumEncodedBytes + 128 else { throw Failure.corrupt }
        var plain = data
        if IdentityVault.isSealed(data) {   // 금고 형식: SE 비밀키 — 지문 뒤에서만
            do { plain = try IdentityVault.shared.open(data) }
            catch IdentityVault.Failure.locked { throw Failure.locked }
            catch { throw Failure.corrupt }
        }
        guard let decoded = try? JSONDecoder().decode(IdentityProfile.self, from: plain),
              let value = try? decoded.validated(), value.id == account else { throw Failure.corrupt }
        return value
    }

    private static func encoded(_ value: IdentityProfile) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumEncodedBytes else { throw Failure.tooLarge }
        guard IdentityVault.shared.isAvailable else { return data }   // SE 없는 Mac·테스트: 예전처럼 평문
        return try IdentityVault.shared.seal(data)
    }

    // Injection at the Security boundary allows tests to verify the real queries without touching a user's Keychain.
    struct KeychainAPI {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var update: (CFDictionary, CFDictionary) -> OSStatus
        var delete: (CFDictionary) -> OSStatus
        static let system = KeychainAPI(copy: SecItemCopyMatching, add: SecItemAdd, update: SecItemUpdate, delete: SecItemDelete)
    }

    static func keychainStorage(api: KeychainAPI = .system,
                                keychain: @escaping () throws -> Any = systemDefaultKeychain,
                                access: @escaping () throws -> Any = systemAppAccess) -> Storage {
        func query(_ account: String? = nil, keychain: Any) -> [String: Any] {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrSynchronizable as String: false,
                                   kSecUseDataProtectionKeychain as String: false,
                                   kSecMatchSearchList as String: [keychain],
                                   kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            if let account { q[kSecAttrAccount as String] = account }
            return q
        }
        func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw Failure.keychain(status) } }
        func readData(_ account: String, keychain: Any) throws -> Data? {
            var q = query(account, keychain: keychain)
            q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = api.copy(q as CFDictionary, &out)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = out as? Data else { throw Failure.corrupt }
            return data
        }
        return Storage(all: {
            let targetKeychain = try keychain()
            // Classic Keychain forbids ReturnData + MatchLimitAll for password items.
            // Enumerate only this service's accounts, then read each encrypted item separately.
            var q = query(keychain: targetKeychain); q[kSecMatchLimit as String] = kSecMatchLimitAll
            q[kSecReturnAttributes as String] = true
            var out: CFTypeRef?
            let status = api.copy(q as CFDictionary, &out)
            if status == errSecItemNotFound { return [] }
            try check(status)
            guard let items = out as? [[String: Any]] else { throw Failure.corrupt }
            let accounts = try items.map { item -> String in
                guard let account = item[kSecAttrAccount as String] as? String else { throw Failure.corrupt }
                return account
            }
            guard Set(accounts).count == accounts.count else { throw Failure.corrupt }
            return try accounts.compactMap { account in
                // Another app process may delete a profile after enumeration; other errors still propagate.
                guard let data = try readData(account, keychain: targetKeychain) else { return nil }
                return Entry(account: account, data: data)
            }
        }, read: { account in
            try readData(account, keychain: try keychain())
        }, write: { account, data in
            let targetKeychain = try keychain()
            let q = query(account, keychain: targetKeychain)
            let values: [String: Any] = [kSecValueData as String: data]
            let status = api.update(q as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                var item = q; values.forEach { item[$0.key] = $0.value }
                item.removeValue(forKey: kSecMatchSearchList as String)
                item[kSecUseKeychain as String] = targetKeychain
                item[kSecAttrAccess as String] = try access()
                // Metadata is deliberately generic; the user's name and profile label remain in the encrypted payload.
                item[kSecAttrLabel as String] = "Ppomi identity profile"
                let added = api.add(item as CFDictionary, nil)
                if added == errSecDuplicateItem { try check(api.update(q as CFDictionary, values as CFDictionary)) }
                else { try check(added) }
            } else { try check(status) }
        }, remove: { account in
            let status = api.delete(query(account, keychain: try keychain()) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        })
    }

    static func systemDefaultKeychain() throws -> Any {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let keychain else { throw Failure.corrupt }
        return keychain
    }

    static func systemAppAccess() throws -> Any {
        var access: SecAccess?
        // Apple's SecAccessCreate nil trusted-list means only the calling app is trusted for restricted operations.
        let status = SecAccessCreate("Ppomi identity profile" as CFString, nil, &access)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let access else { throw Failure.corrupt }
        return access
    }
}
