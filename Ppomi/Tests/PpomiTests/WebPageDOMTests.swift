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
    func testLedgerTextCannotBecomeMarkupAndVoucherButtonPreservesUID() async throws {
        let memo = "메모 <em id='injected'>태그</em> & \"인용\""
        let account = "계좌 <b id='account-markup'>A</b> & 'B'"
        let app = "앱 <i id='app-markup'>C</i>"
        let other = "가게 <u id='other-markup'>D</u>"
        let uid = "voucher\" data-surprise=\"yes' & <tag>"
        let page = Page(html: Timeline.html(ledger(account: account, app: app, other: other, memo: memo, uid: uid)))
        defer { page.dispose() }
        await fulfillment(of: [page.ready], timeout: 15)

        let result = try await page.web.evaluateJavaScript("""
            showDay(P('2026-09-02 00:00'));
            (() => {
                const row = document.querySelector('tr[data-uid]');
                return {
                    memo: row.querySelector('.transaction').textContent,
                    account: document.querySelector('#panel tbody td').textContent,
                    transfer: row.children[2].textContent,
                    uid: row.dataset.uid,
                    injectedElements: document.querySelectorAll('#injected, #account-markup, #app-markup, #other-markup').length,
                    injectedAttribute: row.hasAttribute('data-surprise'),
                    mainCount: document.querySelectorAll('main').length,
                    pressedRanges: document.querySelectorAll('#chips button[aria-pressed="true"]').length
                };
            })();
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["memo"] as? String, memo)
        XCTAssertEqual(values["account"] as? String, account + " " + app)
        XCTAssertEqual(values["transfer"] as? String, account + " → " + other)
        XCTAssertEqual(values["uid"] as? String, uid)
        XCTAssertEqual(values["injectedElements"] as? Int, 0)
        XCTAssertEqual(values["injectedAttribute"] as? Bool, false)
        XCTAssertEqual(values["mainCount"] as? Int, 1)
        XCTAssertEqual(values["pressedRanges"] as? Int, 1)

        let clicked = expectation(description: "Voucher button posts its original UID")
        page.onMessage = { message in
            guard let evidence = message["evidence"] as? String else { return }
            XCTAssertEqual(evidence, uid)
            XCTAssertEqual(message["day"] as? String, "2026-09-02")
            clicked.fulfill()
        }
        _ = try await page.web.evaluateJavaScript("document.querySelector('.transaction').click()")
        await fulfillment(of: [clicked], timeout: 5)
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
            setRange('지난 달');
            showDay(P('2026-09-02 00:00'));
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
            ({range, day:fmtFull(selDay), draft:document.getElementById('draft').value,
              scroll:document.getElementById('retained-scroll').scrollTop,
              sameNode:window.retainedNode === document.getElementById('draft')})
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["range"] as? String, "지난 달")
        XCTAssertEqual(values["day"] as? String, "2026-09-02")
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
            setRange('지난 달');
            showDay(P('2026-09-02 00:00'));
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
            ({range, day:fmtFull(selDay), scroll:window.scrollY,
              shownBalance:document.querySelector('#panel .key').textContent,
              sameDocument:window.retainedRoot === document.querySelector('main'),
              selectedRanges:document.querySelectorAll('#chips button[aria-pressed="true"]').length})
            """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["range"] as? String, "지난 달")
        XCTAssertEqual(values["day"] as? String, "2026-09-02")
        XCTAssertEqual(values["scroll"] as? Int, 173)
        XCTAssertEqual(values["shownBalance"] as? String, "2,500")
        XCTAssertEqual(values["sameDocument"] as? Bool, true)
        XCTAssertEqual(values["selectedRanges"] as? Int, 1)
    }

    /// 계좌 그룹: 칩이 렌즈마다 하나, 고른 그룹의 계좌만 순자산에 더하고, 끌어 놓기·새 그룹은 앱으로 메시지를 보낸다(앱이 없는 아이패드는 배치 구역을 숨긴다).
    func testLensChipsFilterTheSheetAndAssignmentsReachTheApp() async throws {
        UserDefaults.standard.removeObject(forKey: "timelineLens"); defer { UserDefaults.standard.removeObject(forKey: "timelineLens") }
        let day = TS.parse("2026-09-02 00:00")!
        let L = Ledger(accounts: [Account(id: "a", app: "TEST", title: "A"), Account(id: "b", app: "TEST", title: "B"), Account(id: "c", app: "TEST", title: "C")],
                       series: ["a": [Observation(ts: day, value: 1000, how: .snapshot)], "b": [Observation(ts: day.addingTimeInterval(86400), value: 500, how: .chain)]],
                       lines: [], defaultLens: Lens(name: "전부", inside: ["a", "b", "c", "현금(수중)"]), lenses: [Lens(name: "저축", inside: ["b"])])
        let page = Page(html: Timeline.html(L))
        defer { page.dispose() }
        page.web.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)   // 판이 가계부 바닥 + 실체 칸을 가지려면 열이 넓어야 한다
        page.web.uiDelegate = page.coordinator
        page.coordinator.prompt = { message, _, _ in message.contains("이름") ? " 사업 " : nil }   // prompt() 는 WKUIDelegate 가 있어야 산다
        await fulfillment(of: [page.ready], timeout: 15)
        let result = try await page.web.evaluateJavaScript("""
            (() => {
                const t = P('2026-09-03 12:00'), before = total(t).sum, chips = document.querySelectorAll('#lenses button').length;
                const cap = el => [...el.children].map(x => x.textContent.replace(/\\s+/g, ' ').trim()).join(' | ');
                const pressed = [...document.querySelectorAll('#lenses button[aria-pressed]')].map(b => b.getAttribute('aria-pressed'));
                const nowAll = {disp: document.querySelector('#now .disp').textContent, when: document.querySelector('#now .mute').textContent,
                                cards: [...document.querySelectorAll('#now .acct')].map(c => [c.dataset.account, c.querySelector('.n').textContent, c.querySelector('.meta').textContent, c.classList.contains('free')]),
                                groups: [...document.querySelectorAll('#now .grp')].map(g => [g.dataset.lens, String(g.querySelectorAll('.acct').length), g.querySelector('header .n').textContent, g.style.left.replace(/\\s/g, ''), g.style.top.replace(/\\s/g, '')]),
                                debt: document.querySelectorAll('#now .grid3 .key')[1].textContent, unseen: document.querySelector('#now p.meta').textContent,
                                disps: document.querySelectorAll('.disp').length, board: !!document.getElementById('board'), full: getComputedStyle(document.body).maxWidth,
                                charts: [...document.querySelectorAll('#charts figcaption')].map(cap), note: document.getElementById('chartsNote').textContent,
                                tiles: [...document.querySelectorAll('#charts .tile')].map(t => [t.offsetWidth > 100, t.offsetHeight > 60, t.querySelector('svg').getAttribute('viewBox') !== null]),
                                square: [...document.querySelectorAll('#charts .tile')].map(t => Math.abs(t.offsetWidth - t.offsetHeight) <= 1),
                                captions: [...document.querySelectorAll('#charts figcaption')].map(c => c.className)};
                setLens('저축');
                const nowGroup = {disp: document.querySelector('#now .disp').textContent, on: document.querySelector('#now .grp.on')?.dataset.lens, cards: document.querySelectorAll('#now .acct').length, unseen: document.querySelector('#now p.meta'),
                                  charts: [...document.querySelectorAll('#charts figcaption')].map(cap), paths: document.querySelectorAll('#charts path.area').length};
                const after = total(t).sum, on = document.querySelector('#lenses button.on').textContent;
                setLens(D.defaultLens);
                // 판 위 끌기: 포인터 이벤트로 흉내 낸다(좌표는 실제 레이아웃에서). 바뀔 때마다 판이 다시 그려지니 상자는 매번 다시 찾는다.
                const pe = (type, el, x, y) => el.dispatchEvent(new PointerEvent(type, {bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, pointerId: 1}));
                const mid = el => { const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
                const dragFrom = (el, x, y, tx, ty) => { pe('pointerdown', el, x, y); pe('pointermove', document, x + 10, y + 10); pe('pointermove', document, tx, ty); pe('pointerup', document, tx, ty); };
                const dragTo = (el, tx, ty) => dragFrom(el, ...mid(el), tx, ty);
                const G = () => document.querySelector('#now .grp[data-lens="저축"]'), board = document.getElementById('board').getBoundingClientRect(), u = unit();
                dragTo(document.querySelector('#now .acct[data-account="a"]'), ...mid(G()));                       // 판 위 노드 → 상자
                const atOnce = {head: cap(G().querySelector('header')), inBox: G().querySelectorAll('.acct').length, charts: [...document.querySelectorAll('#charts figcaption')].map(cap), note: document.getElementById('chartsNote').textContent};
                dragTo(document.querySelector('#now .acct[data-account="b"]'), board.left + 6 * u, board.bottom - 20);   // 상자 안 노드 → 가계부 바닥
                const gr = G().getBoundingClientRect();
                dragFrom(G().querySelector('header'), gr.left + 4, gr.top + 4, board.left + 4 * u + 4, board.top + 2 * u + 4);   // 상자 머리를 (4,2)로
                const moved = G().style.left.replace(/\\s/g, '') + ' ' + G().style.top.replace(/\\s/g, '');
                pe('pointerdown', G().querySelector('header'), ...mid(G().querySelector('header'))); pe('pointerup', document, ...mid(G().querySelector('header')));   // 안 움직이고 놓기 = 그 그룹만
                const pressedLens = LENS;
                // 올리면: 차트마다 세로 줄, 금액은 값 높이의 오버레이(모든 차트), 날짜는 넓은 칸 아래에만
                setLens(HOME);   // 가계부 안: 저축 a=1,000 · 미분류 b,c=500
                const bigSvg = document.querySelector('#charts .tile svg'), br = bigSvg.getBoundingClientRect();
                bigSvg.dispatchEvent(new PointerEvent('pointermove', {bubbles: true, clientX: br.left + br.width * 0.8, clientY: br.top + br.height / 2}));
                const hover = {lines: [...document.querySelectorAll('#charts .hov')].filter(h => h.style.display !== 'none').length, vals: [...document.querySelectorAll('#hoverlay .hval')].map(e => e.textContent),
                               dates: document.querySelectorAll('#hoverlay .hdate').length, border: getComputedStyle(document.getElementById('charts')).borderTopWidth, mapW: document.getElementById('charts').style.width};
                document.getElementById('charts').dispatchEvent(new PointerEvent('pointerleave'));
                const small = document.querySelector('#charts .tile:last-of-type'), before0 = [small.offsetWidth, small.offsetHeight];
                // 아주 작은 네모: 올려도 반응 없음, 눌러야 커짐
                small._small = true; small.dispatchEvent(new PointerEvent('pointerenter')); const noHover = small.classList.contains('zoom');
                small.querySelector('svg').dispatchEvent(new PointerEvent('pointermove', {bubbles: true, clientX: 0, clientY: 0})); const noVals = document.querySelectorAll('#hoverlay .hval').length;
                small.click(); const clickZoom = small.classList.contains('zoom'); small.querySelector('figcaption').click(); const clickBack = small.classList.contains('zoom'); small._small = false;
                small.dispatchEvent(new PointerEvent('pointerenter')); const zoomed = [small.classList.contains('zoom'), small.offsetWidth, small.offsetHeight, small.querySelector('svg').getAttribute('viewBox')];
                small.dispatchEvent(new PointerEvent('pointerleave')); const back = [small.classList.contains('zoom'), small.offsetWidth, small.offsetHeight];
                // 아주 작은 칸: 제목이 안 들어가면 이름만, 그마저 안 되면 제목 없음 — 올리면 다 보인다
                const tiny = document.querySelector('#charts .tile:last-of-type'); drawTile(tiny, CHARTS[CHARTS.length - 1], 80, 80); const bare = tiny.querySelector('figcaption').className;
                drawTile(tiny, CHARTS[CHARTS.length - 1], 20, 20); const hidden = tiny.querySelector('figcaption').className + '|' + getComputedStyle(tiny).overflow;
                tiny.dispatchEvent(new PointerEvent('pointerenter')); const shown = tiny.querySelector('figcaption').className; tiny.dispatchEvent(new PointerEvent('pointerleave'));
                [...document.querySelectorAll('#lenses button')].find(b => b.textContent === '+ 그룹').click();   // + 그룹: 바로 빈 상자가 선다
                const added = [...document.querySelectorAll('#now .grp')].map(g => g.dataset.lens);
                return {before, after, chips, on, pressed, nowAll, nowGroup, atOnce, moved, added, before0, zoomed, back, bare, hidden, shown, hover, noHover, noVals, clickZoom, clickBack, pressedLens, lens: LENS, native: document.getElementById('board').classList.contains('native')};
            })()
            """) as? [String: Any]
        XCTAssertEqual(result?["before"] as? Int, 1500); XCTAssertEqual(result?["after"] as? Int, 500)
        XCTAssertEqual(result?["chips"] as? Int, 5, "전부 · 가계부 · 저축 · + 그룹 · + 사업"); XCTAssertEqual(result?["on"] as? String, "저축")
        let atOnce = try XCTUnwrap(result?["atOnce"] as? [String: Any])   // 서버 왕복 전에 페이지가 먼저 그린다
        XCTAssertEqual(atOnce["head"] as? String, "저축 2계좌 | 1,500원"); XCTAssertEqual(atOnce["inBox"] as? Int, 2)
        XCTAssertEqual(atOnce["charts"] as? [String], ["가계부 3계좌 | 1,500원"], "전부 보기는 실체 단위: 가계부 하나")
        XCTAssertEqual(atOnce["note"] as? String, "")
        XCTAssertEqual(result?["moved"] as? String, "calc(var(--u)*4) calc(var(--u)*3)", "옮긴 상자도 그 자리에 바로(가계부 머리 아래 3줄부터)")
        XCTAssertEqual(result?["added"] as? [String], ["저축", "사업"], "+ 그룹은 바로 빈 상자")
        let zoomed = try XCTUnwrap(result?["zoomed"] as? [Any]), back = try XCTUnwrap(result?["back"] as? [Any]), before0 = try XCTUnwrap(result?["before0"] as? [Int])
        XCTAssertEqual(zoomed[0] as? Bool, true); XCTAssertGreaterThanOrEqual(zoomed[1] as? Int ?? 0, 290, "올리면 읽을 크기의 정사각형으로"); XCTAssertEqual(zoomed[1] as? Int, zoomed[2] as? Int, "가로세로 같음")
        XCTAssertEqual(back[0] as? Bool, false); XCTAssertEqual([back[1] as? Int, back[2] as? Int], [before0[0], before0[1]], "떠나면 제 면적으로")
        let hover = try XCTUnwrap(result?["hover"] as? [String: Any])
        XCTAssertEqual(hover["lines"] as? Int, 2); XCTAssertEqual(hover["vals"] as? [String], ["1,000원", "500원"], "금액은 모든 차트에 값 높이로"); XCTAssertEqual(hover["dates"] as? Int, 2, "날짜는 넓은 칸마다(둘 다 넓다)")
        XCTAssertEqual(hover["border"] as? String, "1px", "판 전체 테두리"); XCTAssertNotEqual(hover["mapW"] as? String, "", "판은 네모들에 딱 맞게")
        XCTAssertEqual(result?["noHover"] as? Bool, false, "너무 작은 네모는 올려도 안 커진다"); XCTAssertEqual(result?["noVals"] as? Int, 0, "작은 네모 위에선 값도 안 뜬다")
        XCTAssertEqual(result?["clickZoom"] as? Bool, true, "누르면 커진다"); XCTAssertEqual(result?["clickBack"] as? Bool, false, "머리를 다시 누르면 되돌아간다")
        XCTAssertEqual(result?["bare"] as? String, "bare", "좁으면 이름만"); XCTAssertEqual(result?["hidden"] as? String, "bare|visible", "아주 작아도 이름은 삐져나오게 겹쳐 보인다"); XCTAssertEqual(result?["shown"] as? String, "", "올리면 다 보임")
        XCTAssertEqual(result?["native"] as? Bool, true, "앱이 있으면 판 위에서 끌 수 있다"); XCTAssertEqual(result?["pressedLens"] as? String, "저축", "상자 머리를 누르면 그 그룹만"); XCTAssertEqual(result?["lens"] as? String, "가계부")
        // 지금: 본 잔액의 합, 가장 오래된 값의 나이, 계좌마다 본 때, 부채는 본 적 없음, 경계 안의 못 본 곳
        let nowAll = try XCTUnwrap(result?["nowAll"] as? [String: Any]), nowGroup = try XCTUnwrap(result?["nowGroup"] as? [String: Any])
        XCTAssertEqual(nowAll["disp"] as? String, "1,500"); XCTAssertEqual(nowAll["disps"] as? Int, 1, "페이지에 큰 숫자는 하나")
        XCTAssertTrue((nowAll["when"] as? String ?? "").hasPrefix("9/2–9/3에 본 잔액 · "), nowAll["when"] as? String ?? "")
        XCTAssertEqual(nowAll["cards"] as? [[AnyHashable]], [["b", "500원", "B · 거래 내역 · 9/3 00:00", false], ["a", "1,000원", "A · 잔액 화면 · 9/2 00:00", true], ["c", "—", "C · 본 적 없음", true]])
        XCTAssertEqual(nowAll["groups"] as? [[String]], [["저축", "1", "500원", "calc(var(--u)*1)", "calc(var(--u)*3)"]])
        XCTAssertEqual(nowAll["board"] as? Bool, true); XCTAssertEqual(nowAll["full"] as? String, "none", "판은 열 전부")
        XCTAssertEqual(nowAll["charts"] as? [String], ["가계부 3계좌 | 1,500원"], "전부 = 실체 단위(실체 없으면 가계부 하나)")
        XCTAssertEqual(nowAll["tiles"] as? [[Bool]], [[true, true, true]], "칸이 실제 크기를 갖고 선을 그린다"); XCTAssertEqual(nowAll["note"] as? String, "")
        XCTAssertEqual(nowAll["square"] as? [Bool], [true], "칸은 정사각형, 한 변 = √금액"); XCTAssertEqual(nowAll["captions"] as? [String], [""], "들어가면 제목 전부")
        XCTAssertEqual(nowAll["debt"] as? String, "본 적 없음"); XCTAssertEqual(nowAll["unseen"] as? String, "못 본 곳: 현금(수중)")
        XCTAssertEqual(nowGroup["charts"] as? [String], ["저축 1계좌 | 500원"]); XCTAssertEqual(nowGroup["paths"] as? Int, 1, "그룹을 고르면 그 차트 하나")
        XCTAssertEqual(nowGroup["disp"] as? String, "500"); XCTAssertEqual(nowGroup["on"] as? String, "저축"); XCTAssertEqual(nowGroup["cards"] as? Int, 3, "그룹을 골라도 판은 전부"); XCTAssertNil(nowGroup["unseen"] as? String)
        XCTAssertEqual(page.messages.compactMap { $0["lens"] as? String }, ["저축", "전부", "저축", "가계부"])   // 칩 · 칩 · 상자 머리 · 가계부
        XCTAssertEqual(page.messages.compactMap { $0["newLens"] as? String }, ["사업"]); XCTAssertEqual(result?["pressed"] as? [String], ["true", "false", "false"])
        let assigns = page.messages.compactMap { $0["assign"] as? [String: Any] }
        XCTAssertEqual(assigns.map { $0["account"] as? String }, ["a", "b"])
        XCTAssertEqual(assigns.map { $0["lens"] as? String }, ["저축", nil])
        XCTAssertNotNil(assigns.last?["x"] as? Int, "판 위로 뺀 노드는 자리를 갖는다"); XCTAssertNil(assigns.first?["x"], "상자에 넣으면 자리 없음")
        let moves = page.messages.compactMap { $0["moveLens"] as? [String: Any] }
        XCTAssertEqual(moves.map { $0["lens"] as? String }, ["저축"]); XCTAssertEqual(moves.first?["x"] as? Int, 4); XCTAssertEqual(moves.first?["y"] as? Int, 3); XCTAssertNil(moves.first?["kind"] as? String, "가계부 바닥에 놓았으니 그룹")
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
