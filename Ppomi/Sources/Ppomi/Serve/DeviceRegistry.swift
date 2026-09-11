// DeviceRegistry.attach shape (MZZ-50): Clerk/Google is who; this Mac session is where.
// In-memory + optional fleet.json next to the ledger. No tokens, passwords, or keys on this port.
import Foundation

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
        var description: String {
            switch self {
            case .required(let field): return "\(field) is required"
            case .unknownOS(let os): return "unknown device os: \(os)"
            }
        }
    }

    func attach(_ input: DeviceSessionAttach) throws -> FleetDevice {
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

    /// This Mac's session: Google email when signed in, else a local owner. Never a business registration number.
    func attachThisMac(deviceId: String = GoogleAccount.deviceID, ownerId: String? = nil) -> FleetDevice {
        let owner = (ownerId ?? GoogleAccount.session?.email ?? "local")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? attach(DeviceSessionAttach(deviceId: deviceId, os: .macos, ownerId: owner.isEmpty ? "local" : owner)))
            ?? FleetDevice(id: deviceId, os: .macos, online: true,
                           lastSeen: ISO8601DateFormatter().string(from: Date()),
                           ownerId: owner.isEmpty ? "local" : owner, orgId: nil)
    }

    func loadPersisted() {
        guard let url = persistURL, let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([FleetDevice].self, from: data) else { return }
        lock.lock(); devices = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }); lock.unlock()
    }

    static func displayLine(_ device: FleetDevice) -> String {
        "이 Mac · \(device.os.rawValue) · \(device.online ? "온라인" : "오프라인")"
    }

    private static func write(_ rows: [FleetDevice], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(rows) { try? data.write(to: url, options: .atomic) }
    }
}
