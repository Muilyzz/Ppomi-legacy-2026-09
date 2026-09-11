import AppKit
import WebKit
import XCTest
@testable import Ppomi

@MainActor
final class WebPageDOMTests: XCTestCase {
    func testEncryptedServerReadPopulatesActualTimelineWebView() async throws {
        let id = UUID().uuidString.lowercased()
        let config = SharedRecordVault.Configuration(workspaceID: UUID().uuidString.lowercased(), deviceID: UUID().uuidString.lowercased(),
            keyID: UUID().uuidString.lowercased(), key: Data(repeating: 42, count: 32), records: ["ledger": id], sourcePath: "/unused-source")
        let archive = SharedLedgerArchive(snapshots: [.init(app: "TEST", account: "server-account", balance: 73519,
             ts: try XCTUnwrap(TS.parse("2026-09-02 10:00")))], transactions: [], me: "", originalTables: Data("{}".utf8))
        let data = try LifeJSON.encoder().encode(archive)
        let chunks = try SharedRecordCrypto.seal(data, configuration: config, recordID: id, version: 9)
        let hashes = chunks.map(SharedRecordCrypto.hash)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = SharedRecordVault(directory: directory, configuration: { config }, rpc: { method, args in
            switch method {
            case "ppomi_context": return ["workspace": ["id": config.workspaceID], "device": ["id": config.deviceID]]
            case "ppomi_record_get": return ["found": true, "record_id": id, "workspace_id": config.workspaceID,
                "writer_device_id": config.deviceID, "key_id": config.keyID, "version": 9, "chunk_ids": hashes, "updated_at": "synthetic"]
            case "ppomi_record_blob_get":
                let hash = try XCTUnwrap(args["p_hash"] as? String)
                return ["hash": hash, "data": chunks[try XCTUnwrap(hashes.firstIndex(of: hash))].base64EncodedString()]
            default: XCTFail("Presentation must never publish or read a local source"); throw SharedRecordError.invalid
            }
        })
        let server = try vault.read("ledger")
        let restored = try LifeJSON.decoder().decode(SharedLedgerArchive.self, from: server.data).ledger()
        let page = Page(html: Timeline.template, updateScript: Timeline.updateScript(restored))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)
        let rendered = try await page.web.evaluateJavaScript("D.series['server-account'][0][1]") as? Int
        XCTAssertEqual(rendered, 73519)
        XCTAssertEqual(server.version, 9)
    }
    func testLedgerTextCannotBecomeMarkupInTheMap() async throws {
        let memo = "메모 <em id='injected'>태그</em> & \"인용\""
        let account = "계좌 <b id='account-markup'>A</b> & 'B'"
        let app = "앱 <i id='app-markup'>C</i>"
        let other = "가게 <u id='other-markup'>D</u>"
        let uid = "voucher\" data-surprise=\"yes' & <tag>"
        let page = Page(html: Timeline.html(ledger(account: account, app: app, other: other, memo: memo, uid: uid)))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)

        let result = try await page.web.evaluateJavaScript("""
            (() => {
                const go = name => document.querySelector('#map .eqtile[data-name="' + CSS.escape(name) + '"]').click();
                go('자산'); go('예금');
                const leaf = document.querySelector('#map .eqtile.leaf');
                const accountName = leaf.firstChild.firstChild.textContent.trim(), accountMeta = leaf.querySelector('.meta').textContent;
                document.querySelectorAll('#crumbs button')[0].click(); go('비용');
                const expenseName = document.querySelector('#map .eqtile.leaf').firstChild.firstChild.textContent.trim();
                return {accountName, accountMeta, expenseName,
                    injectedElements: document.querySelectorAll('#injected, #account-markup, #app-markup, #other-markup').length,
                    surprise: document.querySelectorAll('[data-surprise]').length,
                    mainCount: document.querySelectorAll('main').length};
            })()
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["accountName"] as? String, account)
        XCTAssertEqual(values["accountMeta"] as? String, app)
        XCTAssertEqual(values["expenseName"] as? String, other)
        XCTAssertEqual(values["injectedElements"] as? Int, 0)
        XCTAssertEqual(values["surprise"] as? Int, 0)
        XCTAssertEqual(values["mainCount"] as? Int, 1)
    }

    func testFocusHandlesQuotesAndOnlyMainFrameCanSendMessages() async throws {
        let focus = "row-'\"\\\n\u{2028}</script>"
        let page = Page(html: """
            <!doctype html><html><body>
            <iframe srcdoc="<script>webkit.messageHandlers.ppomi.postMessage({source:'child'})</script>"></iframe>
            <script>
                function focus(value) { window.receivedFocus = value; }
                webkit.messageHandlers.ppomi.postMessage({source:'main'});
            </script>
            </body></html>
            """, focus: focus)
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)

        let received = try await page.web.evaluateJavaScript("window.receivedFocus") as? String
        XCTAssertEqual(received, focus)
        XCTAssertEqual(page.messages.compactMap { $0["source"] as? String }, ["main"])

        page.coordinator.focus = nil
        page.coordinator.apply(page.web)
        let cleared = try await page.web.evaluateJavaScript("window.receivedFocus === null") as? Bool
        XCTAssertEqual(cleared, true)
    }

    func testEvidenceAppNavigationUsesButtonsWithSelectedState() async throws {
        let title = "앱 <em id='injected'>표기</em> & 인용"
        let data: [String: Any] = ["sub": "합성 증빙", "apps": [
            ["title": "첫 앱", "account": "A", "frames": 0, "ok": 0, "bad": 0, "col": "<p>첫 증빙</p>"],
            ["title": title, "account": "B", "frames": 0, "ok": 0, "bad": 0, "col": "<p>다음 증빙</p>"]
        ]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        let page = Page(html: Web.page("evidence").replacingOccurrences(of: "/*EVIDENCE*/null", with: json))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)

        let result = try await page.web.evaluateJavaScript("""
            document.querySelectorAll('#apps button')[1].click();
            (() => ({
                selected: document.querySelector('#apps button[aria-pressed="true"]').textContent,
                selectedCount: document.querySelectorAll('#apps button[aria-pressed="true"]').length,
                column: document.querySelector('.evidence.on').textContent,
                heading: document.querySelector('#hd h2').textContent,
                hasInjectedElement: !!document.getElementById('injected')
            }))();
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["selected"] as? String, title)
        XCTAssertEqual(values["selectedCount"] as? Int, 1)
        XCTAssertEqual(values["column"] as? String, "다음 증빙")
        XCTAssertEqual(values["heading"] as? String, title + " · B")
        XCTAssertEqual(values["hasInjectedElement"] as? Bool, false)
    }

    func testRecordNavigationPreservesActualTimelineDOMAndScroll() async throws {
        let page = Page(html: Timeline.html(ledger()))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)
        let host = RecordsPageHost(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
        var creations: [AppState.Tab: Int] = [:]
        let evidence = NSView()
        let makePage: (AppState.Tab) -> NSView = { tab in
            creations[tab, default: 0] += 1
            return tab == .timeline ? page.web : evidence
        }
        host.select(.timeline, makePage: makePage)
        host.layoutSubtreeIfNeeded()
        _ = try await page.web.evaluateJavaScript("""
            document.querySelector('#map .eqtile[data-name="자산"]').click();
            const draft = document.createElement('input');
            draft.id = 'draft'; draft.value = '기록 중인 메모';
            document.body.appendChild(draft);
            const scroller = document.createElement('div');
            scroller.id = 'retained-scroll';
            scroller.style = 'height:40px;overflow:auto';
            scroller.innerHTML = '<div style="height:1000px"></div>';
            document.body.appendChild(scroller);
            scroller.scrollTop = 173;
            window.retainedNode = draft;
            true;
            """)

        host.select(.evidence, makePage: makePage)
        XCTAssertTrue(page.web.isHidden)
        XCTAssertFalse(evidence.isHidden)
        host.select(.timeline, makePage: makePage)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(creations[.timeline], 1)
        XCTAssertEqual(creations[.evidence], 1)
        XCTAssertTrue(page.web.superview === host)
        XCTAssertFalse(page.web.isHidden)
        XCTAssertTrue(evidence.isHidden)
        let result = try await page.web.evaluateJavaScript("""
            ({path:PATH.join('/'), draft:document.getElementById('draft').value,
              scroll:document.getElementById('retained-scroll').scrollTop,
              sameNode:window.retainedNode === document.getElementById('draft')})
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["path"] as? String, "차변/자산", "맵의 확대 경로가 남는다")
        XCTAssertEqual(values["draft"] as? String, "기록 중인 메모")
        XCTAssertEqual(values["scroll"] as? Int, 173)
        XCTAssertEqual(values["sameNode"] as? Bool, true)
    }

    func testCommittedLedgerUpdatePreservesTimelineDayRangeAndDocumentScroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PpomiTimelineUpdate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.db").path
        let writer = try DB(path: path, writable: true)
        try writer.insertSnapshot(ts: "2026-09-02 12:00", app: "TEST", account: "Synthetic", balance: 1000, shot: "test.png")
        let reader = LedgerChangeReader(dbPath: path, me: "Synthetic")
        let initial = try XCTUnwrap(reader.poll())
        let page = Page(html: Timeline.template, updateScript: Timeline.updateScript(initial))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)

        let initialScroll = try await page.web.evaluateJavaScript("""
            document.querySelector('#map .eqtile[data-name="자산"]').click();
            document.querySelector('#map .eqtile[data-name="예금"]').click();
            document.body.style.minHeight = '3000px';
            window.retainedRoot = document.querySelector('main');
            window.scrollTo(0, 173);
            window.scrollY;
            """) as? Int
        XCTAssertEqual(initialScroll, 173)

        try writer.insertSnapshot(ts: "2026-09-02 12:01", app: "TEST", account: "Synthetic", balance: 2500, shot: "next.png")
        let committed = try XCTUnwrap(reader.poll())
        page.coordinator.updateScript = Timeline.updateScript(committed)
        page.coordinator.apply(page.web)

        let result = try await page.web.evaluateJavaScript("""
            ({path:PATH.join('/'), scroll:window.scrollY,
              shownBalance:document.querySelector('#map .eqtile[data-name="Synthetic"] .n').textContent,
              sameDocument:window.retainedRoot === document.querySelector('main')})
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["path"] as? String, "차변/자산/예금", "확대해 둔 자리는 그대로")
        XCTAssertEqual(values["scroll"] as? Int, 173)
        XCTAssertEqual(values["shownBalance"] as? String, "2,500원")
        XCTAssertEqual(values["sameDocument"] as? Bool, true)
    }

    /// 재무 상태 트리맵: 차변(자산·비용) | 대변(부채·자본·수익)이 같은 면적, 누르면 그 칸이 맵 전부가 되어 계정과목 → 계좌로 내려간다.
    func testEquationMapZoomsFromDebitAndCreditDownToAccounts() async throws {
        let day = TS.parse("2026-09-02 00:00")!
        let L = Ledger(accounts: [Account(id: "a", app: "TEST", title: "A"), Account(id: "b", app: "TEST", title: "B"), Account(id: "c", app: "TEST", title: "C"), Account(id: "d", app: "KBBIZ", title: "KB스타기업뱅킹"), Account(id: "e", app: "TEST", title: "E")],
                       series: ["a": [Observation(ts: day, value: 1000, how: .snapshot)], "b": [Observation(ts: day, value: 500, how: .chain)], "d": [Observation(ts: day, value: 700, how: .snapshot)],
                                "e": [Observation(ts: day, value: -300, how: .snapshot)]],   // 마이너스 통장: 본 잔액이 음수 = 부채
                       lines: [JournalLine(id: "e1", ts: day.addingTimeInterval(3600), memo: "커피", dr: "유지", cr: "a", amount: 100, rev: false, inferred: false, uid: "u1"),
                               JournalLine(id: "i1", ts: day.addingTimeInterval(7200), memo: "이자", dr: "a", cr: "이자수입", amount: 30, rev: false, inferred: false, uid: "u2"),
                               JournalLine(id: "b1", ts: day.addingTimeInterval(9000), memo: "광고", dr: "광고", cr: "d", amount: 50, rev: false, inferred: false, uid: "u3"),      // 사업 계좌에서 나간 돈 = 사업 비용
                               JournalLine(id: "t1", ts: day.addingTimeInterval(9600), memo: "출자", dr: "d", cr: "a", amount: 200, rev: false, inferred: false, uid: "u4")],      // 가계 → 사업 이체: 비용도 수익도 아니다
                       defaultLens: Lens(name: "전부", inside: ["a", "b", "c", "d", "현금(수중)"]))
        let page = Page(html: Timeline.html(L))
        defer { page.dispose() }
        page.web.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        await fulfillment(of: [page.ready], timeout: 15)
        let result = try await page.web.evaluateJavaScript("""
            (() => {
                const tiles = () => [...document.querySelectorAll('#map .eqtile')].map(t => [t.dataset.name, t.querySelector('.n').textContent, String(Math.round(t.offsetWidth * t.offsetHeight))]);
                const crumbs = () => [...document.querySelectorAll('#crumbs button')].map(b => b.textContent);
                const root = tiles(), crumbs0 = crumbs(), eq = document.getElementById('eqline').textContent, halves = [...document.querySelectorAll('#map .halfname')].map(e => e.textContent);
                const rootColors = [...document.querySelectorAll('#map .eqtile')].map(t => getComputedStyle(t).backgroundColor);
                const bands = [...document.querySelectorAll('#map .eqtile')].map(t => [t.offsetLeft, t.offsetTop, t.offsetWidth, t.offsetHeight]);
                document.querySelector('#map .eqtile[data-name="자산"]').click();   // 맨 위에서 자산을 누르면 차변/자산으로
                const assets = tiles(), crumbs2 = crumbs();
                PATH = ['차변']; drawMap();   // 반쪽 자체(글자·경로엔 없지만 확대는 된다)
                const debit = tiles(), colors = [...document.querySelectorAll('#map .eqtile')].map(t => getComputedStyle(t).backgroundColor);
                document.querySelector('#map .eqtile[data-name="자산"]').click();
                document.querySelector('#map .eqtile[data-name="예금"]').click(); const deposits = tiles();
                document.querySelector('#map .eqtile[data-name="가계부"]').click(); const home = tiles(), crumbs4 = crumbs(), eqHome = document.getElementById('eqline').textContent;
                document.querySelector('#map .eqtile.leaf').click(); const stillHome = tiles().length;
                document.querySelectorAll('#crumbs button')[0].click(); const back = tiles().length;
                PATH = ['대변']; drawMap(); const credit = tiles();
                PATH = ['차변']; drawMap(); document.querySelector('#map .eqtile[data-name="비용"]').click(); const expSeg = tiles();   // 비용 › 가계부/사업자 › 용도
                document.querySelector('#map .eqtile[data-name="사업자"]').click(); const bizExp = tiles(), crumbs5 = crumbs();
                PATH = ['대변']; drawMap(); document.querySelector('#map .eqtile[data-name="자본"]').click(); const equitySeg = tiles();   // 자본도 구분마다 잔여
                PATH = ['대변']; drawMap(); document.querySelector('#map .eqtile[data-name="부채"]').click(); const debt = tiles();   // 부채 › 차입 › 가계부 › 계좌
                document.querySelector('#map .eqtile[data-name="차입"]').click(); document.querySelector('#map .eqtile[data-name="가계부"]').click(); const debtLeaf = tiles(), crumbs6 = crumbs();
                // 트리맵 토글: 끄면 같은 나무가 차분한 표로, 면적이 없던 것(부채·본 잔액 없는 계좌)도 보인다
                PATH = []; drawMap(); document.getElementById('mapToggle').click();
                const rows = () => [...document.querySelectorAll('#list tr')].map(tr => [tr.dataset.key.split('/').pop(), tr.children[1].textContent, getComputedStyle(tr.children[0]).paddingLeft]);
                const listRoot = rows(), mapHidden = document.getElementById('map').hidden, pressed = document.getElementById('mapToggle').getAttribute('aria-pressed'),
                      listTables = [...document.querySelectorAll('#list table')].map(t => t.getAttribute('aria-label') + '|' + t.querySelectorAll('tr').length), listGrid = getComputedStyle(document.getElementById('list')).display,
                      rowTints = new Set([...document.querySelectorAll('#list tr')].map(tr => getComputedStyle(tr).backgroundColor)).size, swatches = document.querySelectorAll('#list td.k, #list i').length;
                const open = key => document.querySelector('#list tr[data-key="' + CSS.escape(key) + '"]').click();
                open('차변/자산'); open('차변/자산/예금'); open('차변/자산/예금/가계부');   // 파일 탐색기처럼 그 자리에서 펼친다
                const listHome = rows(), listCrumbs = crumbs();
                open('차변/자산'); const collapsed = rows().length;   // 다시 누르면 접힌다
                open('대변/자본'); const equityRows = rows().map(r => r[0]); open('대변/자본');
                document.getElementById('mapToggle').click(); const mapBack = document.getElementById('map').hidden, tilesBack = tiles().length;
                return {root, crumbs0, eq, halves, rootColors, bands, expSeg, bizExp, crumbs5, equitySeg, equityRows, debt, debtLeaf, crumbs6, crumbs2, debit, colors, assets, deposits, home, crumbs4, eqHome, stillHome, back, credit, listRoot, mapHidden, pressed, listTables, listGrid, rowTints, swatches, listHome, listCrumbs, collapsed, mapBack, tilesBack};
            })()
            """) as? [String: Any]
        let root = try XCTUnwrap(result?["root"] as? [[String]])
        XCTAssertEqual(root.map { $0[0] }, ["자산", "비용", "부채", "자본", "수익"], "맨 위부터 다섯 갈래가 색으로")
        XCTAssertEqual(root.map { $0[1] }, ["2,200원", "150원", "300원", "2,020원", "30원"], "자산 2,200 + 비용 150 = 부채 300 + 자본 2,020 + 수익 30; 이체 200은 어디에도 없다, 음수 계좌 e 는 자산이 아니라 부채")
        let areas = root.compactMap { Int($0[2]) }; XCTAssertEqual(areas.count, 5); XCTAssertLessThan(abs(areas[0] + areas[1] - areas[2] - areas[3] - areas[4]), (areas[0] + areas[1]) / 50, "차변·대변은 같은 면적")
        XCTAssertEqual(result?["halves"] as? [String], [], "차변·대변 글자 없음: 왼쪽·오른쪽이 이미 보인다"); XCTAssertEqual(Set(try XCTUnwrap(result?["rootColors"] as? [String])).count, 5, "다섯 갈래 다섯 색")
        let bands = try XCTUnwrap(result?["bands"] as? [[Int]]); XCTAssertEqual(bands.count, 5)
        XCTAssertEqual(Set(bands.map { $0[2] }).count, 1, "맨 위의 갈래는 반쪽 너비를 다 쓰는 띠"); XCTAssertEqual(bands.map { $0[0] }, [0, 0, bands[0][2], bands[0][2], bands[0][2]], "왼쪽 반쪽에 자산·비용, 오른쪽에 부채·자본·수익")
        XCTAssertEqual(bands[1][1], bands[0][3], "비용은 자산 바로 아래"); XCTAssertEqual(bands[3][1], bands[2][3], "자본은 부채 바로 아래"); XCTAssertEqual(bands[4][1], bands[2][3] + bands[3][3], "수익은 자본 바로 아래")
        XCTAssertEqual(Double(bands[0][3]) / Double(max(1, bands[1][3])), 2200.0 / 150.0, accuracy: 0.5, "띠 높이가 금액 비(2,200 : 150)")
        XCTAssertEqual(result?["crumbs0"] as? [String], ["전부"]); XCTAssertEqual(result?["crumbs2"] as? [String], ["전부", "자산"], "경로에도 반쪽은 없다")
        XCTAssertEqual(result?["eq"] as? String, "자산 2,200원 + 비용 150원 = 부채 300원 + 자본 2,020원(자산 + 비용 − 수익 − 부채) + 수익 30원")
        XCTAssertEqual((result?["debit"] as? [[String]])?.map { [$0[0], $0[1]] }, [["자산", "2,200원"], ["비용", "150원"]])
        let colors = try XCTUnwrap(result?["colors"] as? [String]); XCTAssertEqual(Set(colors).count, 2, "자산과 비용은 다른 대표색")
        XCTAssertEqual((result?["assets"] as? [[String]])?.map { [$0[0], $0[1]] }, [["예금", "2,200원"]])
        XCTAssertEqual((result?["deposits"] as? [[String]])?.map { [$0[0], $0[1]] }, [["가계부", "1,500원"], ["사업자", "700원"]], "기업뱅킹 계좌는 사업자 아래")
        XCTAssertEqual((result?["home"] as? [[String]])?.map { [$0[0], $0[1]] }, [["a", "1,000원"], ["b", "500원"]], "본 잔액 없는 c 는 면적이 없다")
        XCTAssertEqual(result?["crumbs4"] as? [String], ["전부", "자산", "예금", "가계부"])
        XCTAssertTrue((result?["eqHome"] as? String ?? "").hasSuffix("면적 없음: c"), result?["eqHome"] as? String ?? "")
        XCTAssertEqual(result?["stillHome"] as? Int, 2, "계좌는 잎: 눌러도 그대로"); XCTAssertEqual(result?["back"] as? Int, 5, "경로의 전부를 누르면 맨 위로(다섯 갈래)")
        XCTAssertEqual((result?["credit"] as? [[String]])?.map { [$0[0], $0[1]] }, [["부채", "300원"], ["자본", "2,020원"], ["수익", "30원"]])
        XCTAssertEqual((result?["expSeg"] as? [[String]])?.map { [$0[0], $0[1]] }, [["가계부", "100원"], ["사업자", "50원"]], "비용은 반대편 계좌의 구분을 따라 가계부/사업자로")
        XCTAssertEqual((result?["bizExp"] as? [[String]])?.map { [$0[0], $0[1]] }, [["광고", "50원"]]); XCTAssertEqual(result?["crumbs5"] as? [String], ["전부", "비용", "사업자"])
        XCTAssertEqual((result?["equitySeg"] as? [[String]])?.map { [$0[0], $0[1]] }, [["가계부", "1,270원"], ["사업자", "750원"]], "구분마다 자본 = 자산 + 비용 − 수익 − 부채; 이체 200은 저장 없이 두 잔여에 들어 있다")
        XCTAssertEqual((result?["debt"] as? [[String]])?.map { [$0[0], $0[1]] }, [["차입", "300원"]]); XCTAssertEqual((result?["debtLeaf"] as? [[String]])?.map { [$0[0], $0[1]] }, [["e", "300원"]], "음수 잔액 계좌가 부채 잎으로, 양수로 표시")
        XCTAssertEqual(result?["crumbs6"] as? [String], ["전부", "부채", "차입", "가계부"])
        XCTAssertEqual(result?["equityRows"] as? [String], ["자산", "비용", "부채", "자본", "가계부", "사업자", "수익"], "표에서도 자본이 구분으로 펼쳐진다")
        XCTAssertEqual((result?["assets"] as? [[String]])?.map { $0[0] }, ["예금"])
        XCTAssertEqual((result?["listRoot"] as? [[String]])?.map { [$0[0], $0[1]] }, [["자산", "2,200원"], ["비용", "150원"], ["부채", "300원"], ["자본", "2,020원"], ["수익", "30원"]], "처음엔 접혀 있다")
        XCTAssertEqual(result?["mapHidden"] as? Bool, true); XCTAssertEqual(result?["pressed"] as? String, "false")
        XCTAssertEqual(result?["listTables"] as? [String], ["차변|2", "대변|3"], "표도 차변 | 대변 두 열"); XCTAssertEqual(result?["listGrid"] as? String, "grid")
        XCTAssertEqual(result?["rowTints"] as? Int, 5, "줄 배경이 종류마다 옅은 음영"); XCTAssertEqual(result?["swatches"] as? Int, 0, "작은 네모 없음")
        let listHome = try XCTUnwrap(result?["listHome"] as? [[String]])
        XCTAssertEqual(listHome.map { $0[0] }, ["자산", "예금", "가계부", "a", "b", "c", "사업자", "비용", "부채", "자본", "수익"], "펼친 자리에서 하위가 들여쓰기로; 이동 없음")
        XCTAssertEqual(listHome.filter { ["a", "b", "c"].contains($0[0]) }.map { $0[1] }, ["1,000원", "500원", "본 적 없음"], "표에는 본 잔액 없는 계좌도 보인다")
        XCTAssertEqual(Set(listHome.filter { ["자산", "예금", "가계부", "a"].contains($0[0]) }.map { $0[2] }).count, 4, "깊이마다 들여쓰기가 다르다")
        XCTAssertEqual(result?["listCrumbs"] as? [String], ["전부"], "표는 늘 맨 위부터"); XCTAssertEqual(result?["collapsed"] as? Int, 5, "다시 누르면 접힌다")
        XCTAssertEqual(result?["mapBack"] as? Bool, false); XCTAssertEqual(result?["tilesBack"] as? Int, 5, "다시 켜면 트리맵은 맨 위(표는 늘 맨 위부터라 경로가 없다)")
    }

    /// 부채가 자산보다 크면 자본은 음수다. 트리맵은 양수 면적만 그리므로 그 몫을 차변에 '자본잠식'으로 둔다: 자산 + 비용 + 자본잠식 = 부채 + 자본 + 수익.
    func testDeficitShowsOnTheDebitSide() async throws {
        let day = TS.parse("2026-09-02 00:00")!
        let L = Ledger(accounts: [Account(id: "a", app: "TEST", title: "A"), Account(id: "loan", app: "SHINHAN", title: "신한 슈퍼SOL")],
                       series: ["a": [Observation(ts: day, value: 100, how: .snapshot)], "loan": [Observation(ts: day, value: -500, how: .snapshot)]],
                       lines: [], defaultLens: Lens(name: "전부", inside: ["a", "loan"]))
        let page = Page(html: Timeline.html(L))
        defer { page.dispose() }
        page.web.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        await fulfillment(of: [page.ready], timeout: 15)
        let result = try await page.web.evaluateJavaScript("""
            (() => {
                const tiles = () => [...document.querySelectorAll('#map .eqtile')].map(t => [t.dataset.name, t.querySelector('.n').textContent, String(Math.round(t.offsetWidth * t.offsetHeight))]);
                const root = tiles(), eq = document.getElementById('eqline').textContent;
                document.getElementById('mapToggle').click();
                const rows = [...document.querySelectorAll('#list tr')].map(tr => [tr.dataset.key, tr.children[1].textContent]);
                document.getElementById('mapToggle').click();
                return {root, eq, rows};
            })()
            """) as? [String: Any]
        let root = try XCTUnwrap(result?["root"] as? [[String]])
        XCTAssertEqual(root.map { [$0[0], $0[1]] }, [["자산", "100원"], ["자본잠식", "400원"], ["부채", "500원"]], "자본이 음수인 만큼이 차변의 자본잠식")
        let areas = root.compactMap { Int($0[2]) }; XCTAssertEqual(areas.count, 3); XCTAssertLessThan(abs(areas[0] + areas[1] - areas[2]), areas[2] / 50, "그래서 차변·대변이 다시 같은 면적")
        XCTAssertEqual(result?["eq"] as? String, "자산 100원 + 비용 내역 없음 + 자본잠식 400원 = 부채 500원 + 자본 0원(자본잠식) + 수익 내역 없음")
        XCTAssertEqual((result?["rows"] as? [[String]])?.map { $0[0] + "=" + $0[1] }, ["차변/자산=100원", "차변/비용=내역 없음", "차변/자본잠식=400원", "대변/부채=500원", "대변/자본=자본잠식", "대변/수익=내역 없음"])
    }

    /// 절차 페이지: 계정과목표 같은 한 나무(자리 › 패키지 › 기능)에서 줄을 고르면 명세 나무(같은 앞 단계는 접힘)에 판정 ✓△✗ 가 실린다.
    func testPlaybooksPageOutlinesTheCatalogAndDrawsTheChosenSpecTree() async throws {
        let json = """
        {"schemaVersion":1,"id":"t","name":"테스트","version":"0.1.0","aliases":[],"launch":{"search":"https://example.com/","target":"browser"},"humanSteps":["로그인은 당사자"],"guide":"guide.md",
         "capabilities":[{"id":"a","title":"A","description":"","inputs":[],"steps":[{"id":"s1","title":"▶열기","kind":"open"},{"id":"s2","title":"⊙로그인","kind":"tap"},{"id":"s3","title":"📝읽기","kind":"read"}]},
                         {"id":"b","title":"B","description":"","inputs":[],"steps":[{"id":"s1","title":"▶열기","kind":"open"},{"id":"s2","title":"⊙로그인","kind":"tap"},{"id":"s3","title":"👤인증","kind":"human"}]}]}
        """
        let manifest = try JSONDecoder().decode(PlaybookManifest.self, from: Data(json.utf8))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let record = PlaybookRecord(manifest: manifest, directory: dir, guideText: "사용법 본문", iconURL: nil)
        try VerificationStore.append(StepVerification(app: "t", version: "0.1.0", capability: "a", step: "s1", outcome: "ok"), in: dir)
        try VerificationStore.append(StepVerification(app: "t", version: "0.1.0", capability: "a", step: "s3", outcome: "fail", actual: "TouchEn 설치 페이지"), in: dir)
        let entry = PlaybookEntry(record: record, footprints: [], installed: nil)
        let page = Page(html: PlaybooksPage.html([entry], categories: ["t": "공공/법무/대법원"], dir: dir))
        defer { page.dispose() }
        page.web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        await fulfillment(of: [page.ready], timeout: 15)
        let result = try await page.web.evaluateJavaScript("""
            (() => {
                try { localStorage.clear(); } catch (e) {} OPEN = {'공공': 1}; SEL = null; drawList(); drawDetail();   // 저장된 펼침 상태와 무관하게
                const rows = () => [...document.querySelectorAll('#list tr')].map(tr => tr.dataset.key + '=' + tr.children[1].textContent);
                const r0 = rows(), sum = document.getElementById('sum').textContent;
                const open = key => document.querySelector('#list tr[data-key="' + CSS.escape(key) + '"]').click();
                open('공공/법무'); open('공공/법무/대법원'); const r1 = rows();
                open('pkg:t'); const r2 = rows(), steps = document.querySelectorAll('#detail .pb-step').length, ok = document.querySelectorAll('#detail .pb-step.ok').length, fail = document.querySelectorAll('#detail .pb-step.fail').length;
                open('pkg:t/b'); const dim = document.querySelectorAll('#detail .pb-step.dim').length, sel = document.querySelector('#list tr.sel').dataset.key, human = document.querySelector('#detail details') != null;
                document.getElementById('mapToggle').click(); const tiles = document.querySelectorAll('#map [data-path]').length, listHidden = document.getElementById('list').hidden;
                return {r0, sum, r1, r2, steps, ok, fail, dim, sel, human, tiles, listHidden};
            })()
            """) as? [String: Any]
        XCTAssertEqual(result?["r0"] as? [String], ["공공=플레이북 1 · 단계 6 · ✓1 ✗1 · 미검증 4", "공공/법무=플레이북 1 · 단계 6 · ✓1 ✗1 · 미검증 4"], "맨 위 가지만 펼쳐진 계정과목표")
        XCTAssertEqual(result?["sum"] as? String, "플레이북 1 · 기능 2 · 단계 6 · ✓1 △0 ✗1 · 미검증 4")
        XCTAssertEqual((result?["r1"] as? [String])?.last, "pkg:t=기능 2 · 단계 6 · ✓1 ✗1 · 미검증 4", "기관까지 펼치면 패키지 줄")
        XCTAssertEqual((result?["r2"] as? [String])?.suffix(2).map { $0 }, ["pkg:t/a=단계 3 · ✓1 ✗1 · 미검증 1", "pkg:t/b=단계 3 · 미검증 3"], "패키지를 고르면 기능 줄이 펼쳐지고")
        XCTAssertEqual(result?["steps"] as? Int, 4, "…아래에 명세 나무: 여섯 단계 중 앞 둘이 접혀 넷"); XCTAssertEqual(result?["ok"] as? Int, 1); XCTAssertEqual(result?["fail"] as? Int, 1)
        XCTAssertEqual(result?["dim"] as? Int, 1, "기능 줄을 고르면 그 기능 밖 단계는 흐리게"); XCTAssertEqual(result?["sel"] as? String, "pkg:t/b"); XCTAssertEqual(result?["human"] as? Bool, true)
        XCTAssertGreaterThan(result?["tiles"] as? Int ?? 0, 0, "트리맵 토글: 미검증 단계 수가 면적"); XCTAssertEqual(result?["listHidden"] as? Bool, true)
    }

    private func ledger(account: String = "account", app: String = "Test", other: String = "external",
                        memo: String = "Synthetic", uid: String = "uid") -> Ledger {
        let day = TS.parse("2026-09-02 00:00")!
        return Ledger(accounts: [Account(id: account, app: "TEST", title: app)],
                      series: [account: [Observation(ts: day, value: 1000, how: .snapshot)]],
                      lines: [JournalLine(id: "line", ts: day.addingTimeInterval(3600), memo: memo, dr: other,
                                          cr: account, amount: 10, rev: false, inferred: false, uid: uid)],
                      defaultLens: Lens(name: "Synthetic", inside: [account]))
    }

    /// Exercises the production bridge in a real WebKit document without opening or focusing a window.
    @MainActor private final class Page {
        let web: WKWebView
        let coordinator = WebPage.Coordinator()
        let ready = XCTestExpectation(description: "Local page loaded")
        var messages: [[String: Any]] = []
        var onMessage: (([String: Any]) -> Void)?

        init(html: String, focus: String? = nil, updateScript: String? = nil) {
            _ = NSApplication.shared
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()   // 페이지의 localStorage(트리맵 토글 등)가 다른 실행에 새지 않게
            configuration.userContentController.add(coordinator, name: "ppomi")
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 500), configuration: configuration)
            web.navigationDelegate = coordinator
            coordinator.focus = focus
            coordinator.updateScript = updateScript
            coordinator.onReady = { [weak self] _ in self?.ready.fulfill() }
            coordinator.onMessage = { [weak self] message in
                guard let self, let message = message as? [String: Any] else { return }
                self.messages.append(message)
                self.onMessage?(message)
            }
            web.loadHTMLString(html, baseURL: nil)
        }

        func dispose() {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: "ppomi")
        }
    }
}
