import AppKit
import XCTest
@testable import Ppomi

final class RegistryExtractTests: XCTestCase {
    // 등기소 PDF 본문처럼 글자 사이 공백이 끼고, 열이 줄바꿈으로 흩어진 꼴
    let sample = """
    등기사항전부증명서(말소사항 포함) - 집합건물
    [집합건물] 서울특별시 서초구 서초동 1234 레몬프라자 제3층 제301호
    【 표 제 부 】 ( 1동의 건물의 표시 )
    표시번호 접수 소재지번,건물명칭 및 번호 건물내역
    1 2010년5월1일 서울특별시 서초구 서초동 1234 레몬프라자 철근콘크리트조 5층
    【 갑    구 】 ( 소유권에 관한 사항 )
    순위번호 등기목적 접수 등기원인 권리자 및 기타사항
    1 소유권보존 2010년5월1일 제1000호  소유자 주식회사건설 110111-1234567 서울특별시
    2 소유권이전 2019년3월5일 제12345호 2019년1월10일 매매 소유자 김용석 800101-******* 서울특별시 강남구
      거 래 가 액 금3,000,000,000원
    【 을    구 】 ( 소유권 이외의 권리에 관한 사항 )
    1 근저당권설정 2015년2월2일 제200호 2015년2월2일 설정계약 채권최고액 금120,000,000원 채무자 주식회사건설 근저당권자 주식회사국민은행
    2 1번근저당권설정등기말소 2019년3월5일 제12344호 2019년3월4일 해지
    3 근저당권설정 2019년3월5일 제12346호 2019년3월5일 설정계약 채 권 최 고 액 금4,740,000,000원 채무자 김용석 근저당권자 주식회사신한은행 110111-0012809
    """

    func testParsesOwnerPriceAndLiveMortgages() {
        let f = RegistryExtract.parse(sample)
        XCTAssertEqual(f.address, "서울특별시 서초구 서초동 1234 레몬프라자 제3층 제301호")
        XCTAssertEqual(f.owners.map(\.name), ["주*****", "김**"], "이름은 첫 글자만; 주민번호는 아예 읽지 않는다")
        XCTAssertEqual(f.owners.last?.price, 3_000_000_000); XCTAssertEqual(f.owners.last?.received, "2019-03-05"); XCTAssertEqual(f.owners.last?.cause, "매매")
        XCTAssertNil(f.owners.first?.price, "보존등기에는 거래가액이 없다")
        XCTAssertEqual(f.mortgages.map { [$0.rank, $0.maxClaim] }, [[1, 120_000_000], [3, 4_740_000_000]])
        XCTAssertEqual(f.mortgages.map(\.cancelled), [true, false], "2번 '1번근저당권설정등기말소'로 1번은 말소")
        XCTAssertEqual(f.mortgages.last?.creditor, "주식회사신한은행"); XCTAssertEqual(f.mortgages.last?.received, "2019-03-05")
    }

    func testReadsTextFromAPDFFile() throws {   // PDFKit 경로: 글자가 든 PDF 를 만들어 다시 읽는다
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800)); view.string = sample
        let data = view.dataWithPDF(inside: view.bounds)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString).pdf"); try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = RegistryExtract.parse(try RegistryExtract.text(of: url))
        XCTAssertEqual(f.owners.last?.price, 3_000_000_000); XCTAssertEqual(f.mortgages.filter { !$0.cancelled }.map(\.maxClaim), [4_740_000_000])
        let json = try RegistryExtract.read(path: url.path, password: nil)
        XCTAssertTrue(json.contains("\"max_claim\":4740000000") && json.contains("\"name\":\"김**\"") && !json.contains("800101"), json)
    }

    func testSharedOwnershipAndNoSections() {
        let f = RegistryExtract.parse("【 갑 구 】 ( 소유권에 관한 사항 )\n3 소유권이전 2020년1월2일 제5호 2019년12월1일 매매 공유자 지분 2분의 1 김용석 800101-******* 공유자 지분 2분의 1 이몽룡 790101-******* 거래가액 금900,000,000원")
        XCTAssertEqual(f.owners.map { ($0.name, $0.share ?? "") }.map { "\($0.0)/\($0.1)" }, ["김**/2분의1", "이**/2분의1"])
        XCTAssertEqual(RegistryExtract.parse("아무 내용"), RegistryExtract.Facts(address: nil, owners: [], mortgages: []))
    }
}
