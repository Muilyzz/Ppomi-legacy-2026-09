// 등기사항전부증명서(부동산 등기부등본) PDF → 사실. 표제부의 소재지, 갑구의 소유권이전(거래가액), 을구의 근저당(채권최고액·근저당권자).
// 주민등록번호는 읽지 않는다. 소유자 이름은 첫 글자만 남긴다. 말소된 순위번호는 뺀다.
import Foundation
import PDFKit

enum RegistryExtract {
    struct Owner: Equatable { var name: String; var share: String?; var price: Int?; var received: String?; var cause: String? }
    struct Mortgage: Equatable { var rank: Int; var maxClaim: Int; var creditor: String; var received: String?; var cancelled: Bool }
    struct Facts: Equatable { var address: String?; var owners: [Owner]; var mortgages: [Mortgage] }

    static func text(of url: URL, password: String? = nil) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw Failure(message: "PDF를 열지 못했습니다.") }
        if doc.isLocked, !doc.unlock(withPassword: password ?? "") { throw Failure(message: "PDF 비밀번호가 필요합니다.") }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }
    struct Failure: Error { let message: String }

    // 등기소 PDF는 글자 사이에 공백이 끼는 일이 많다: 키워드는 글자마다 \s* 를 허용한다.
    private static func loose(_ s: String) -> String { s.map { "\\s*" + NSRegularExpression.escapedPattern(for: String($0)) }.joined() }
    private static let won = #"금\s*([\d,\s]+?)\s*원"#
    private static let date = #"(\d{4})\s*년\s*(\d{1,2})\s*월\s*(\d{1,2})\s*일"#
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) }
    private static func amount(_ s: String) -> Int? { Int(s.filter(\.isNumber)) }
    private static func iso(_ m: NSTextCheckingResult, _ s: NSString, from i: Int) -> String {
        String(format: "%@-%02d-%02d", s.substring(with: m.range(at: i)), Int(s.substring(with: m.range(at: i + 1)))!, Int(s.substring(with: m.range(at: i + 2)))!)
    }

    static func parse(_ raw: String) -> Facts {
        let s = raw as NSString, all = NSRange(location: 0, length: s.length)
        // 세 부(部)로 자른다: 【 표 제 부 】 … 【 갑 구 】 … 【 을 구 】
        func section(_ name: String, until next: String?) -> String {
            guard let a = re(loose("【") + "\\s*" + loose(name) + "\\s*" + loose("】")).firstMatch(in: raw, range: all) else { return "" }
            let start = a.range.location + a.range.length
            let end = next.flatMap { re(loose("【") + "\\s*" + loose($0) + "\\s*" + loose("】")).firstMatch(in: raw, range: NSRange(location: start, length: s.length - start))?.range.location } ?? s.length
            return s.substring(with: NSRange(location: start, length: end - start))
        }
        let head = section("표제부", until: "갑구"), gap = section("갑구", until: "을구"), eul = section("을구", until: nil)
        var facts = Facts(address: nil, owners: [], mortgages: [])
        if let m = re(#"\[\s*집합건물\s*\]\s*([^\n\[]+)|\[\s*건물\s*\]\s*([^\n\[]+)|\[\s*토지\s*\]\s*([^\n\[]+)"#).firstMatch(in: raw, range: all) {
            for i in 1...3 where m.range(at: i).location != NSNotFound { facts.address = s.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespacesAndNewlines); break }
        } else if let m = re(loose("소재지번") + #"[^\n]*?\n?\s*([^\n]+)"#).firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
            facts.address = (head as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 갑구: 행 = '순위 | 등기목적(소유권이전…) | 접수일 제N호 | 원인일 매매 | 소유자 홍길동 800101-******* 주소 … 거래가액 금N원'.
        // 행 경계는 등기목적 키워드로 잡는다(PDF 본문은 열이 줄로 흩어진다): 접수일·원인은 키워드와 소유자 사이, 거래가액은 소유자와 다음 소유자 사이.
        let g = gap as NSString, gAll = NSRange(location: 0, length: g.length)
        let owners = re(loose("소유자") + #"\s+([가-힣A-Za-z]+)|"# + loose("공유자") + #"\s+지분\s*([\d분의\s]+?)\s+([가-힣A-Za-z]+)"#).matches(in: gap, range: gAll)
        let purposes = re(#"소유권\s*(?:일부)?\s*(?:보존|이전|경정)"#).matches(in: gap, range: gAll).map(\.range.location)
        for (k, m) in owners.enumerated() {
            let name = m.range(at: 1).location != NSNotFound ? g.substring(with: m.range(at: 1)) : g.substring(with: m.range(at: 3))
            let share = m.range(at: 2).location != NSNotFound ? g.substring(with: m.range(at: 2)).replacingOccurrences(of: " ", with: "") : nil
            let rowStart = purposes.last { $0 < m.range.location } ?? 0
            let rowEnd = purposes.first { $0 > m.range.location } ?? g.length
            let head = NSRange(location: rowStart, length: m.range.location - rowStart)
            let next = k + 1 < owners.count ? min(owners[k + 1].range.location, rowEnd) : rowEnd
            let tail = NSRange(location: m.range.location, length: next - m.range.location)
            let price = re(loose("거래가액") + "\\s*" + won).firstMatch(in: gap, range: tail).flatMap { amount(g.substring(with: $0.range(at: 1))) }
            let dates = re(date).matches(in: gap, range: head)
            let received = dates.first.map { iso($0, g, from: 1) }                       // 접수일이 먼저, 등기원인일이 다음에 온다
            let cause = re(date + #"\s*(매매|증여|상속|분양|교환|경매|신탁|재산분할)"#).matches(in: gap, range: head).last.map { g.substring(with: $0.range(at: 4)) }
            facts.owners.append(Owner(name: String(name.prefix(1)) + String(repeating: "*", count: max(0, name.count - 1)), share: share, price: price, received: received, cause: cause))
        }
        // 을구: 순위번호 | 근저당권설정 | 접수 | … 채권최고액 금N원 … 근저당권자 주식회사신한은행 ; 'N번근저당권설정등기말소'가 뒤에 오면 말소
        let e = eul as NSString
        let cancelled = Set(re(#"(\d+)\s*번\s*"# + loose("근저당권설정등기말소")).matches(in: eul, range: NSRange(location: 0, length: e.length)).compactMap { Int(e.substring(with: $0.range(at: 1))) })
        for m in re(#"(?m)^\s*(\d+)\s*[|\s]+"# + loose("근저당권설정") + #"(?!등기말소)"#).matches(in: eul, range: NSRange(location: 0, length: e.length)) {
            let rank = Int(e.substring(with: m.range(at: 1)))!
            let tail = NSRange(location: m.range.location, length: min(900, e.length - m.range.location))
            guard let mc = re(loose("채권최고액") + "\\s*" + won).firstMatch(in: eul, range: tail), let max = amount(e.substring(with: mc.range(at: 1))) else { continue }
            let creditor = re(loose("근저당권자") + #"\s+([^\s\d]+)"#).firstMatch(in: eul, range: tail).map { e.substring(with: $0.range(at: 1)) } ?? ""
            let received = re(date).firstMatch(in: eul, range: tail).map { iso($0, e, from: 1) }
            facts.mortgages.append(Mortgage(rank: rank, maxClaim: max, creditor: creditor, received: received, cancelled: cancelled.contains(rank)))
        }
        return facts
    }

    /// MCP: 파일 하나를 읽어 사실만 JSON 으로. 이름은 첫 글자만, 주민번호는 읽지 않는다.
    static func read(path: String, password: String?) throws -> String {
        let f = parse(try text(of: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), password: password))
        let out: [String: Any] = [
            "address": f.address ?? "",
            "owners": f.owners.map { ["name": $0.name, "share": $0.share ?? "", "price": $0.price ?? 0, "received": $0.received ?? "", "cause": $0.cause ?? ""] },
            "mortgages": f.mortgages.map { ["rank": $0.rank, "max_claim": $0.maxClaim, "creditor": $0.creditor, "received": $0.received ?? "", "cancelled": $0.cancelled] },
            "notice": f.owners.isEmpty && f.mortgages.isEmpty ? "갑구·을구를 찾지 못했다. 등기사항전부증명서 PDF 가 맞는지, 스캔본이면 OCR 이 필요한지 확인." : "취득가는 거래가액 + 취득세·중개수수료. 살아 있는 근저당의 채권최고액은 보통 대출의 110~120%."]
        return String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
