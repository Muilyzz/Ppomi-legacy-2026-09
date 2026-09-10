import Foundation
import CoreGraphics

/// The observed KB corporate certificate issuance page (인증서 발급/재발급 1단계 · 사용자 본인확인), not the ID-lookup popup.
/// OCR proves the origin and the two-line 사업자등록번호 row; pixels find the three bordered boxes to its right (Vision drops the
/// small dashes between them here) and prove each is empty. The private focus check must still prove the click landed in a
/// focused input before any digit is sent, and nothing here reads or reconstructs typed values.
enum KBCertificateFormGeometry {
    static let boxPrefix = "__ppomi_kb_box_"
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func centerY(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
    private static func failure() -> ProfileTools.Failure {
        .init(message: "KB 인증서 발급 본인확인의 정확한 주소·사업자등록번호 행·입력칸을 확인하지 못했습니다. 개인정보를 입력하지 않았습니다.")
    }

    private static func address(_ word: OCR.Word) -> Bool {
        var text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("a ") { text.removeFirst(2) }   // Edge's lock glyph as OCR sees it
        guard !text.contains(where: \.isWhitespace), let url = URLComponents(string: text), url.scheme == "https", url.host == "obank.kbstar.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443, url.percentEncodedPath == "/quics",
              url.fragment == nil || url.fragment == "loading", let items = url.queryItems else { return false }
        // Vision reads the zero in C019623 as the letter O at some window sizes; nothing else in the value may differ.
        return items.count == 1 && items[0].name == "page" && items[0].value?.replacingOccurrences(of: "O", with: "0") == "C019623"
    }

    /// Row anchor: 사업자등록번호 over (납세번호/고유번호) in the left label column, the address bar above, 사용자 ID above and 주민등록번호 below.
    private struct Row {
        let label: OCR.Word, sub: OCR.Word
        var y: Double { (label.y + label.h / 2 + sub.y + sub.h / 2) / 2 }
        var h: Double { max(label.h, sub.h) }
    }
    private static func row(_ words: [OCR.Word]) -> Row? {
        let labels = words.filter { compact($0.text).trimmingCharacters(in: CharacterSet(charactersIn: ".。·,")) == "사업자등록번호" && $0.h > 0.008 && $0.h < 0.04 && $0.x > 0.2 && $0.x < 0.5 }   // OCR may append a period
        guard labels.count == 1, let label = labels.first else { return nil }
        let subs = words.filter { compact($0.text) == "(납세번호/고유번호)" && abs($0.x - label.x) < label.h * 1.5 && $0.y > label.y && $0.y - (label.y + label.h) < label.h * 1.5 }
        guard subs.count == 1, let sub = subs.first,
              words.contains(where: { $0.y >= 0.03 && $0.y < 0.25 && $0.y + $0.h < label.y && address($0) }),
              words.contains(where: { compact($0.text) == "사용자ID" && abs($0.x - label.x) < label.h * 1.5 && $0.y + $0.h < label.y }),
              words.contains(where: { compact($0.text) == "주민등록번호" && abs($0.x - label.x) < label.h * 1.5 && $0.y > sub.y + sub.h }) else { return nil }
        return Row(label: label, sub: sub)
    }

    /// Pixel pass: nil when this is not the KB form. Otherwise the words plus one box word per slot and an empty marker per empty box.
    /// Boxes are pairs of vertical border runs crossing the row middle; a top-left corner may be rendered a few pixels short, so the
    /// horizontal edges only need most of the width. Emptiness is the box interior being bright apart from a caret.
    static func enrich(_ words: [OCR.Word], png: URL) throws -> [OCR.Word]? {
        guard let row = row(words), !words.contains(where: { $0.text.hasPrefix(boxPrefix) }), let p = try BusinessFormGeometry.read(png) else { return nil }
        let W = Double(p.width), H = Double(p.height), h = max(4, Int(ceil(row.h * H))), middle = Int((row.y * H).rounded())
        guard middle > h * 2, middle < p.height - h * 2 else { return nil }
        let start = Int(((row.label.x + row.label.w) * W).rounded()) + h / 2, limit = Int(0.75 * W)
        // An edge is the start of a thin vertical faint band (a 1px border or a focus outline up to h/4 wide) with bright air
        // right before and after the band on all three middle rows. Carets and glyph strokes also qualify here; the side test rejects them.
        let band = max(2, h / 4)
        func faint(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < p.width && p.faint[p.index(x, y)] }
        var edges: [Int] = [], x = max(1, start)
        while x < min(limit, p.width - 2) {
            guard ((middle - 1)...(middle + 1)).allSatisfy({ faint(x, $0) && !faint(x - 1, $0) }) else { x += 1; continue }
            var end = x
            while end + 1 < p.width, ((middle - 1)...(middle + 1)).allSatisfy({ faint(end + 1, $0) }) { end += 1 }
            if end - x + 1 <= band, ((middle - 1)...(middle + 1)).allSatisfy({ !faint(end + 1, $0) }) { edges.append(x) }
            x = end + 1
        }
        func coverage(_ y: Int, _ l: Int, _ r: Int) -> Double { Double((l...r).filter { p.faint[p.index($0, y)] }.count) / Double(r - l + 1) }
        func box(_ l: Int, _ r: Int) -> BusinessFormGeometry.Component? {
            guard r - l >= h * 2, r - l <= h * 8 else { return nil }
            guard let top = ((max(0, middle - h * 2))...(middle - 3)).reversed().first(where: { coverage($0, l, r) >= 0.85 }),
                  let bottom = ((middle + 3)...min(p.height - 1, middle + h * 2)).first(where: { coverage($0, l, r) >= 0.85 }) else { return nil }
            let rows = Double(bottom - top + 1)
            guard Double((top...bottom).filter { p.faint[p.index(l, $0)] }.count) / rows >= 0.85,
                  Double((top...bottom).filter { p.faint[p.index(r, $0)] }.count) / rows >= 0.85 else { return nil }
            return BusinessFormGeometry.Component(left: l, top: top, right: r, bottom: bottom)
        }
        func empty(_ b: BusinessFormGeometry.Component) -> Bool {
            let inset = band + 2   // clears a focus outline as well as a plain border
            guard b.right - b.left > inset * 2 + 2, b.bottom - b.top > inset * 2 + 2 else { return false }
            var pts: [(Int, Int)] = []
            for y in (b.top + inset)...(b.bottom - inset) { for x in (b.left + inset)...(b.right - inset) where !p.bright[p.index(x, y)] { pts.append((x, y)) } }
            if pts.isEmpty { return true }
            let xs = pts.map { $0.0 }, ys = pts.map { $0.1 }
            let w = xs.max()! - xs.min()! + 1, hh = ys.max()! - ys.min()! + 1   // a lone insertion caret at the left padding is still empty
            return w <= max(2, h / 8) && hh >= h / 2 && xs.min()! - b.left <= h && Double(pts.count) / Double(w * hh) >= 0.8
        }
        // Pair each left edge with the first later edge that closes a real box; skip past that box afterwards.
        var boxes: [BusinessFormGeometry.Component] = [], i = 0
        while i < edges.count, boxes.count < 3 {
            var matched = false
            for j in (i + 1)..<edges.count where edges[j] - edges[i] <= h * 8 {
                if let b = box(edges[i], edges[j]) { boxes.append(b); i = edges.firstIndex(where: { $0 > b.right }) ?? edges.count; matched = true; break }
            }
            if !matched { i += 1 }
        }
        guard boxes.count == 3, zip(boxes, boxes.dropFirst()).allSatisfy({ $1.left > $0.right && abs($1.width - $0.width) < $0.width / 2 && abs($1.top - $0.top) <= h / 2 }) else { return nil }
        var out = words
        for (i, b) in boxes.enumerated() {
            let x = Double(b.left) / W, w = Double(b.width) / W, y = Double(b.top) / H, hh = Double(b.height) / H
            out.append(OCR.Word(x: x, y: y, w: w, h: hh, text: boxPrefix + "\(i + 1)__"))
            if empty(b) { out.append(BusinessFormGeometry.emptyMarker(segment: i + 1, x: x + w / 2, y: row.y)) }
        }
        return out
    }

    /// The requested slot's box, only when the page, the row and all three boxes are proven and the point is inside that box.
    static func region(_ words: [OCR.Word], target: ProfileFormFiller.Target) throws -> CGRect {
        guard target.form == .kbCertificate, target.field == .businessRegistrationNumber, target.bankID == nil,
              let segment = target.segment, (1...3).contains(segment), target.x.isFinite, target.y.isFinite, let row = row(words) else { throw failure() }
        let credential: Set<String> = ["비밀번호", "인증번호", "인증서암호", "인증서비밀번호", "보안카드", "보안키패드", "otp", "pin", "password", "passcode", "인증서선택", "공동인증서선택"]
        guard !words.contains(where: { credential.contains(compact($0.text).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":：*"))) }) else { throw failure() }
        let boxes = (1...3).map { n in words.filter { $0.text == boxPrefix + "\(n)__" && $0.w > 0 && $0.h > 0 } }
        guard boxes.allSatisfy({ $0.count == 1 }), let box = boxes[segment - 1].first,
              boxes[0][0].x < boxes[1][0].x, boxes[1][0].x < boxes[2][0].x, boxes[0][0].x > row.label.x + row.label.w,
              boxes.allSatisfy({ abs(centerY($0[0]) - row.y) < row.h * 1.5 }) else { throw failure() }
        let rect = CGRect(x: box.x, y: box.y, width: box.w, height: box.h)
        guard rect.contains(CGPoint(x: target.x, y: target.y)) else { throw failure() }
        return rect
    }
}
