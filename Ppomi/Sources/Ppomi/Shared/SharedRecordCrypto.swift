// 서버 기록의 암호화 형식(ppomi-record-v1): Mac 이 봉인하고 아이패드가 연다. 키·기록 ID(SharedRecordKey)는 기기 키체인에만 있고 서버에는 가지 않는다.
// SharedRecordVault(Mac) 에서 떼어 낸 것: 이 파일은 Foundation·CryptoKit 뿐이라 iPad 타깃에 그대로 들어간다.
import Foundation
import CryptoKit

enum SharedRecordError: Error, LocalizedError {
    case unavailable, key, invalid, conflict, sourceChanged, oversized
    var errorDescription: String? {
        switch self {
        case .unavailable: return "서버 기록을 확인하지 못했습니다. 마지막 서버 기록을 유지합니다."
        case .key: return "이 Mac의 기록 암호화 키를 읽지 못했습니다. 원본 자료는 보존되어 있습니다."
        case .invalid: return "서버 기록의 암호화·무결성 검증에 실패했습니다."
        case .conflict: return "서버 기록 버전이 달라졌습니다. 자동으로 덮어쓰지 않았습니다."
        case .sourceChanged: return "수집 원본 경로가 바뀌었습니다. 기존 서버 기록에 자동 병합하지 않습니다."
        case .oversized: return "암호화할 기록이 현재 전송 크기 한도를 넘었습니다."
        }
    }
}

struct SharedRecordKey: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var workspaceID: String
    var deviceID: String
    var keyID: String
    var key: Data
    var records: [String: String]
    var sourcePath: String
    var description: String { "SharedRecordVault.Configuration(redacted)" }
    var debugDescription: String { description }
}

enum SharedRecordCrypto {
        static func seal(_ data: Data, configuration c: SharedRecordKey, recordID: String, version: Int64) throws -> [Data] {
        guard data.count <= 256 * 1024 * 1024 else { throw SharedRecordError.oversized }
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        var chunks: [Data] = []
        for start in stride(from: 0, to: max(compressed.count, 1), by: 400000) {
            let part = compressed.subdata(in: start..<min(start + 400000, compressed.count))
            let aad = Self.aad(c, recordID, version, chunks.count)
            guard let combined = try AES.GCM.seal(part, using: SymmetricKey(data: c.key), authenticating: aad).combined else { throw SharedRecordError.invalid }
            chunks.append(combined)
        }
        guard chunks.count <= 1024 else { throw SharedRecordError.oversized }
        return chunks
    }
    static func open(_ chunks: [Data], configuration c: SharedRecordKey, recordID: String, version: Int64) throws -> Data {
        do {
            var compressed = Data()
            for (index, chunk) in chunks.enumerated() {
                compressed.append(try AES.GCM.open(AES.GCM.SealedBox(combined: chunk), using: SymmetricKey(data: c.key),
                    authenticating: aad(c, recordID, version, index)))
            }
            let result = try (compressed as NSData).decompressed(using: .lzfse) as Data
            guard result.count <= 256 * 1024 * 1024 else { throw SharedRecordError.oversized }
            return result
        } catch { throw SharedRecordError.invalid }
    }
    private static func aad(_ c: SharedRecordKey, _ id: String, _ version: Int64, _ part: Int) -> Data {
        Data("ppomi-record-v1|\(c.workspaceID)|\(c.keyID)|\(id)|\(version)|\(part)".utf8)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
