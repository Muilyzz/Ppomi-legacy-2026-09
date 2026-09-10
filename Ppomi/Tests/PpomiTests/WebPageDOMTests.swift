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
              shownBalance:document.querySelector('#panel .disp').textContent,
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
