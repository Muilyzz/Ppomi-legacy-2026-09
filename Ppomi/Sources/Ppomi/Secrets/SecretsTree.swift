// Storybook `storybook/secrets.js` (#64/#66) rules, in Swift. No Storybook runtime.
// Locked: account-key leaves only show ****last4; every other leaf is ••••. Unlocked: plaintext.
import Foundation

enum SecretsTree {
    static let accountKeys = ["account", "accountNumber", "accountNo", "acct", "계좌", "계좌번호"]
    static let maxDepth = 32
    static let mask = "••••"

    struct Chip: Equatable {
        var path: [String]
        var key: String
        var chip: String
    }

    static func unwrap(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return text }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) ?? text
    }

    static func digits(of value: Any) -> String {
        stringish(value).filter { $0 >= "0" && $0 <= "9" }
    }

    static func last4(_ value: Any) -> String? {
        let digits = digits(of: value)
        return digits.count >= 4 ? "****" + digits.suffix(4) : nil
    }

    static func normKey(_ key: String) -> String {
        key.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" }
    }

    static func keyToken(_ path: [String]) -> String {
        let last = path.last ?? ""
        let token = last.split { "/.:".contains($0) }.last.map(String.init) ?? last
        return normKey(token)
    }

    static func isAccountKey(_ path: [String], accountKeys: [String] = accountKeys) -> Bool {
        accountKeys.map(normKey).contains(keyToken(path))
    }

    static func accountish(path: [String], value: Any, accountKeys: [String] = accountKeys) -> Bool {
        isAccountKey(path, accountKeys: accountKeys) && last4(value) != nil
    }

    static func maskLeaf(path: [String], value: Any, accountKeys: [String] = accountKeys) -> String {
        accountish(path: path, value: value, accountKeys: accountKeys) ? last4(value)! : mask
    }

    static func display(path: [String], value: Any?, unlocked: Bool, accountKeys: [String] = accountKeys) -> String {
        guard let value, !(value is NSNull) else { return "—" }
        if isSecretLeaf(value) && !unlocked { return maskLeaf(path: path, value: value, accountKeys: accountKeys) }
        return stringish(value)
    }

    static func isSecretLeaf(_ value: Any) -> Bool {
        if value is String { return true }
        if let number = value as? NSNumber { return CFGetTypeID(number) != CFBooleanGetTypeID() }
        return false
    }

    static func stringish(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return String(describing: value)
    }

    static func asObject(_ value: Any?) -> [String: Any]? {
        let value = unwrap(value)
        if let object = value as? [String: Any] { return object }
        guard let object = value as? NSDictionary else { return nil }
        var out: [String: Any] = [:]
        for (key, child) in object {
            guard let key = key as? String else { continue }
            out[key] = child
        }
        return out
    }

    static func asArray(_ value: Any?) -> [Any]? {
        let value = unwrap(value)
        if let array = value as? [Any] { return array }
        return value as? [Any]
    }

    static func isContainer(_ value: Any?) -> Bool {
        asObject(value) != nil || asArray(value) != nil
    }

    static func children(_ value: Any?) -> [(key: String, path: String, value: Any)] {
        if let array = asArray(value) {
            return array.enumerated().map { (key: "\($0.offset)", path: "\($0.offset)", value: $0.element) }
        }
        if let object = asObject(value) {
            return object.keys.sorted().map { (key: $0, path: $0, value: object[$0] as Any) }
        }
        return []
    }

    static func atPath(_ value: Any?, _ path: [String]) -> Any? {
        var current = unwrap(value)
        for step in path {
            if let array = asArray(current), let index = Int(step), array.indices.contains(index) {
                current = unwrap(array[index]); continue
            }
            if let object = asObject(current) { current = unwrap(object[step]); continue }
            return nil
        }
        return current
    }

    static func eachLeaf(_ value: Any?, path: [String] = [], visit: ([String], Any) -> Void) {
        guard path.count < maxDepth else { return }
        let value = unwrap(value)
        if let array = asArray(value) {
            for (index, child) in array.enumerated() { eachLeaf(child, path: path + ["\(index)"], visit: visit) }
            return
        }
        if let object = asObject(value) {
            for key in object.keys.sorted() { eachLeaf(object[key], path: path + [key], visit: visit) }
            return
        }
        if let value { visit(path, value) }
    }

    static func chips(of value: Any?, accountKeys: [String] = accountKeys) -> [Chip] {
        var out: [Chip] = []
        eachLeaf(value) { path, leaf in
            guard accountish(path: path, value: leaf, accountKeys: accountKeys), let chip = last4(leaf) else { return }
            let key = path.first(where: { $0.hasPrefix("ppomi/") }) ?? path.last ?? ""
            out.append(Chip(path: path, key: key, chip: chip))
        }
        return out.sorted { $0.key < $1.key }
    }

    static func containsPlaintext(_ haystack: String, from blob: Any) -> Bool {
        var found = false
        eachLeaf(blob) { _, leaf in
            guard isSecretLeaf(leaf) else { return }
            let text = stringish(leaf)
            if !text.isEmpty, haystack.contains(text) { found = true }
        }
        return found
    }
}
