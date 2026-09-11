// DeviceRegistry.attach shape (MZZ-50): Clerk/Google is who; this Mac session is where.
// In-memory + optional fleet.json next to the ledger. No tokens, passwords, keys, or account emails on this port.
import Foundation
import CryptoKit

enum DeviceOs: String, Codable, CaseIterable {
    case macos, windows, android, ios
}

struct FleetDevice: Codable, Equatable, Sendable {
    var id: String
    var os: DeviceOs
    var online: Bool
    var lastSeen: String
    var ownerId: String
    var orgId: String?
}

struct DeviceSessionAttach: Equatable, Sendable {
    var deviceId: String
    var os: DeviceOs
    var ownerId: String
    var orgId: String?
    /// Test clock. Production callers omit this; attach stamps now.
    var lastSeen: String?
}

struct DeviceListScope: Equatable, Sendable {
    var ownerId: String
    var orgId: String?
}

/// App-logged-in machines. Same attach/list upsert a later store implements.
final class DeviceRegistry: @unchecked Sendable {
    static let shared = DeviceRegistry()

    private let lock = NSLock()
    private var devices: [String: FleetDevice] = [:]
    /// ponytail: process-local map + optional JSON; durable multi-app store if a second body must share the fleet.
    var persistURL: URL?

    enum Failure: Error, CustomStringConvertible {
        case required(String)
        case unknownOS(String)
        case ownerMismatch(String)
        var description: String {
            switch self {
            case .required(let field): return "\(field) is required"
            case .unknownOS(let os): return "unknown device os: \(os)"
            case .ownerMismatch(let id): return "owner_mismatch: \(id)"
            }
        }
    }

    /// `allowReown` is set only by `attachThisMac` for this Mac's own device id (the signed-in person owns this machine).
    /// Every other caller keeps the default: a different owner/org may not silently re-attach an existing id.
    func attach(_ input: DeviceSessionAttach, allowReown: Bool = false) throws -> FleetDevice {
        let deviceId = input.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerId = input.ownerId.trimmingCharacters(in: .whitespacesAndNewlines)
        if deviceId.isEmpty { throw Failure.required("deviceId") }
        if ownerId.isEmpty { throw Failure.required("ownerId") }
        let record = FleetDevice(
            id: deviceId,
            os: input.os,
            online: true,
            lastSeen: input.lastSeen ?? ISO8601DateFormatter().string(from: Date()),
            ownerId: ownerId,
            orgId: input.orgId
        )
        lock.lock()
        // Refuse a cross-owner re-attach (mirror ppomi-brain owner_mismatch); same-owner re-attach just refreshes.
        if !allowReown, let existing = devices[deviceId], existing.ownerId != ownerId || existing.orgId != input.orgId {
            lock.unlock()
            throw Failure.ownerMismatch(deviceId)
        }
        devices[deviceId] = record
        let snapshot = Array(devices.values)
        let url = persistURL
        lock.unlock()
        if let url { Self.write(snapshot, to: url) }
        return record
    }

    func list(_ scope: DeviceListScope) -> [FleetDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.filter { device in
            if device.ownerId != scope.ownerId { return false }
            if let org = scope.orgId, device.orgId != org { return false }
            return true
        }
    }

    /// This Mac's session. The persisted owner is opaque (never the Google email); this device may re-own its own id.
    func attachThisMac(deviceId: String = GoogleAccount.deviceID, ownerId: String? = nil) -> FleetDevice {
        let owner = (ownerId ?? Self.opaqueOwner(email: GoogleAccount.session?.email))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = owner.isEmpty ? "local" : owner
        return (try? attach(DeviceSessionAttach(deviceId: deviceId, os: .macos, ownerId: resolved), allowReown: true))
            ?? FleetDevice(id: deviceId, os: .macos, online: true,
                           lastSeen: ISO8601DateFormatter().string(from: Date()),
                           ownerId: resolved, orgId: nil)
    }

    /// Opaque, stable owner id for the local fleet file. Never the Google email: signed in → a per-Mac salted hash
    /// of the account subject; signed out → "local". Two accounts on one Mac hash differently, so ownership tracks the person.
    static func opaqueOwner(email: String?) -> String {
        let account = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { return "local" }
        let defaults = UserDefaults.standard
        let salt = defaults.string(forKey: "fleetOwnerSalt") ?? {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: "fleetOwnerSalt")
            return generated
        }()
        let hex = SHA256.hash(data: Data("\(salt)\u{0}\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "owner:" + String(hex.prefix(24))
    }

    func loadPersisted() {
        guard let url = persistURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([FleetDevice].self, from: data) else {
            fputs("fleet: \(url.lastPathComponent)을 읽을 수 없어 빈 상태로 시작합니다.\n", stderr)
            return
        }
        // Last write wins on a duplicate id: a hand-merged or restored file must not crash launch.
        lock.lock(); devices = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }); lock.unlock()
    }

    static func displayLine(_ device: FleetDevice) -> String {
        "이 Mac · \(device.os.rawValue) · \(device.online ? "온라인" : "오프라인")"
    }

    private static func write(_ rows: [FleetDevice], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)   // opaque owner id is local-only
    }
}
