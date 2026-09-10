// 아이패드 연결: 초대 토큰(서버, 10분·일회용) + 기록 암호화 키(이 Mac 키체인)를 QR 하나로. 아이패드가 구글 로그인 뒤 이걸 읽어
// 같은 작업 공간에 자기 기기를 등록하고(ppomi_register_device) 서버의 암호화 기록을 읽는다. 키는 QR 로만 오간다 — 서버에는 없다.
import AppKit
import CoreImage.CIFilterBuiltins

enum PadPairing {
    static let rpcNames: Set<String> = ["ppomi_create_invite"]
    struct Payload: Codable { let invite: String; let workspaceID: String; let keyID: String; let key: Data; let records: [String: String] }

    static func payload() throws -> String {
        let key = try SharedRecordVault.loadKey()
        guard let reply = try SharedServerClient.shared.rpc("ppomi_create_invite", [:]) as? [String: Any],
              let invite = reply["token"] as? String else { throw SharedServerError.invalidResponse }
        let data = try JSONEncoder().encode(Payload(invite: invite, workspaceID: key.workspaceID, keyID: key.keyID, key: key.key, records: key.records))
        return String(decoding: data, as: UTF8.self)
    }
    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: image); let out = NSImage(size: rep.size); out.addRepresentation(rep); return out
    }
}
