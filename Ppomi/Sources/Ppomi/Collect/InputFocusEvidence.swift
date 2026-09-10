import Foundation
import CoreGraphics
import ImageIO

/// Local visual evidence for the known EAIS PASS form style: an active input has a dark grey outline.
/// This does not prove browser DOM focus. Unknown themes, weak/partial borders and ambiguous boxes fail closed.
enum InputFocusEvidence {
    enum Failure: Error, LocalizedError {
        case image
        var errorDescription: String? { "입력 포커스의 로컬 화면 증거를 읽지 못했습니다. 개인정보를 입력하지 않았습니다." }
    }

    private struct Box {
        var left, top, right, bottom: Int
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        func contains(_ x: Int, _ y: Int) -> Bool { x > left + 1 && x < right - 1 && y > top + 1 && y < bottom - 1 }
        func same(as other: Box) -> Bool {
            let tolerance = max(3, height / 8)
            return abs(left - other.left) <= tolerance && abs(right - other.right) <= tolerance &&
                abs(top - other.top) <= tolerance && abs(bottom - other.bottom) <= tolerance
        }
    }

    /// Pixel classes: 0 = neutral dark border, 1 = other, 2 = bright interior. Rows use image top-left coordinates.
    private struct Plane {
        let width, height: Int
        let pixels: [UInt8]
        func dark(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] == 0 }
        func light(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] == 2 }
    }

    /// `minimums` = (width, height) as fractions of the capture; the EAIS default rejects narrow boxes, KB's three business-number boxes need a lower floor.
    static func focused(png: URL, x: Double, y: Double, minimums: (width: Double, height: Double) = (0.05, 0.025)) throws -> Bool {
        guard x.isFinite, y.isFinite, x > 0, x < 1, y > 0, y < 1 else { return false }
        let plane = try read(png)
        guard plane.width >= 160, plane.height >= 120 else { return false }
        let px = Int(x * Double(plane.width)), py = Int(y * Double(plane.height))
        let minWidth = max(8, Int(ceil(Double(plane.width) * minimums.width)))
        let maxWidth = Int(floor(Double(plane.width) * 0.40))
        let minHeight = max(6, Int(ceil(Double(plane.height) * minimums.height)))
        let maxHeight = Int(floor(Double(plane.height) * 0.075))
        let local = boxes(plane, xRange: max(0, px - maxWidth)...min(plane.width - 1, px + maxWidth),
                          topRange: max(0, py - maxHeight)...max(0, py - 2),
                          minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight,
                          containing: (px, py))
        guard local.count == 1, let selected = local.first else { return false }

        // Only the known form's basic-information band is checked; surrounding browser buttons are unrelated evidence.
        // Two similarly sized dark input outlines in this band make this theme/state ambiguous.
        if x > 0.30, y > 0.20, y < 0.65 {
            let others = boxes(plane, xRange: Int(Double(plane.width) * 0.30)...min(plane.width - 1, Int(Double(plane.width) * 0.98)),
                               topRange: Int(Double(plane.height) * 0.18)...min(plane.height - 1, Int(Double(plane.height) * 0.65)),
                               minWidth: minWidth, maxWidth: maxWidth,
                               minHeight: max(minHeight, selected.height * 3 / 4), maxHeight: min(maxHeight, selected.height * 5 / 4),
                               containing: nil)
            guard !others.contains(where: { !selected.same(as: $0) }) else { return false }
        }
        return true
    }

    private static func boxes(_ p: Plane, xRange: ClosedRange<Int>, topRange: ClosedRange<Int>,
                              minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int,
                              containing point: (Int, Int)?) -> [Box] {
        guard minHeight <= maxHeight, minWidth <= maxWidth else { return [] }
        var result: [Box] = []
        for top in topRange {
            var x = xRange.lowerBound
            while x <= xRange.upperBound {
                guard p.dark(x, top) else { x += 1; continue }
                let left = x
                while x <= xRange.upperBound && p.dark(x, top) { x += 1 }
                let right = x - 1, width = right - left + 1
                guard width >= minWidth, width <= maxWidth else { continue }
                if let point, !(point.0 > left + 1 && point.0 < right - 1) { continue }
                let firstBottom = max(top + minHeight - 1, point.map { $0.1 + 2 } ?? 0)
                let lastBottom = min(p.height - 1, top + maxHeight - 1)
                guard firstBottom <= lastBottom else { continue }
                for bottom in firstBottom...lastBottom {
                    let box = Box(left: left, top: top, right: right, bottom: bottom)
                    if let point, !box.contains(point.0, point.1) { continue }
                    guard horizontal(p, left: left, right: right, y: bottom),
                          vertical(p, x: left, top: top, bottom: bottom), vertical(p, x: right, top: top, bottom: bottom),
                          brightInterior(p, box: box) else { continue }
                    if !result.contains(where: { $0.same(as: box) }) { result.append(box) }
                    if result.count > 1 { return result }
                }
            }
        }
        return result
    }

    private static func horizontal(_ p: Plane, left: Int, right: Int, y: Int) -> Bool {
        var dark = 0, run = 0, longest = 0
        for x in left...right {
            if p.dark(x, y) { dark += 1; run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let width = Double(right - left + 1)
        return Double(dark) / width >= 0.94 && Double(longest) / width >= 0.88
    }

    private static func vertical(_ p: Plane, x: Int, top: Int, bottom: Int) -> Bool {
        guard bottom - top > 4 else { return false }
        // A one-pixel antialiased corner may move the strongest vertical stroke relative to the top run.
        for column in max(0, x - 1)...min(p.width - 1, x + 1) {
            let dark = ((top + 1)..<bottom).filter { p.dark(column, $0) }.count
            if Double(dark) / Double(bottom - top - 1) >= 0.88 { return true }
        }
        return false
    }

    private static func brightInterior(_ p: Plane, box: Box) -> Bool {
        let inset = max(3, min(5, box.height / 5))
        guard box.width > inset * 2, box.height > inset * 2 else { return false }
        var light = 0, count = 0
        for y in (box.top + inset)...(box.bottom - inset) {
            for x in (box.left + inset)...(box.right - inset) { count += 1; if p.light(x, y) { light += 1 } }
        }
        return Double(light) / Double(count) >= 0.65
    }

    private static func read(_ url: URL) throws -> Plane {
        guard url.isFileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 20_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw Failure.image }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= 16_777_216 else { throw Failure.image }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.image }
        var pixels = [UInt8](repeating: 1, count: width * height)
        for i in pixels.indices {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            let luminance = (r * 2126 + g * 7152 + b * 722) / 10000
            if luminance < 130, max(r, max(g, b)) - min(r, min(g, b)) <= 35 { pixels[i] = 0 }
            else if luminance > 180 { pixels[i] = 2 }
        }
        return Plane(width: width, height: height, pixels: pixels)
    }
}
