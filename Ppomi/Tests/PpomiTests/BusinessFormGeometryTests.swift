import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Ppomi

final class BusinessFormGeometryTests: XCTestCase {
    private let width = 813, height = 748
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ppomi-business-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private var words: [OCR.Word] {
        [OCR.Word(x: 0.12, y: 0.12, w: 0.70, h: 0.02, text: "a https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04"),
         OCR.Word(x: 0.0435, y: 0.303, w: 0.0627, h: 0.0212, text: "사업자명"),
         OCR.Word(x: 0.4011, y: 0.3032, w: 0.1076, h: 0.0209, text: "사업자등록번호"),
         OCR.Word(x: 0.6192, y: 0.3096, w: 0.0131, h: 0.0126, text: "-")]
    }

    private func fixture(dashes: [(Int, Int)] = [(506, 235), (593, 235)], borders: Bool = true,
                         glyph: Bool = false, shade: UInt8 = 80, marks: [(Int, Int, Int, Int)] = [], antialiased: Bool = false,
                         solidThreeRowBlob: Bool = false, borderThickness: Int = 1) throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ value: UInt8) {
            for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
        }
        if borders {
            for (left, right) in [(428, 502), (514, 588), (601, 675)] {
                for offset in 0..<borderThickness {
                    let shade: UInt8 = borderThickness > 1 ? 45 : 165
                    for x in (left + offset)...(right - offset) { set(x, 221 + offset, shade); set(x, 250 - offset, shade) }
                    for y in (221 + offset)...(250 - offset) { set(left + offset, y, shade); set(right - offset, y, shade) }
                }
            }
        }
        for (left, y) in dashes {
            if antialiased || solidThreeRowBlob {
                for (dy, rowShade): (Int, UInt8) in [(0, 170), (1, 0), (2, 93)] {
                    for x in left..<(left + 7) { set(x, y + dy, solidThreeRowBlob ? 80 : rowShade) }
                }
            } else { for x in left..<(left + 5) { set(x, y, shade) } }
        }
        for (left, top, markWidth, markHeight) in marks {
            for y in top..<(top + markHeight) { for x in left..<(left + markWidth) { set(x, y, 45) } }
        }
        if glyph {
            // Connected E-like strokes contain horizontal lines but are a character, not an isolated separator.
            for y in 228...243 { set(550, y, 45) }
            for y in [228, 235, 243] { for x in 550...556 { set(x, y, 45) } }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return file
    }

    func testRestoresMissingHyphenFromActualInkAndKeepsCaptureUnchanged() throws {
        let png = try fixture(glyph: true), original = try Data(contentsOf: png)
        let result = try BusinessFormGeometry.enrich(words, png: png)
        let dashes = result.filter { $0.text == "-" }.sorted { $0.x < $1.x }
        XCTAssertEqual(dashes.count, 2)
        XCTAssertEqual(dashes[0].x, 506.0 / 813, accuracy: 0.000001)
        XCTAssertEqual(dashes[1].x, 593.0 / 813, accuracy: 0.000001)
        for segment in 1...3 {
            XCTAssertNoThrow(try ProfileFormFiller.validate(result, target: .init(field: .businessRegistrationNumber,
                              x: [0.57, 0.678, 0.786][segment - 1], y: 0.314, form: .eaisBusiness, segment: segment)))
        }
        XCTAssertEqual(try Data(contentsOf: png), original)
    }

    func testCanRestoreBothMissingHyphensButDoesNotInventEither() throws {
        let blankOCR = Array(words.dropLast())
        XCTAssertEqual(try BusinessFormGeometry.enrich(blankOCR, png: fixture()).filter { $0.text == "-" }.count, 2)
        for png in [try fixture(dashes: []), try fixture(dashes: [(506, 235)]), try fixture(dashes: [], glyph: true),
                    try fixture(shade: 230), try fixture(dashes: [(506, 260), (593, 260)])] {
            let result = try BusinessFormGeometry.enrich(words, png: png)
            XCTAssertEqual(result.count, words.count)
            XCTAssertThrowsError(try ProfileFormFiller.validate(result, target: .init(field: .businessRegistrationNumber,
                                 x: 0.57, y: 0.314, form: .eaisBusiness, segment: 1)))
        }
    }

    func testAmbiguousInkAndOCRConflictAreNotRepairedByGuessing() throws {
        let extra = try BusinessFormGeometry.enrich(words, png: fixture(dashes: [(506, 235), (593, 235), (650, 235)]))
        XCTAssertEqual(extra.count, words.count)
        var conflict = words; conflict[3].x = 0.83
        let result = try BusinessFormGeometry.enrich(conflict, png: fixture())
        XCTAssertEqual(result.count, conflict.count)
        XCTAssertEqual(result.last?.x, 0.83)
        var excessive = words
        excessive += [OCR.Word(x: 0.73, y: 0.31, w: 0.007, h: 0.006, text: "-"),
                      OCR.Word(x: 0.85, y: 0.31, w: 0.007, h: 0.006, text: "-")]
        XCTAssertEqual(try BusinessFormGeometry.enrich(excessive, png: fixture()).count, excessive.count)
    }

    func testNoPixelFallbackForOtherOriginPathOrForm() throws {
        for address in ["https://www.eais.go.kr.evil.invalid/moct/awp/aba01/AWPABA01F04",
                        "https://evil.invalid/?next=https://www.eais.go.kr/moct/awp/aba01/AWPABA01F04",
                        "https://www.eais.go.kr/moct/awp/aba01/AWPABA01F02",
                        "http://www.eais.go.kr/moct/awp/aba01/AWPABA01F04"] {
            var invalid = words; invalid[0].text = address
            XCTAssertEqual(try BusinessFormGeometry.enrich(invalid, png: fixture()).count, invalid.count)
        }
        var inPage = words; inPage[0].y = 0.55
        var separateRows = words; separateRows[1].y = 0.50
        for invalid in [inPage, separateRows, Array(words.dropFirst(2))] {
            XCTAssertEqual(try BusinessFormGeometry.enrich(invalid, png: fixture()).count, invalid.count)
        }
        let pass: [OCR.Word] = [OCR.Word(x: 0.5, y: 0.3, w: 0.2, h: 0.02, text: "본인인증 정보 입력")]
        XCTAssertEqual(try BusinessFormGeometry.enrich(pass, png: directory.appendingPathComponent("does-not-exist.png")).count, 1)
    }
    func testEmptyEvidenceRequiresActualWholeInputBorderAndEmptyInterior() throws {
        let empty = try BusinessFormGeometry.enrich(words, png: fixture())
        for segment in 1...3 {
            XCTAssertTrue(BusinessFormGeometry.hasEmptyEvidence(empty, segment: segment,
                          x: [0.57, 0.678, 0.786][segment - 1], y: 0.314))
        }
        let unbounded = try BusinessFormGeometry.enrich(words, png: fixture(borders: false))
        XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(unbounded, segment: 2, x: 0.678, y: 0.314))
        let masked = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(520, 233, 4, 4), (529, 233, 4, 4)]))
        XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(masked, segment: 2, x: 0.678, y: 0.314))
        XCTAssertTrue(BusinessFormGeometry.hasEmptyEvidence(masked, segment: 1, x: 0.57, y: 0.314))
    }

    func testOnlyLoneLeftInsertionCaretCanAccompanyEmptyEvidence() throws {
        let caret = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(519, 228, 1, 16)]))
        XCTAssertTrue(BusinessFormGeometry.hasEmptyEvidence(caret, segment: 2, x: 0.678, y: 0.314))
        let widerGlyph = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(519, 228, 3, 16)]))
        XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(widerGlyph, segment: 2, x: 0.678, y: 0.314))
        let middleMark = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(550, 228, 1, 16)]))
        XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(middleMark, segment: 2, x: 0.678, y: 0.314))
    }

    func testAntialiasedSevenByThreeDashUsesDenseHorizontalCoreWithoutAcceptingBlobs() throws {
        // Fractional display scaling gives a 7×3 outer component but only 7×2 solid ink.
        // Reproduce its public geometry, without embedding a real screen capture.
        let result = try BusinessFormGeometry.enrich(words, png: fixture(borders: false, antialiased: true))
        let dashes = result.filter { $0.text == "-" }
        XCTAssertEqual(dashes.count, 2)
        XCTAssertTrue(dashes.allSatisfy { abs($0.w - 7.0 / 813) < 0.000001 && abs($0.h - 3.0 / 748) < 0.000001 })
        let blobs = try BusinessFormGeometry.enrich(words, png: fixture(borders: false, solidThreeRowBlob: true))
        XCTAssertEqual(blobs.filter { $0.text == "-" }.count, 1)
        XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(result, segment: 1, x: 0.57, y: 0.314))
    }

    func testThickFocusBorderUsesObservedInnerEdgesAndDoesNotHideDotsOrDigits() throws {
        for thickness in [3, 4] {
            let focused = try BusinessFormGeometry.enrich(words, png: fixture(borderThickness: thickness))
            XCTAssertTrue(BusinessFormGeometry.hasEmptyEvidence(focused, segment: 2, x: 0.678, y: 0.314))
            let dotted = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(520, 233, 4, 4), (529, 233, 4, 4)],
                                                                                       borderThickness: thickness))
            XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(dotted, segment: 2, x: 0.678, y: 0.314))
            let digit = try BusinessFormGeometry.enrich(words, png: fixture(marks: [(520, 228, 3, 15)], borderThickness: thickness))
            XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(digit, segment: 2, x: 0.678, y: 0.314))
        }
    }

    func testMergedCompanyWordStillAnchorsNumberGeometryAndEmptyEvidence() throws {
        var merged = words
        merged[1].text = "사업자명 합성사업장"; merged[1].w = 0.1642
        let result = try BusinessFormGeometry.enrich(merged, png: fixture())
        XCTAssertEqual(result.filter { $0.text == "-" }.count, 2)
        for segment in 1...3 {
            XCTAssertTrue(BusinessFormGeometry.hasEmptyEvidence(result, segment: segment,
                          x: [0.57, 0.678, 0.786][segment - 1], y: 0.314))
        }
        XCTAssertEqual(result.first { $0.text == "사업자명 합성사업장" }?.w, 0.1642)
        for invalid in ["사업자명칭 합성사업장", "이전 사업자명 합성사업장", "사업자명합성사업장", "사업자명\n다른행"] {
            var changed = merged; changed[1].text = invalid
            let rejected = try BusinessFormGeometry.enrich(changed, png: fixture())
            XCTAssertEqual(rejected.filter { $0.text == "-" }.count, 1)
            XCTAssertFalse(BusinessFormGeometry.hasEmptyEvidence(rejected, segment: 2, x: 0.678, y: 0.314))
        }
    }

}
