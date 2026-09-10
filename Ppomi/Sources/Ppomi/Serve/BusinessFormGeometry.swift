import Foundation
import CoreGraphics
import ImageIO

/// Local-only pixel evidence for the two separators in EAIS's three-box business-number row.
/// OCR sometimes drops a small hyphen. This only restores independently observed isolated ink, never an inferred position.
/// The PNG is supplied by privateScreen while its temporary file is alive; this type does not create or retain files.
enum BusinessFormGeometry {
    struct Plane {
        let width, height: Int
        let ink, bright, border, core, faint: [Bool]   // faint: a lighter border class for thin input edges that fractional scaling washes out
        func index(_ x: Int, _ y: Int) -> Int { y * width + x }
    }
    struct Component {
        var left, top, right, bottom: Int
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
    }
    private static func compact(_ value: String) -> String { value.filter { !$0.isWhitespace }.lowercased() }
    private static func centerY(_ word: OCR.Word) -> Double { word.y + word.h / 2 }
    private static func isSeparator(_ word: OCR.Word) -> Bool { ["-", "−", "–", "—"].contains(compact(word.text)) }

    /// Vision can merge the visible label and its filled company value into one OCR word. The whole word
    /// remains the row anchor; no character-width estimate is used to invent a separate label rectangle.
    static func isBusinessNameAnchor(_ word: OCR.Word) -> Bool {
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isNewline }) else { return false }
        if compact(text) == "사업자명" { return true }
        guard text.hasPrefix("사업자명") else { return false }
        let suffix = text.dropFirst("사업자명".count)
        return suffix.first?.isWhitespace == true && !suffix.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func enrich(_ words: [OCR.Word], png: URL) throws -> [OCR.Word] {
        if let kb = try KBCertificateFormGeometry.enrich(words, png: png) { return kb }   // KB 인증서 발급 폼은 구분선 없이 상자 셋을 픽셀로 찾는다
        let names = words.filter(isBusinessNameAnchor)
        let numbers = words.filter { compact($0.text) == "사업자등록번호" }
        guard names.count == 1, numbers.count == 1, let name = names.first, let number = numbers.first,
              name.h > 0, number.h > 0, name.x >= 0, name.x < 0.35,
              number.x > name.x + name.w + name.h, number.x < 0.80,
              abs(centerY(name) - centerY(number)) <= max(name.h, number.h),
              name.y > 0.18, name.y < 0.70,
              words.contains(where: { word in
                  let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard word.y >= 0.03, word.y < 0.25, word.y + word.h < min(name.y, number.y),
                        let start = text.range(of: "https://", options: .caseInsensitive)?.lowerBound,
                        let token = text[start...].split(whereSeparator: \.isWhitespace).first,
                        let url = URLComponents(string: String(token)) else { return false }
                  return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.eais.go.kr" &&
                      url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
                      url.percentEncodedPath == "/moct/awp/aba01/AWPABA01F04" && url.fragment == nil
              }) else { return words }
        let rowY = centerY(number), textHeight = max(name.h, number.h)
        let existing = words.filter {
            isSeparator($0) && $0.x > number.x + number.w && abs(centerY($0) - rowY) <= max(0.014, textHeight)
        }
        // Complete OCR needs no fallback; conflicting/excessive OCR is not repaired by discarding evidence.
        guard existing.count <= 2, let plane = try read(png) else { return words }
        if existing.count == 2 { return appendEmptyEvidence(words, plane: plane, number: number, textHeight: textHeight) }
        let h = max(1, Int(ceil(textHeight * Double(plane.height))))
        let left = max(0, Int(ceil((number.x + number.w) * Double(plane.width))))
        let right = min(plane.width - 1, Int(floor(0.995 * Double(plane.width))))
        let middle = Int((rowY * Double(plane.height)).rounded())
        let top = max(0, middle - h), bottom = min(plane.height - 1, middle + h)
        guard left < right, top < bottom else { return words }
        let components = components(plane, left: left, top: top, right: right, bottom: bottom)
        let candidates = components.filter { c in
            let width = c.width, height = c.height
            guard c.left > left, c.right < right, c.top > top, c.bottom < bottom,
                  width >= 3, width <= max(5, Int(ceil(Double(h) * 0.85))),
                  height >= 1, height <= max(2, h / 4),
                  (Double(width) / Double(height) >= 2.5 || horizontalCore(plane, component: c)),
                  abs(Double(c.top + c.bottom) / 2 - Double(middle)) <= Double(h) * 0.50 else { return false }
            // An isolated dash has bright air around all sides. Broken glyph strokes and joined borders do not qualify.
            let pad = max(2, min(3, h / 5))
            return clearSurrounding(plane, component: c, padding: pad)
        }.sorted { $0.left < $1.left }
        guard candidates.count == 2 else { return words }
        let observed = candidates.map { c in
            OCR.Word(x: Double(c.left) / Double(plane.width), y: Double(c.top) / Double(plane.height),
                     w: Double(c.width) / Double(plane.width), h: Double(c.height) / Double(plane.height), text: "-")
        }
        // If OCR did see one separator, the independent pixel evidence must agree with that location.
        guard existing.allSatisfy({ old in observed.contains(where: { fresh in
            fresh.x >= old.x - textHeight * 0.5 && fresh.x + fresh.w <= old.x + old.w + textHeight * 0.5 &&
                abs(centerY(fresh) - centerY(old)) <= textHeight * 0.5
        }) }) else { return words }
        let pitch = observed[1].x - observed[0].x
        guard pitch > textHeight * 2, pitch < 0.30 else { return words }
        let result = words.filter { word in !existing.contains(where: { $0.x == word.x && $0.y == word.y && $0.text == word.text }) } + observed
        return appendEmptyEvidence(result, plane: plane, number: number, textHeight: textHeight)
    }

    /// Zero-area metadata is created from local pixel evidence, never from OCR text or a requested coordinate.
    /// A masked field without this evidence is not automatically overwritten on a subsequent fill call.
    static func emptyMarker(segment: Int, x: Double, y: Double) -> OCR.Word {
        OCR.Word(x: x, y: y, w: 0, h: 0, text: "__ppomi_business_empty_\(segment)__")
    }
    static func hasEmptyEvidence(_ words: [OCR.Word], segment: Int, x: Double, y: Double) -> Bool {
        let matches = words.filter { $0.text == "__ppomi_business_empty_\(segment)__" && $0.w == 0 && $0.h == 0 }
        return matches.count == 1 && matches.contains { abs($0.x - x) < 0.09 && abs($0.y - y) < 0.02 }
    }

    private static func appendEmptyEvidence(_ words: [OCR.Word], plane p: Plane, number: OCR.Word, textHeight: Double) -> [OCR.Word] {
        let rowY = centerY(number)
        let separators = words.filter {
            isSeparator($0) && $0.w > 0 && $0.w <= textHeight && $0.x > number.x + number.w &&
                abs(centerY($0) - rowY) <= max(0.014, textHeight)
        }.sorted { $0.x < $1.x }
        guard separators.count == 2 else { return words }
        let first = separators[0], second = separators[1], pitch = separators[1].x - separators[0].x
        guard pitch > textHeight * 2, pitch < 0.30 else { return words }
        let slots: [(Double, Double)] = [
            (max(number.x + number.w + textHeight * 0.35, first.x - pitch + first.w), first.x - textHeight * 0.20),
            (first.x + first.w + textHeight * 0.20, second.x - textHeight * 0.20),
            (second.x + second.w + textHeight * 0.20, min(0.995, second.x + pitch))
        ]
        let middle = Int((rowY * Double(p.height)).rounded()), h = max(1, Int(ceil(textHeight * Double(p.height))))
        var result = words
        for (index, slot) in slots.enumerated() {
            let left = max(0, Int(floor(slot.0 * Double(p.width))) - 1)
            let right = min(p.width - 1, Int(ceil(slot.1 * Double(p.width))) + 1)
            guard let box = inputBox(p, left: left, right: right, middle: middle, textHeight: h),
                  emptyInterior(p, box: box, textHeight: h) else { continue }
            result.append(emptyMarker(segment: index + 1, x: Double(box.left + box.right) / 2 / Double(p.width), y: rowY))
        }
        return result
    }

    /// Require the actual four-sided input border. A blank patch between inferred separators is not an empty-field proof.
    private static func inputBox(_ p: Plane, left: Int, right: Int, middle: Int, textHeight h: Int) -> Component? {
        guard left + 8 < right else { return nil }
        let minWidth = max(12, Int(Double(right - left) * 0.65)), maxWidth = right - left
        let topStart = max(1, middle - h * 3 / 2), topEnd = max(topStart, middle - max(3, h / 2))
        let bottomStart = min(p.height - 2, middle + max(3, h / 2)), bottomEnd = min(p.height - 2, middle + h * 3 / 2)
        guard topEnd < bottomStart, bottomStart <= bottomEnd else { return nil }
        var boxes: [Component] = []
        for top in topStart...topEnd {
            var x = left
            while x <= right {
                guard p.border[p.index(x, top)] else { x += 1; continue }
                let begin = x
                while x <= right && p.border[p.index(x, top)] { x += 1 }
                let end = x - 1, width = end - begin + 1
                guard begin > left, end < right, width >= minWidth, width <= maxWidth else { continue }
                for bottom in bottomStart...bottomEnd {
                    let row = (begin...end).filter { p.border[p.index($0, bottom)] }.count
                    let leftSide = (top...bottom).filter { p.border[p.index(begin, $0)] }.count
                    let rightSide = (top...bottom).filter { p.border[p.index(end, $0)] }.count
                    guard Double(row) / Double(width) >= 0.94,
                          Double(leftSide) / Double(bottom - top + 1) >= 0.90,
                          Double(rightSide) / Double(bottom - top + 1) >= 0.90 else { continue }
                    guard let box = canonicalBorder(p, box: Component(left: begin, top: top, right: end, bottom: bottom), textHeight: h) else { continue }
                    if !boxes.contains(where: { abs($0.left - box.left) <= 2 && abs($0.right - box.right) <= 2 &&
                        abs($0.top - box.top) <= 2 && abs($0.bottom - box.bottom) <= 2 }) { boxes.append(box) }
                    if boxes.count > 1 { return nil }
                }
            }
        }
        return boxes.count == 1 ? boxes.first : nil
    }

    /// Different scan rows of a thick focus outline belong to one border band, not separate input boxes.
    /// Expand only over actual contiguous horizontal border pixels; disconnected outlines stay ambiguous.
    private static func canonicalBorder(_ p: Plane, box: Component, textHeight h: Int) -> Component? {
        var result = box
        let limit = max(2, h / 3)
        func horizontal(_ y: Int) -> Bool {
            guard y >= 0, y < p.height else { return false }
            return Double((box.left...box.right).filter { p.border[p.index($0, y)] }.count) / Double(box.width) >= 0.94
        }
        for _ in 0..<limit {
            if horizontal(result.top - 1) { result.top -= 1 } else { break }
        }
        for _ in 0..<limit {
            if horizontal(result.bottom + 1) { result.bottom += 1 } else { break }
        }
        guard !horizontal(result.top - 1), !horizontal(result.bottom + 1) else { return nil }
        return result
    }

    private static func emptyInterior(_ p: Plane, box: Component, textHeight h: Int) -> Bool {
        // Determine each inner edge from the observed border's thickness. A fixed inset leaves thick focus
        // outlines in the content region, while increasing that inset blindly could hide real dots or digits.
        let limit = max(2, h / 3)
        func horizontal(_ y: Int) -> Bool {
            Double((box.left...box.right).filter { p.border[p.index($0, y)] }.count) / Double(box.width) >= 0.94
        }
        var top = box.top, bottom = box.bottom
        while top <= bottom && horizontal(top) && top - box.top <= limit { top += 1 }
        while bottom >= top && horizontal(bottom) && box.bottom - bottom <= limit { bottom -= 1 }
        guard top > box.top, bottom < box.bottom, top - box.top <= limit, box.bottom - bottom <= limit,
              bottom - top >= h else { return false }
        func vertical(_ x: Int) -> Bool {
            Double((top...bottom).filter { p.border[p.index(x, $0)] }.count) / Double(bottom - top + 1) >= 0.90
        }
        var left = box.left, right = box.right
        while left <= right && vertical(left) && left - box.left <= limit { left += 1 }
        while right >= left && vertical(right) && box.right - right <= limit { right -= 1 }
        guard left > box.left, right < box.right, left - box.left <= limit, box.right - right <= limit,
              right - left > h else { return false }
        var nonbright: [(Int, Int)] = []
        for y in top...bottom { for x in left...right { if !p.bright[p.index(x, y)] { nonbright.append((x, y)) } } }
        if nonbright.isEmpty { return true }
        // A lone insertion caret at the empty field's left padding may be visible. Digits, dots, selections and
        // ambiguous marks do not count as empty; this does not try to read or reconstruct masked values.
        let xs = nonbright.map { $0.0 }, ys = nonbright.map { $0.1 }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return false }
        let width = maxX - minX + 1, height = maxY - minY + 1
        return width <= max(1, h / 16) && height >= h / 2 && height <= h * 5 / 4 &&
            minX - box.left <= h / 2 && Double(nonbright.count) / Double(width * height) >= 0.85
    }

    private static func components(_ p: Plane, left: Int, top: Int, right: Int, bottom: Int) -> [Component] {
        var visited = Set<Int>(), result: [Component] = []
        for y in top...bottom {
            for x in left...right {
                let start = p.index(x, y)
                guard p.ink[start], visited.insert(start).inserted else { continue }
                var queue = [(x, y)], head = 0
                var component = Component(left: x, top: y, right: x, bottom: y)
                while head < queue.count {
                    let (cx, cy) = queue[head]; head += 1
                    component.left = min(component.left, cx); component.right = max(component.right, cx)
                    component.top = min(component.top, cy); component.bottom = max(component.bottom, cy)
                    for ny in max(top, cy - 1)...min(bottom, cy + 1) {
                        for nx in max(left, cx - 1)...min(right, cx + 1) {
                            let index = p.index(nx, ny)
                            if p.ink[index], visited.insert(index).inserted { queue.append((nx, ny)) }
                        }
                    }
                }
                result.append(component)
            }
        }
        return result
    }

    /// A fractional display scale can add one antialiased row to a genuine horizontal dash (for example 7×3
    /// outside, 7×2 solid ink). Keep the outer isolation test, and accept only a dense, equally wide dark core.
    private static func horizontalCore(_ p: Plane, component c: Component) -> Bool {
        var left = c.right, right = c.left, top = c.bottom, bottom = c.top, count = 0
        for y in c.top...c.bottom {
            for x in c.left...c.right where p.core[p.index(x, y)] {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y); count += 1
            }
        }
        guard count > 0 else { return false }
        let width = right - left + 1, height = bottom - top + 1
        return Double(width) / Double(height) >= 2.5 && Double(width) / Double(c.width) >= 0.80 &&
            c.width - width <= 2 && c.height - height <= 2 && Double(count) / Double(width * height) >= 0.85
    }

    private static func clearSurrounding(_ p: Plane, component c: Component, padding: Int) -> Bool {
        guard c.left >= padding, c.right + padding < p.width, c.top >= padding, c.bottom + padding < p.height else { return false }
        var count = 0, bright = 0
        for y in (c.top - padding)...(c.bottom + padding) {
            for x in (c.left - padding)...(c.right + padding) {
                if x >= c.left && x <= c.right && y >= c.top && y <= c.bottom { continue }
                count += 1
                if p.bright[p.index(x, y)] { bright += 1 }
            }
        }
        return count > 0 && Double(bright) / Double(count) >= 0.93
    }

    static func read(_ url: URL) throws -> Plane? {
        guard url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 20_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width >= 160, height >= 120, width * height <= 16_777_216 else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var ink = [Bool](repeating: false, count: width * height), bright = ink, border = ink, core = ink, faint = ink
        for i in ink.indices {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let luminance = (r * 2126 + g * 7152 + b * 722) / 10000
            ink[i] = luminance <= 180 && max(r, max(g, b)) - min(r, min(g, b)) <= 45
            bright[i] = luminance > 210
            border[i] = luminance <= 230 && max(r, max(g, b)) - min(r, min(g, b)) <= 45
            core[i] = luminance <= 110 && max(r, max(g, b)) - min(r, min(g, b)) <= 45
            faint[i] = luminance <= 244 && max(r, max(g, b)) - min(r, min(g, b)) <= 45
        }
        return Plane(width: width, height: height, ink: ink, bright: bright, border: border, core: core, faint: faint)
    }
}
