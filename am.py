#!/usr/bin/env python3
"""am — personal money pipeline. stdlib only.

  am.py init                 create data/ledger.db
  am.py ingest-sms           pull card/bank SMS from Mac Messages (needs Full Disk Access) -> transactions
  am.py snapshot [APP ...]   drive iPhone Mirroring, OCR account balances -> snapshots (default: all APPS)
  am.py reparse              re-run the list parsers over the archived OCR frames (data/shots/*.jsonl); stores what is new
  am.py state                mirroring health: CONNECTED | DISCONNECTED | PAUSED
  am.py peek APP             open APP and print what OCR sees (amounts masked) to learn its layout
  am.py today                today's card spending summary (+ notification)
  am.py advise               30-day facts (categories, recurring, income, balances) -> LLM review; weekly via ADVISE_AT
  am.py sql "SELECT ..."     read-only query (for the LLM layer / debugging)
  am.py serve                stay up: Telegram long-polling commands + SMS watch + scheduled snapshots
  am.py plist                print a launchd agent that keeps `serve` running; install instructions included

env (shell or ./.env): TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (or pair once with `/start <code>` printed at startup),
     SNAPSHOT_TIMES="08:00,20:00", LOGIN_WAIT=600 (seconds one snapshot run may wait for you: login / reconnect),
     TX_DAYS=3 (how far back the transaction list is read; set 35 once to backfill a month),
     MIRROR_AT=center (where the mirroring window is put before driving it: "center" = the spot `phone kiosk` uses, or "x,y"),
     NUDGE_TIMES="09:30,18:30" (when the bot lists conversations you are putting off — one line, no nagging)
"""
import glob, json, os, re, secrets, sqlite3, subprocess, sys, threading, time, urllib.request, urllib.parse
from datetime import datetime, date, timedelta
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(os.path.join(HERE, ".env")):          # KEY=VALUE lines; shell env wins
    for line in open(os.path.join(HERE, ".env")):
        k, _, v = line.strip().partition("=")
        k = k.strip().removeprefix("export ").strip()
        if k and not k.startswith("#") and k not in os.environ:
            os.environ[k] = v.split(" #")[0].strip().strip("\"'")
DB = os.path.join(HERE, "data", "ledger.db")
SHOTS = os.path.join(HERE, "data", "shots")
PHONE = os.path.join(HERE, "phone")
CHAT_DB = os.path.expanduser("~/Library/Messages/chat.db")
LOGIN_WAIT = int(os.environ.get("LOGIN_WAIT", "600"))

# app name -> how to open it (home_label: tap the icon under this label on home page 1; else Spotlight search),
# and the OCR row that is an account. KB rows carry a (last4) token, so that alone separates them from headers.
APPS = {
    # expand: a word to tap once the app is open (KB's home collapses extras under '더보기')
    # list: a control that opens the full account list (KB: needs a live login session; the home shows one account)
    # tx/txpage/home/scroll_y: see 카카오뱅크 below. KB's list is a web view: a mouse drag selects text instead of scrolling,
    # and the wheel only moves it with the pointer over the rows (y≈0.7), not over the sticky filter bar at mid-screen.
    "KB": {"search": "kb", "title": "KB스타뱅킹", "account": r"\(\d{4}\)|\d{6}-\d{2}-\d{6}", "expand": r"^더보기", "list": r"내 계좌 전체보기",
           "tx": r"^KB국민ONE통장", "txpage": r"거래내역조회", "home": r"내 계좌 전체보기|나의 총 자산|이번 주 카드결제", "scroll_y": 0.7},
    "KBANK": {"home_label": "케이뱅크", "search": "kbank", "title": "케이뱅크", "account": r"통장|계좌|박스|입출금|적금|예금|청약"},
    # 카카오뱅크 debit card = the user's daily spending; its 입출금통장 거래내역 is the transaction source (자동로그인 needed)
    # tx: the home row to tap for the transaction list (first match); the list is read back TX_DAYS days
    # txpage: text only the transaction list has (default: 카카오 '13:06 #' rows); scroll_y: where the wheel scrolls (default mid)
    # home: text that only the home screen has — if absent after opening (app resumed on a sub-page), tap back
    "KAKAO": {"search": "kakaobank", "title": "카카오뱅크", "account": r"통장|입출금|세이프박스|적금|모임|예금", "tx": r"통장",
              "home": r"다른금융계좌|홈 혜택"},
    # Toss with 비밀번호 인증 1단계 shows every linked bank/card on its 자산 tab without a PIN — the primary source.
    # Its rows repeat other banks' accounts, so totals are reported per app, never summed across apps.
    "TOSS": {"search": "toss", "title": "토스", "account": r"통장|계좌|뱅크|은행|입출금|적금|예금|청약"},
    "KBBIZ": {"search": "KB스타기업뱅킹", "title": "KB스타기업뱅킹", "account": r"(통장|예금|적금)(\s+\d+/\d+)?$",   # 사업자로 로그인한 기업뱅킹: 홈 카드의 이름 줄이 계좌 행
              "home": r"카드매출 입금확인|어제 매출|간편홈"},
    "SHINHAN": {"search": "신한", "title": "신한 슈퍼SOL", "account": r"예금$|대출\(", "list": r"^계좌$",   # 홈의 '계좌' 제목 → 전체계좌(입출금·대출)
                "home": r"땡겨요|마이신한포인트|추천서비스", "debt": r"대출"},
    "SAMSUNG": {"search": "삼성증권", "title": "삼성증권", "account": r"^총 ?자산( 투자성과)?$", "expand": r"^자산$", "home": r"상품/연금"},   # mPOP 홈 '자산' 탭의 총 자산 한 줄
    "KAKAOPAY": {"search": "카카오페이", "title": "카카오페이", "account": r"^계좌 총 자산$", "expand": r"^증권$", "list": r"^내 계좌$"},   # 증권 탭 → 내 계좌
}

# ---------------------------------------------------------------- db
SCHEMA = """
CREATE TABLE IF NOT EXISTS transactions(
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, kind TEXT NOT NULL,      -- approval|cancel|deposit|withdrawal
  amount INTEGER NOT NULL, merchant TEXT, card TEXT, cumulative INTEGER,
  source TEXT, msg_rowid INTEGER UNIQUE, raw TEXT);
CREATE TABLE IF NOT EXISTS snapshots(
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, app TEXT NOT NULL, account TEXT, balance INTEGER NOT NULL, shot TEXT);
CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS later(                                        -- conversations being put off
  id INTEGER PRIMARY KEY, ts TEXT NOT NULL, who TEXT NOT NULL, topic TEXT, tags TEXT, done_ts TEXT);
"""

def db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = sqlite3.connect(DB)
    c.executescript(SCHEMA)
    for ddl in ("ALTER TABLE transactions ADD COLUMN status TEXT DEFAULT 'pending'",   # SMS rows are provisional
                "ALTER TABLE transactions ADD COLUMN uid TEXT",                          # app-screen rows: natural key
                "CREATE UNIQUE INDEX IF NOT EXISTS ux_tx_uid ON transactions(uid)"):
        try:
            c.execute(ddl)
        except sqlite3.OperationalError:
            pass
    return c

def get_state(c, key, default=None):
    row = c.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
    return row[0] if row else default

def set_state(c, key, value):
    c.execute("INSERT OR REPLACE INTO state VALUES(?,?)", (key, str(value))); c.commit()

# ---------------------------------------------------------------- sms parsing
AMOUNT = re.compile(r"(-?)(\d[\d,]{0,14})\s*원")            # first char must be a digit: ', 원하시는' is not money
CUM = re.compile(r"(?:누적|잔액)\s*(-?)(\d[\d,]{0,14})\s*원")
DATE = re.compile(r"(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})")
NOISE = re.compile(r"\(광고\)|수신거부|이벤트|캐시백|예정|거절|실패|한도초과")
CARD_KINDS = [("승인취소", "cancel"), ("취소", "cancel"), ("승인", "approval")]
BANK_KINDS = [("출금", "withdrawal"), ("입금", "deposit")]

def money(m):
    return int(m.group(1) + m.group(2).replace(",", ""))

def parse_sms(text, when):
    """Tolerant parser for Korean card/bank alert SMS. Returns dict or None.
    Formats differ per issuer, so we key off tokens (금액원, 승인/취소/입금/출금, MM/DD HH:MM) instead of full templates."""
    if NOISE.search(text):
        return None
    t = re.sub(r"\[[^\]]*발신\]", "", text)
    lines = [l.strip() for l in re.split(r"[\r\n]+", t) if l.strip()]
    if not lines:
        return None
    flat = " ".join(lines)
    cum = CUM.search(flat)
    amounts = [(m.start(2), money(m)) for m in AMOUNT.finditer(flat) if not cum or m.start(2) != cum.start(2)]
    if not amounts:
        return None                                   # foreign-currency approvals (USD 12.34) land here on purpose
    amount = amounts[0][1]
    # kind: decided from the header up to the transaction amount, bank vs card vocab (a bank deposit whose memo
    # says '신한카드취소' must stay a deposit; '출금계좌 1234' in a deposit memo must not flip it to withdrawal)
    scope = flat[: amounts[0][0]] or flat
    kinds = BANK_KINDS if re.search(r"은행|뱅크", lines[0]) else CARD_KINDS
    kind = next((v for k, v in kinds if k in scope), None) or next((v for k, v in kinds if k in flat), None)
    if not kind:
        return None
    ts = when
    m = DATE.search(flat)
    if m:
        mo, d, h, mi = map(int, m.groups())
        y = when.year - (1 if (mo, d) > (when.month, when.day) else 0)  # 12/31 alert read on 01/01
        ts = datetime(y, mo, d, h, mi)
    card = re.search(r"([가-힣A-Za-z]{1,6}카드)", flat)
    last4 = re.search(r"\((\d{4})\)|(\d\*\d\*)", flat)
    merchant = None
    for l in lines[1:]:                               # line 0 is the issuer header
        if AMOUNT.search(l) or DATE.search(l) or "*" in l:  # money, time, masked customer name
            continue
        if re.search(r"승인|취소|입금|출금|누적|잔액|일시불|\d+개월|^USD|^JPY|^EUR", l) or re.fullmatch(r"[가-힣A-Za-z]{1,6}카드(\(\d{4}\))?", l):
            continue                                  # keywords, or a bare card name line; '카드결제' as a memo is fine
        merchant = l; break
    if not merchant and m:                            # single-line formats: merchant follows the time
        tail = re.split(r"누적|잔액", flat[m.end():])[0]
        tail = re.sub(r"-?\d[\d,]*\s*원|\(?일시불\)?|\d+개월|\([^)]*\)", " ", tail)
        merchant = " ".join(tail.split()) or None
    return {"ts": ts.strftime("%Y-%m-%d %H:%M"), "kind": kind, "amount": amount, "merchant": merchant,
            "card": (card.group(1) + (f"({last4.group(1) or last4.group(2)})" if last4 else "")) if card else None,
            "cumulative": money(cum) if cum else None}

def decode_attributed_body(blob):
    """macOS 13+ stores message text in a typedstream blob when `text` is NULL."""
    if not blob:
        return None
    i = blob.find(b"NSString")
    if i < 0:
        return None
    i += 8 + 5  # skip 'NSString' + \x01\x94\x84\x01\x2b
    if i >= len(blob):
        return None
    n = blob[i]
    if n == 0x81:
        n = int.from_bytes(blob[i + 1:i + 3], "little"); i += 3
    elif n == 0x82:
        n = int.from_bytes(blob[i + 1:i + 5], "little"); i += 5
    else:
        i += 1
    return blob[i:i + n].decode("utf-8", "ignore")

def ingest_sms(quiet=False):
    """Pull new SMS from Messages into transactions. Returns the newly inserted rows (for notifications),
    or None when chat.db is unreadable (no Full Disk Access)."""
    c = db()
    last = int(get_state(c, "sms_rowid", 0))
    try:
        src = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
        rows = src.execute("""SELECT m.ROWID, m.date/1000000000 + 978307200, m.text, m.attributedBody, h.id
                              FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
                              WHERE m.ROWID > ? AND m.is_from_me = 0 ORDER BY m.ROWID""", (last,)).fetchall()
    except sqlite3.OperationalError as e:
        if quiet:
            return None
        sys.exit(f"cannot read {CHAT_DB}: {e}\n-> 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한 에서 이 앱(터미널/Claude)을 켜세요")
    new = []
    for rowid, epoch, text, body, sender in rows:
        if sender and "@" in sender:                  # iMessage from a person, not an SMS short code
            continue
        text = text or decode_attributed_body(body)
        if not text:
            continue
        try:
            p = parse_sms(text, datetime.fromtimestamp(epoch))
        except Exception as e:                        # one weird message must not stall ingestion forever
            print(f"parse error rowid={rowid}: {e}", file=sys.stderr); continue
        if not p:
            continue
        if c.execute("INSERT OR IGNORE INTO transactions(ts,kind,amount,merchant,card,cumulative,source,msg_rowid,raw) VALUES(?,?,?,?,?,?,?,?,?)",
                     (p["ts"], p["kind"], p["amount"], p["merchant"], p["card"], p["cumulative"], f"sms:{sender}", rowid, text)).rowcount:
            new.append(p)
    if rows:
        set_state(c, "sms_rowid", rows[-1][0])
    c.commit()
    if not quiet:
        print(f"scanned {len(rows)} messages, {len(new)} transactions")
    return new

def watch_sms(c):
    """serve tick: if Messages' database changed since last tick, ingest and announce new card events (~30s latency)."""
    if not os.path.exists(CHAT_DB):
        return
    mtime = str(os.path.getmtime(CHAT_DB))
    if mtime == get_state(c, "sms_mtime"):
        return
    set_state(c, "sms_mtime", mtime)
    new = ingest_sms(quiet=True)
    if new is None:
        if not get_state(c, "sms_warned"):
            set_state(c, "sms_warned", 1)
            notify("문자 수집 비활성", "전체 디스크 접근 권한을 켜면 카드 문자를 실시간 수집합니다")
        return
    for p in new:
        if p["kind"] in ("approval", "cancel"):
            sign = "-" if p["kind"] == "cancel" else ""
            notify("💳 결제" if p["kind"] == "approval" else "↩︎ 취소", f"{esc(p['merchant'] or '')} <b>{sign}{p['amount']:,}원</b> · " + today_text().splitlines()[-1])

# ---------------------------------------------------------------- phone driving
def phone(*args, check=True):
    if not os.path.exists(PHONE) or os.path.getmtime(PHONE) < os.path.getmtime(PHONE + ".swift"):
        subprocess.run(["swiftc", "-O", PHONE + ".swift", "-o", PHONE], check=True)
    r = subprocess.run([PHONE, *args], capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"phone {args[0]}: {r.stderr.strip()}")
    return r.stdout

def screen():
    """Capture the mirroring window and OCR it. Returns (png_path, [word dicts])."""
    os.makedirs(SHOTS, exist_ok=True)
    for f in os.listdir(SHOTS):                       # ponytail: keep a week of screenshots for debugging, no more
        if f.endswith(".png") and os.path.getmtime(os.path.join(SHOTS, f)) < time.time() - 7 * 86400:
            os.remove(os.path.join(SHOTS, f))
    png = os.path.join(SHOTS, datetime.now().strftime("%Y%m%d-%H%M%S") + ".png")
    phone("capture", png)
    ocr = phone("ocr", png)
    with open(png[:-4] + ".jsonl", "w") as f:         # the raw exposure, kept for good (~1% of the PNG): a better parser can rerun old runs
        f.write(ocr)
    words = [json.loads(l) for l in ocr.splitlines() if l.strip()]
    return png, words

def find(words, pattern):
    return next((w for w in words if re.search(pattern, w["text"])), None)

def tap(word):
    phone("tap", str(word["x"] + word["w"] / 2), str(word["y"] + word["h"] / 2))

def state():
    """Print mirroring state: CONNECTED | DISCONNECTED | PAUSED | IN_USE | NONE. Read from the mirroring window's accessibility
    tree (no capture); `phone watch` streams the same as events."""
    print(phone("state").strip())

# mirroring app's own overlays, matched as whole OCR lines so app text like '잠금' or 'iPhone' can't trip it
OVERLAY = r"^(연결이 (중단됨|일시 정지됨)|iPhone(을| ).*(사용 중|잠금 해제).*)$"
LOGIN = r"패턴|비밀번호|인증서|간편인증|Face ID|로그인(?! 연장| 시간)"   # '로그인 연장' is a session popup, not a login wall
EXTEND = r"^로그인 연장$"                                                 # KB: idle-timeout popup; tapping keeps the human's session
RUN = {"deadline": None, "asked": False}             # one snapshot run shares a single wait budget (LOGIN_WAIT)

def deadline_passed():
    return RUN["deadline"] is not None and time.time() > RUN["deadline"]

def ensure_connected(tries=4):
    """Mirroring drops often ('연결이 중단됨' -> 다시 시도) or pauses when idle ('연결이 일시 정지됨' -> 재개); click through.
    An empty OCR result is the grey 'connecting' frame, not a success. Returns (words, reconnected)."""
    png, reconnected = None, False
    while True:
        png, words = screen()
        button = find(words, r"^(다시 시도|재개)$")
        if button:
            tap(button); reconnected = True
        elif words and (find(words, LOGIN) or not find(words, OVERLAY)):
            return words, reconnected
        tries -= 1
        if tries <= 0 and not RUN["asked"]:           # phone in use / away: tell the human once, then keep trying
            RUN["asked"] = True
            notify("미러링 끊김", "아이폰을 잠그고 Mac 옆에 두면 이어서 수집합니다")
        if tries <= 0 and deadline_passed():
            sys.exit(f"mirroring not ready — is the iPhone locked, nearby, recently unlocked, not in use? see {png}")
        time.sleep(7 if tries > 0 else 15)

def open_app(cfg, retry=True):
    """Bring an app to the front of the mirrored phone. Returns False (no exception) when it can't, so a run
    continues with the next app. A mirroring drop mid-way is reconnected and the open retried once."""
    def dropped(words):
        return bool(find(words, r"^(다시 시도|재개)$")) or not words
    phone("key", "home"); time.sleep(1)
    if "home_label" in cfg:
        for _ in range(2):                            # a second Home press returns to page 1
            _, words = screen()
            label = find(words, "^" + re.escape(cfg["home_label"]) + "$")
            if label:
                phone("tap", str(label["x"] + label["w"] / 2), str(label["y"] - 0.045))  # the icon sits above its label
                time.sleep(7)
                return True
            phone("key", "home"); time.sleep(1)
    if not cfg.get("search"):
        print(f"{cfg['title']}: home icon not found and no Spotlight search term"); return False
    phone("key", "spotlight"); time.sleep(1.2)
    phone("type", cfg["search"]); time.sleep(2)
    png, words = screen()
    hit = find(words, re.escape(cfg["title"]))
    if not hit and dropped(words) and retry:           # connection fell over while we were typing
        ensure_connected()
        return open_app(cfg, retry=False)
    if not hit:                      # never press Return blindly: it opens whatever Spotlight suggests (e.g. Messages)
        phone("key", "escape"); phone("key", "home")
        print(f"Spotlight did not show {cfg['title']} for '{cfg['search']}' -> see {png}"); return False
    # Vision often returns the three top-hit labels as ONE observation, so its center is the wrong icon.
    # Return opens the top hit, and the search field literally says '<title> — 열기' when that is the case.
    # Spotlight's field autocompletes the top hit ("kakaotalk — 카카오톡" / "kb스타뱅킹 — 열기"): Return opens it.
    field = next((w for w in words if w["y"] > 0.85 and cfg["title"].lower() in w["text"].lower()), None)
    if field:
        phone("key", "return")
    else:
        header = find(words, r"연관성 높은 항목")
        if header and 0 < hit["y"] - header["y"] < 0.1:  # top-hit grid: the icon sits above the label
            phone("tap", str(hit["x"] + min(hit["w"], 0.25) / 2), str(hit["y"] - 0.06))
        else:                                            # '앱' list row: icon to the left, the whole row is tappable
            tap(hit)
    time.sleep(7)
    return to_home(cfg)

def to_home(cfg):
    """iOS resumes an app where it was left; if this app isn't on its home screen, tap the top-left back control."""
    if not cfg.get("home"):
        return True
    for _ in range(3):
        _, words = screen()
        if find(words, cfg["home"]) or find(words, LOGIN):
            return True
        # the back chevron in the nav bar: OCR sees it as a lone '^' / '<' glyph near the top-left
        nav = [w for w in words if 0.09 < w["y"] < 0.17]
        chevron = next((w for w in nav if re.fullmatch(r"[\^<〈←‹]", w["text"].strip())), None) or (min(nav, key=lambda w: w["x"]) if nav else None)
        if not chevron:
            break
        tap(chevron); time.sleep(2)
    return True

def expand(cfg, words):
    """Tap the app's 'show more' control if configured and visible; return the refreshed (png, words)."""
    more = cfg.get("expand") and find(words, cfg["expand"])
    if not more:
        return None
    tap(more); time.sleep(1.5)
    return screen()

def drill(cfg, words):
    """Open the app's full account list if configured and visible. Returns (png, words) of that page, or None
    (control absent, or it bounced to a login screen — then the caller keeps the home-screen results)."""
    ctl = cfg.get("list") and find(words, cfg["list"])
    if not ctl:
        return None
    tap(ctl); time.sleep(3)
    png, words = screen()
    return None if find(words, LOGIN) else (png, words)

def keep_session(words):
    """If the app is asking whether to extend the idle session, say yes; return refreshed (png, words) or None."""
    btn = find(words, EXTEND)
    if not btn:
        return None
    tap(btn); time.sleep(1.5)
    return screen()

# Popups we close, and the only buttons we are allowed to press for each. Money-moving suggestions
# ('복사한 계좌로 이체할까요?') are closed with X/닫기/아니요 only — never 확인/이체.
POPUPS = [(r"이체할까요", r"^[X×x]$|^닫기$|^아니요$"), (r"로그아웃 되었습니다", r"^확인$|^[X×x]$")]

def dismiss(words):
    """Close a known popup with its safe button; return refreshed (png, words) or None if nothing to do."""
    for text, buttons in POPUPS:
        if find(words, text):
            btn = next((w for w in words if re.fullmatch(buttons, w["text"].strip())), None)
            if btn:
                tap(btn); time.sleep(1.5)
                return screen()
    return None

def read_balances(cfg):
    """Home screen (expanded) first; the full list page wins when it yields more accounts."""
    png, words = screen()
    png, words = dismiss(words) or (png, words)
    png, words = keep_session(words) or (png, words)
    png, words = expand(cfg, words) or (png, words)
    found = parse_balances(words, cfg["account"])
    deep = drill(cfg, words)
    if deep:
        more = parse_balances(deep[1], cfg["account"])
        if len(more) >= len(found):
            png, words, found = deep[0], deep[1], more
    return png, words, found

def row_groups(words, tol=0.012):
    """Group OCR words into visual rows by y-center (ponytail: plain clustering, no layout model). [(cy, [words])]."""
    rows = []
    for w in sorted(words, key=lambda w: w["y"] + w["h"] / 2):
        cy = w["y"] + w["h"] / 2
        if rows and abs(rows[-1][0] - cy) < tol:
            rows[-1][1].append(w)
        else:
            rows.append([cy, [w]])
    return rows

def rows_from(words, tol=0.012):
    return [" ".join(x["text"] for x in sorted(ws, key=lambda w: w["x"])) for _, ws in row_groups(words, tol)]

BALANCE = re.compile(r"(?<![\d,])(-?)(\d{1,3}(?:,\d{3})+|\d+)\s*원")
NOT_BALANCE = r"누적|총 ?자산|총 ?잔액|이벤트|혜택|수수료|배달비|출시|\d+개 계좌|모두 ?보기|전체보기|내역|송금|적립금|만료|다시 연결|예금 • 적금"

def parse_balances(words, account_re):
    """(account label, balance) pairs. The balance is the N원 on the account row itself, else within the next 4 rows
    (KB's full list puts 신규일/만기일 lines between a savings account and its balance). Stops at the next account row
    and never reuses a balance row, so wrapped names / headers can't double-count. When the account row is just a
    number (name on the row above, as in KB's 전체계좌조회), the name row becomes the label."""
    rows = rows_from(words)
    out, used = [], set()
    for i, r in enumerate(rows):
        if not re.search(account_re, r) or re.search(NOT_BALANCE, r):
            continue
        for j in range(i, min(i + 5, len(rows))):
            if j in used or (j > i and re.search(account_re, rows[j])):
                break
            m = BALANCE.search(rows[j])
            if m and not re.search(NOT_BALANCE, rows[j]):
                label = r if re.search(r"[가-힣]{2,}", r) or i == 0 else rows[i - 1] + " " + r
                label = re.sub(r"\(\d{4}\)", "(****)", label)
                label = re.sub(r"\d[\d-]{6,}\d", lambda a: "…" + a.group(0)[-4:], label)   # full account numbers: keep last 4
                label = re.sub(r"-?\d[\d,]*\s*원|이체|:", " ", label)
                label = re.sub(r"(?<=[\d)])\s+[A-Za-z](?=\s|$)|\s+[A-Za-z]$", "", label)   # OCR noise letters after numbers / at end
                label = label.replace("|", "I")                                              # 'A|' -> 'AI' (OCR)
                label = re.sub(r"\b([A-Za-z]) (?=[A-Za-z]\b)", r"\1", label)                # 'A I' -> 'AI' (split by OCR)
                label = " ".join(label.split())
                label = re.sub(r"^[^\w가-힣(]+|[\s*•·]+$", "", label)   # chevrons/bullets in front, hidden-balance '*' at the end
                out.append((label, money(m))); used.add(j)
                break
    return out

# ---------------------------------------------------------------- transactions from an app's list screen
# 카카오뱅크 layout: a date header (MM.DD), then per transaction two rows: "<merchant> -12,000원" and
# "HH:MM #체크카드 518,574원" (time, type tag, balance after). Deposits carry no sign and, for transfers in, no tag.
TX_DATE = re.compile(r"^(\d{1,2})\.(\d{1,2})(?![\d,])")            # '09.02', also with trailing OCR noise
TX_AMT = re.compile(r"^(.+?)\s+([+\-–—~]?)\s?(\d[\d,]*)\s*원$")   # deposits carry no sign (blue in the app); OCR reads '-' as '~' at times
TX_META = re.compile(r"^(\d{1,2}):(\d{2})\s+(?:#?\s*(.+?)\s+)?(-?\d[\d,]*)\s*원$")   # tag may have spaces / a split '#', or be absent (transfers in)
TX_DAYS = int(os.environ.get("TX_DAYS", "3"))          # daily runs: 3; one-off backfill: TX_DAYS=35 am.py snapshot KAKAO

PAGE = "\x00page"                                  # separates scrolled pages in the row list handed to the parsers

def parse_transactions(rows, when, app):
    """Rows must be the concatenation of every page read so far (newest first), pages separated by PAGE: the date
    header for a page's first transactions is on an earlier page, and a merchant/time row pair can straddle a boundary."""
    out, cur, prev, pending = [], None, None, None
    for j, r in enumerate(rows):
        if r == PAGE:
            # a page opens with the rows that sat just above its first date header on the previous page (the pages overlap).
            # If that header is the one already current, those rows are newer than it: use the date before it.
            nxt = next((x for x in rows[j + 1:] if x == PAGE or TX_DATE.match(x)), None)
            m = nxt and nxt != PAGE and TX_DATE.match(nxt)
            if m and cur and (int(m.group(1)), int(m.group(2))) == cur[1:]:
                cur = prev
            pending = None
            continue
        m = TX_DATE.match(r)
        if m:
            mo, d = int(m.group(1)), int(m.group(2))
            prev, cur = cur, (when.year - (1 if (mo, d) > (when.month, when.day) else 0), mo, d); pending = None
            continue
        m = TX_META.match(r)                          # checked first: an unsigned balance row also looks like an amount row
        if m:
            if pending and cur:
                merchant, sign, amount, j0 = pending
                tag, balance = (m.group(3) or "").strip(), int(m.group(4).replace(",", ""))
                ts = datetime(*cur, int(m.group(1)), int(m.group(2))).strftime("%Y-%m-%d %H:%M")
                # natural key from numbers only — OCR of the merchant text drifts between captures, digits don't;
                # two same-minute same-amount purchases still differ by the balance after each
                out.append({"ts": ts, "kind": tx_kind(sign, tag, merchant), "amount": amount, "merchant": merchant, "card": tag.lstrip("#"),
                            "cumulative": balance, "uid": f"{app}:{ts}:{sign}{amount}:{balance}", "rows": (j0, j)})
            pending = None
            continue
        m = TX_AMT.match(r)
        if m and cur:
            pending = (m.group(1).strip(), "+" if m.group(2) in ("", "+") else "-", int(m.group(3).replace(",", "")), j); continue
        pending = None                                # any other row breaks a merchant/time pair
    return out

def tx_kind(sign, tag, merchant):
    """'+' is a deposit, or a refund when 취소 appears; '-' is card spend when the tag says 체크카드, else an account withdrawal
    ('-' rows with 취소 in the name are spend)."""
    if sign == "+":
        return "cancel" if "취소" in tag or "취소" in merchant else "deposit"
    return "approval" if "체크카드" in tag else "withdrawal"

# KB스타뱅킹 거래내역조회 layout: a month header (YYYY.MM), then per transaction four consecutive rows:
# "MM.DD HH:MM:SS | 타입", "<상대/적요>", "-100,000원" ('+' for deposits), "518,574원" (balance after).
# The four must be consecutive: a page boundary cutting through a transaction drops it there; the next page has it whole.
KB_MONTH = re.compile(r"^(\d{4})\.(\d{2})(?![\d,.])")                # '2026.08', not the range line '2026.06.04 ~'
KB_TX = re.compile(r"^(\d{1,2})\.(\d{1,2})\s+(\d{1,2}):(\d{2}):\d{2}\s*[|Il1]?\s*(.*)$")   # OCR reads '|' as I/l/1
KB_WON = re.compile(r"^([+\-–—~]?)\s?(\d[\d,]*)\s*원$")      # OCR reads '-' as '~' at times

def parse_kb_transactions(rows, when, app):
    out, year, i = [], None, 0
    while i < len(rows):
        m = KB_MONTH.match(rows[i])
        if m:
            year = int(m.group(1)); i += 1; continue
        m = KB_TX.match(rows[i])
        if not m or i + 3 >= len(rows):
            i += 1; continue
        amt, bal = KB_WON.match(rows[i + 2]), KB_WON.match(rows[i + 3])
        if not amt or not bal or KB_WON.match(rows[i + 1]):     # four-row shape broken (page boundary, wrapped memo)
            i += 1; continue
        mo, d, h, mi = map(int, m.groups()[:4])
        y = year or when.year - (1 if (mo, d) > (when.month, when.day) else 0)
        tag, merchant = m.group(5).strip(), rows[i + 1].strip()
        # ponytail: a '-' lost by OCR reads as a withdrawal; the balance column could confirm the sign, add if it ever bites
        sign, amount, balance = "+" if amt.group(1) == "+" else "-", int(amt.group(2).replace(",", "")), int(bal.group(2).replace(",", ""))
        ts = datetime(y, mo, d, h, mi).strftime("%Y-%m-%d %H:%M")
        out.append({"ts": ts, "kind": tx_kind(sign, tag, merchant), "amount": amount, "merchant": merchant, "card": tag,
                    "cumulative": balance, "uid": f"{app}:{ts}:{sign}{amount}:{balance}", "rows": (i, i + 3)})
        i += 4
    return out

PARSERS = {"KB": parse_kb_transactions}                    # default: parse_transactions (카카오뱅크)
LIST_MARKERS = {"KAKAO": TX_META, "KB": KB_TX}             # a row pattern only that app's transaction list has (>= 2 rows)

def reparse():
    """Re-run the list parsers over every archived OCR frame (data/shots/*.jsonl) and store what is new.
    The raw frames outlive the parser: fix a regex, run this, and the ledger catches up without touching the phone."""
    c, new, runs, frames = db(), 0, 0, []
    for j in sorted(glob.glob(os.path.join(SHOTS, "*.jsonl"))):
        rows = rows_from([json.loads(l) for l in open(j) if l.strip()])
        when = datetime.strptime(os.path.basename(j)[:15], "%Y%m%d-%H%M%S")
        for name, marker in LIST_MARKERS.items():
            if sum(bool(marker.match(r)) for r in rows) >= 2:
                frames.append((when, name, rows))
    run = []                                           # consecutive frames of one app under 2 minutes apart = one scrolling run
    for f in frames + [None]:
        if run and (f is None or f[1] != run[-1][1] or (f[0] - run[-1][0]).total_seconds() > 120):
            name, when = run[0][1], run[-1][0]
            for t in PARSERS.get(name, parse_transactions)(sum(([PAGE] + r for _, _, r in run), []), when, name):
                new += c.execute("""INSERT OR IGNORE INTO transactions(ts,kind,amount,merchant,card,cumulative,source,uid,status)
                                    VALUES(?,?,?,?,?,?,?,?,'confirmed')""",
                                 (t["ts"], t["kind"], t["amount"], t["merchant"], t["card"], t["cumulative"], f"app:{name}", t["uid"])).rowcount
            runs += 1; run = []
        if f:
            run.append(f)
    c.commit()
    print(f"{len(frames)} list frames in {runs} runs, {new} new transactions")

def tx_uid(app, ts, kind, amount, balance):
    return f"{app}:{ts}:{'+' if kind in ('deposit', 'cancel') else '-'}{amount}:{balance}"

def read_transactions(cfg, name, c):
    """From the app's home: tap the account row, then read the list page by page (scrolling ~half a window so
    pages overlap) back TX_DAYS days. Rows accumulate across pages before parsing (see parse_transactions).
    Returns the number of new rows stored."""
    _, words = screen()
    words = (dismiss(words) or (None, words))[1]
    if not find(words, cfg.get("txpage", r"^\d{1,2}:\d{2}\s+#")):   # not already on a transaction list
        # the account row on the home; never the nav title (y<0.2) and never a row that is a bare number. Tap its name end:
        # a tap on the account number copies it and the app then offers a transfer
        row = next((w for w in words if re.search(cfg["tx"], w["text"]) and w["y"] > 0.2 and not re.match(r"\W*\d", w["text"])), None)
        if not row:
            print(f"{name}: no account row for transactions"); return 0
        phone("tap", str(row["x"] + min(row["w"], 0.2) / 2), str(row["y"] + row["h"] / 2)); time.sleep(3)
        _, words = screen()
        words = (dismiss(words) or (None, words))[1]
    cutoff = (date.today() - timedelta(days=TX_DAYS)).isoformat()
    step = -int(int(phone("window").split()[4]) * 0.5)
    rows_all, prev, seen, new = [], None, set(), 0
    for page in range(120):                       # bounded by cutoff / end of list; 120 ≈ a busy month at half-window scrolls
        _, words = screen()
        rows = rows_from(words)
        if rows == prev:                              # scroll didn't move anything: end of the list
            break
        prev = rows
        rows_all += [PAGE] + rows
        found = PARSERS.get(name, parse_transactions)(rows_all, datetime.now(), name)
        for t in found:
            if t["uid"] in seen:
                continue
            seen.add(t["uid"])
            new += c.execute("""INSERT OR IGNORE INTO transactions(ts,kind,amount,merchant,card,cumulative,source,uid,status)
                                VALUES(?,?,?,?,?,?,?,?,'confirmed')""",
                             (t["ts"], t["kind"], t["amount"], t["merchant"], t["card"], t["cumulative"], f"app:{name}", t["uid"])).rowcount
        c.commit()
        if found and min(t["ts"] for t in found) < cutoff:
            break
        phone("scroll", str(step), "0.5", str(cfg.get("scroll_y", 0.5)))
    print(f"{name}: {len(seen)} transactions seen, {new} new")
    return new

def with_phone(fn):
    """Common wrapper: Stage Manager pulls the mirror on stage; give the user their app back afterwards."""
    prev = phone("front").strip()
    phone("place", *os.environ.get("MIRROR_AT", "center").split(","))   # the same spot the kiosk uses; MIRROR_AT=40,60 to dodge a floating panel
    RUN["deadline"], RUN["asked"] = time.time() + LOGIN_WAIT, False
    try:
        fn()
    finally:
        phone("key", "home", check=False)  # never leave a banking app open in the mirror
        if prev and prev != "com.apple.ScreenContinuity":
            phone("activate", prev, check=False)

def peek(name):
    """Open an app and print what OCR sees (amounts masked) — for discovering an app's layout before wiring it up."""
    if name not in APPS:
        sys.exit(f"unknown app {name}; known: {sorted(APPS)}")
    def go():
        ensure_connected()
        if not open_app(APPS[name]):
            return
        png, words, found = read_balances(APPS[name])
        print(f"[{name}] {os.path.basename(png)}  login_screen={bool(find(words, LOGIN))}  accounts={len(found)}")
        for r in rows_from(words):
            print("  " + re.sub(r"\d{1,3}(?:,\d{3})+\s*원", "***,***원", re.sub(r"\(\d{4}\)", "(****)", r)))
    with_phone(go)

def snapshot(apps):
    bad = set(apps) - APPS.keys() - API_APPS.keys()
    if bad:
        sys.exit(f"unknown app(s) {sorted(bad)}; known: {sorted(APPS) + sorted(API_APPS)}")
    if "TOSSINVEST" in apps:                          # API source: no phone needed
        try:
            tossinvest()
        except RuntimeError as e:
            print(f"TOSSINVEST: {e}")
    apps = [a for a in apps if a in APPS]
    if not apps:
        return
    c = db()
    def go():
        for name in apps:
            cfg = APPS[name]
            try:
                words, _ = ensure_connected()
                if not open_app(cfg):
                    continue
                words, reconnected = ensure_connected()
                if reconnected and not open_app(cfg):  # the phone came back on its home screen, not in our app
                    continue
                png, words, found = read_balances(cfg)
                if not found and find(words, LOGIN):
                    # Credentials stay with the human. Easiest: unlock the phone, open the app, Face ID, lock it again.
                    # Mirroring reconnects to the home screen, so we re-open the app and read while the session lives.
                    notify(f"🔐 {esc(cfg['title'])} 로그인 필요",
                           f"폰에서 {esc(cfg['title'])}을 열어 Face ID로 로그인한 뒤 다시 잠가 주세요 ({LOGIN_WAIT // 60}분 안에). "
                           "미러링 창에서 직접 로그인해도 됩니다.")
                    print(f"{name}: login screen — waiting for you to log in", flush=True)
                    while not found and not deadline_passed():
                        time.sleep(10)
                        words, reconnected = ensure_connected()
                        if reconnected or not find(words, LOGIN) and not parse_balances(words, cfg["account"]):
                            if not open_app(cfg):     # phone came back on its home screen: bring the app up again
                                continue
                            png, words, found = read_balances(cfg)
                        else:
                            found = parse_balances(words, cfg["account"])
                if not found:
                    print(f"{name}: no balance found (login not done? popup?) -> see {png}")
                    continue
                for acct, bal in found:
                    c.execute("INSERT INTO snapshots(ts,app,account,balance,shot) VALUES(?,?,?,?,?)",
                              (datetime.now().strftime("%Y-%m-%d %H:%M"), name, acct, bal, os.path.basename(png)))
                    print(f"{name}: {acct} = {bal:,}원")
                c.commit()
                if cfg.get("tx"):
                    if cfg.get("list"):               # we may be on the full-list page; go back to the home first
                        open_app(cfg)
                    read_transactions(cfg, name, c)
            except SystemExit as e:                   # one app's failure (phone helper, timeout) must not kill the run
                print(f"{name}: {e}")
                if deadline_passed():
                    break
    with_phone(go)

# ---------------------------------------------------------------- 토스증권 Open API (no screen needed)
# Keys: tossinvest.com (WTS) 설정 > Open API → client_id/secret; register this Mac's public IP in 허용 IP 관리 (else 403).
TOSS_API = "https://openapi.tossinvest.com"
API_APPS = {"TOSSINVEST": "토스증권(API)"}

def title(app):
    return APPS.get(app, {}).get("title") or API_APPS.get(app, app)

def toss_call(path, token=None, account=None, form=None):
    headers = {"Content-Type": "application/x-www-form-urlencoded"} if form is not None else {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if account is not None:
        headers["X-Tossinvest-Account"] = str(account)
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(TOSS_API + path, data, headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"tossinvest {path} {e.code}: {e.read().decode()[:200]}")

def toss_token(c):
    cid, sec = os.environ.get("TOSSINVEST_CLIENT_ID", ""), os.environ.get("TOSSINVEST_CLIENT_SECRET", "")
    if not (cid and sec):
        return None
    if float(get_state(c, "toss_token_exp", 0)) > time.time() + 60:
        return get_state(c, "toss_token")
    d = toss_call("/oauth2/token", form={"grant_type": "client_credentials", "client_id": cid, "client_secret": sec})
    set_state(c, "toss_token", d["access_token"]); set_state(c, "toss_token_exp", time.time() + int(d.get("expires_in", 3600)))
    return d["access_token"]

def parse_holdings(result, usd_krw):
    """HoldingsOverview -> (total market value in KRW, [item dicts]). Amounts are strings per currency."""
    mv = result.get("marketValue", {}).get("amount", {}) or {}
    total = float(mv.get("krw") or 0) + float(mv.get("usd") or 0) * usd_krw
    items = []
    for it in result.get("items", []):
        fx = 1.0 if it.get("currency") == "KRW" else usd_krw
        items.append({"symbol": it["symbol"], "name": it["name"], "country": it.get("marketCountry"), "currency": it.get("currency"),
                      "quantity": float(it["quantity"]), "last_price": float(it["lastPrice"]), "avg_price": float(it["averagePurchasePrice"]),
                      "market_value_krw": round(float(it["marketValue"]["amount"]) * fx),
                      "pnl_krw": round(float(it["profitLoss"]["amount"]) * fx), "pnl_rate": float(it["profitLoss"]["rate"])})
    rate = result.get("profitLoss", {}).get("rate")
    return round(total), items, float(rate) if rate is not None else None

def usd_krw_rate(token):
    """Best effort: the API's exchange-rate endpoint; falls back to 1400 (flagged) so USD holdings still show up."""
    try:
        d = toss_call("/api/v1/exchange-rate", token)
        r = d.get("result", d)
        for k in ("rate", "exchangeRate", "usdKrw", "price", "basePrice"):
            if isinstance(r, dict) and r.get(k):
                return float(r[k]), True
        if isinstance(r, list) and r and isinstance(r[0], dict):
            for k in ("rate", "exchangeRate", "price", "basePrice"):
                if r[0].get(k):
                    return float(r[0][k]), True
    except Exception as e:
        print(f"exchange-rate: {e}", file=sys.stderr)
    return 1400.0, False

def tossinvest():
    """Collect 토스증권 holdings via the official API into snapshots (total) + holdings (per symbol). Returns rows stored."""
    c = db()
    c.executescript("""CREATE TABLE IF NOT EXISTS holdings(id INTEGER PRIMARY KEY, ts TEXT, app TEXT, account TEXT, symbol TEXT, name TEXT,
        country TEXT, currency TEXT, quantity REAL, last_price REAL, avg_price REAL, market_value_krw INTEGER, pnl_krw INTEGER, pnl_rate REAL);""")
    token = toss_token(c)
    if not token:
        print("TOSSINVEST: no credentials (.env TOSSINVEST_CLIENT_ID/SECRET)"); return 0
    accounts = toss_call("/api/v1/accounts", token).get("result", [])
    fx, fx_ok = usd_krw_rate(token)
    ts, n = datetime.now().strftime("%Y-%m-%d %H:%M"), 0
    shot = f"api-{ts}"
    for a in accounts:
        if a.get("accountType") not in (None, "BROKERAGE"):
            continue
        time.sleep(1.1)                                   # account group: 1 request/second
        res = toss_call("/api/v1/holdings", token, account=a["accountSeq"]).get("result", {})
        total, items, rate = parse_holdings(res, fx)
        label = f"토스증권 …{str(a.get('accountNo', ''))[-4:]}" + ("" if fx_ok else " (USD 환율 추정)")
        c.execute("INSERT INTO snapshots(ts,app,account,balance,shot) VALUES(?,?,?,?,?)", (ts, "TOSSINVEST", label, total, shot))
        for it in items:
            c.execute("""INSERT INTO holdings(ts,app,account,symbol,name,country,currency,quantity,last_price,avg_price,market_value_krw,pnl_krw,pnl_rate)
                         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""", (ts, "TOSSINVEST", label, it["symbol"], it["name"], it["country"], it["currency"],
                                                                 it["quantity"], it["last_price"], it["avg_price"], it["market_value_krw"], it["pnl_krw"], it["pnl_rate"]))
        n += 1 + len(items)
        print(f"TOSSINVEST: {label} = {total:,}원, {len(items)} holdings" + (f", 손익률 {rate:+.1%}" if rate is not None else ""))
    c.commit()
    return n

def holdings_summary(c):
    """Latest run per securities account: total, PnL rate, top positions with weights — for the advice JSON."""
    c.executescript("CREATE TABLE IF NOT EXISTS holdings(id INTEGER PRIMARY KEY, ts TEXT, app TEXT, account TEXT, symbol TEXT, name TEXT, country TEXT, currency TEXT, quantity REAL, last_price REAL, avg_price REAL, market_value_krw INTEGER, pnl_krw INTEGER, pnl_rate REAL);")
    out = []
    for (acct,) in c.execute("SELECT DISTINCT account FROM holdings"):
        ts = c.execute("SELECT MAX(ts) FROM holdings WHERE account=?", (acct,)).fetchone()[0]
        rows = c.execute("SELECT name, country, market_value_krw, pnl_krw, pnl_rate FROM holdings WHERE account=? AND ts=? ORDER BY market_value_krw DESC", (acct, ts)).fetchall()
        total = sum(r[2] for r in rows) or 1
        out.append({"계좌": acct, "시각": ts, "평가금액": sum(r[2] for r in rows), "손익": sum(r[3] for r in rows),
                    "종목수": len(rows), "국내/해외 비중": {"KR": round(sum(r[2] for r in rows if r[1] == "KR") / total, 2), "US": round(sum(r[2] for r in rows if r[1] == "US") / total, 2)},
                    "상위 종목": [{"종목": n, "비중": round(mv / total, 2), "손익률": pr} for n, _, mv, _, pr in rows[:6]]})
    return out

# ---------------------------------------------------------------- telegram + notifications
TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
if TOKEN and not re.fullmatch(r"\d+:[A-Za-z0-9_-]{30,}", TOKEN):   # .env placeholder / typo -> behave as unset
    print("TELEGRAM_BOT_TOKEN doesn't look like a bot token; running without Telegram", file=sys.stderr)
    TOKEN = None

def tg(method, **params):
    """Telegram Bot API call (stdlib). Long-poll friendly. Returns the 'result' payload or None on failure."""
    if "text" in params:
        params["text"] = params["text"][:4000]
    data = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}).encode()
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{TOKEN}/{method}", data, timeout=40) as r:
            return json.load(r).get("result")
    except Exception as e:
        print(f"telegram {method}: {e}", file=sys.stderr); return None

# --- rich output: Telegram HTML parse mode. Every user-derived string goes through esc(); amounts sit in spoilers
# so a glance at the phone doesn't reveal balances. Buttons appear only at the phone-collection permission gate.
def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def won(n, hide=False):
    s = f"<b>{n:,}원</b>"
    return f"<tg-spoiler>{s}</tg-spoiler>" if hide else s

def plain(html):
    """Strip our own tags for macOS notifications / terminal output."""
    return re.sub(r"<[^>]+>", "", html).replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

COMMANDS = json.dumps([{"command": "today", "description": "오늘 카드 지출"}, {"command": "balance", "description": "최근 잔액 (탭해서 보기)"},
                       {"command": "advise", "description": "재무 리뷰 (관찰·질문·선택지)"},
                       {"command": "apps", "description": "연결된 앱과 수집 현황"}, {"command": "snapshot", "description": "지금 잔액 수집 (앱 이름 선택)"},
                       {"command": "peek", "description": "앱 화면 OCR 결과 보기"}, {"command": "sql", "description": "읽기 전용 SQL"},
                       {"command": "later", "description": "미루는 대화 적어두기: 상대 요지 #태그"}, {"command": "list", "description": "미루고 있는 대화 목록"},
                       {"command": "done", "description": "보냈음: 상대 또는 번호"}, {"command": "draft", "description": "내 말투 초안 3개: 상대 요지"},
                       {"command": "pattern", "description": "누구·무엇을 오래 미루는지"}, {"command": "help", "description": "명령 목록"}])

def send(cid, html, reply_markup=None):
    """Rich text (bold / spoilers / monospace). Buttons only when the model asked for them this turn."""
    return tg("sendMessage", chat_id=cid, text=html, parse_mode="HTML", reply_markup=reply_markup)

def chat_id():
    return os.environ.get("TELEGRAM_CHAT_ID") or get_state(db(), "chat_id")

def notify(title, body):
    """Bot message when Telegram is configured, macOS notification otherwise. `body` may contain our HTML."""
    if TOKEN and chat_id():
        send(chat_id(), f"<b>{esc(title)}</b>\n{body}")
    else:  # pass strings as argv, never spliced into AppleScript source
        subprocess.run(["osascript", "-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
                        "-e", "end run", plain(body)[:200], title])

# ---------------------------------------------------------------- reporting
def today_text():
    """HTML. One line per card event, bold total; ends with the 'N건 M원' line other code reuses."""
    c = db()
    d = date.today().isoformat()
    if not c.execute("SELECT 1 FROM transactions LIMIT 1").fetchone():
        return "거래 소스가 아직 연결되지 않았어요 (앱 거래내역 읽기 또는 카드 문자 수집 필요)"
    spent, n = c.execute("""SELECT COALESCE(SUM(CASE kind WHEN 'approval' THEN amount ELSE -amount END),0), SUM(kind='approval')
                            FROM transactions WHERE ts LIKE ? AND kind IN ('approval','cancel')""", (d + "%",)).fetchone()
    lines = [f"{t} · {esc(m or '')} · {'↩︎ -' if k == 'cancel' else ''}{a:,}원" for t, k, a, m in
             c.execute("SELECT substr(ts,12), kind, amount, merchant FROM transactions WHERE ts LIKE ? AND kind IN ('approval','cancel') ORDER BY ts", (d + "%",))]
    return "\n".join([f"📅 <b>{d[5:].replace('-', '/')} 지출</b>"] + lines + [f"오늘 {n or 0}건 {won(spent)}"])

def balance_text():
    """HTML. Latest run per app (rows of one run share a shot file), amounts under spoilers.
    Subtotals per app only: Toss re-lists other banks, so a grand total would double count."""
    rows = db().execute("""SELECT app, account, balance, ts FROM snapshots s
                           WHERE shot = (SELECT shot FROM snapshots WHERE app = s.app ORDER BY id DESC LIMIT 1)
                           ORDER BY app, id""").fetchall()
    if not rows:
        return "스냅샷 없음"
    out, sub, seen = [], {}, set()
    for app, acct, bal, ts in rows:
        if app not in seen:
            seen.add(app); out.append(f"\n{'📈' if app in API_APPS else '💰'} <b>{esc(title(app))}</b> <i>{esc(ts[5:])}</i>")
        out.append(f"{esc(acct)} · {won(bal, hide=True)}"); sub[app] = sub.get(app, 0) + bal
    out += [""] + [f"{esc(title(app))} 소계 {won(v, hide=True)}" for app, v in sub.items()]
    return "\n".join(out).strip()

def sql_text(q):
    """HTML: a monospace block so columns line up."""
    if not re.match(r"\s*(SELECT|WITH|EXPLAIN|PRAGMA table_info)\b", q, re.I):
        return "read-only: SELECT/WITH/EXPLAIN only"
    try:
        cur = sqlite3.connect(f"file:{DB}?mode=ro", uri=True).execute(q)
        out = ["\t".join(d[0] for d in cur.description or [])]
        out += ["\t".join("" if v is None else str(v) for v in row) for row in cur.fetchmany(50)]
        return "<pre>" + esc("\n".join(out)) + "</pre>"
    except sqlite3.Error as e:
        return f"sql error: {esc(e)}"

def apps_text():
    """A monospace table. Korean (variable width in mono fonts) goes in the last column so the others stay aligned."""
    c = db()
    rows = [f"{'APP':<10} {'ACCT':>4} {'RUNS':>4}  {'LAST':<11}  NAME"]
    for name in list(APPS) + list(API_APPS):
        last, runs = c.execute("SELECT MAX(ts), COUNT(DISTINCT shot) FROM snapshots WHERE app=?", (name,)).fetchone()
        accts = c.execute("SELECT COUNT(*) FROM snapshots WHERE app=? AND shot=(SELECT shot FROM snapshots WHERE app=? ORDER BY id DESC LIMIT 1)",
                          (name, name)).fetchone()[0]
        rows.append(f"{name:<10} {accts:>4} {runs:>4}  {(last or '-')[5:16]:<11}  {title(name)}")
    return "🔗 <b>연결된 앱</b>\n<pre>" + esc("\n".join(rows)) + "</pre>\n<i>ACCT = 최근 수집에서 읽은 계좌 수, RUNS = 수집 횟수</i>"

def today():
    msg = today_text(); print(plain(msg)); notify("오늘 지출", msg.splitlines()[-1])

def sql(q):
    print(plain(sql_text(q)))

# ---------------------------------------------------------------- 미루는 대화 (never sends anything; lowers the first step)
def later_add(text):
    who, _, rest = text.strip().partition(" ")
    if not who:
        return "/later 상대 요지 #태그  예) /later 김영희 회비 답장 #돈"
    tags = " ".join(sorted(re.findall(r"#\S+", rest)))
    topic = re.sub(r"#\S+", "", rest).strip()
    db().execute("INSERT INTO later(ts,who,topic,tags) VALUES(?,?,?,?)", (datetime.now().strftime("%Y-%m-%d %H:%M"), who, topic, tags)).connection.commit()
    return f"적어뒀어요: <b>{esc(who)}</b> {esc(topic)} {esc(tags)}\n요지가 정리되면 /draft {esc(who)} 요지 로 초안 만들어드릴게요."

def later_open():
    return db().execute("SELECT id, ts, who, topic, tags FROM later WHERE done_ts IS NULL ORDER BY ts").fetchall()

def days_since(ts):
    return (datetime.now() - datetime.strptime(ts, "%Y-%m-%d %H:%M")).days

def later_list():
    rows = later_open()
    if not rows:
        return "미루고 있는 대화 없음 👍"
    return "⏳ <b>미루고 있는 대화</b>\n" + "\n".join(
        f"{i}. <b>{esc(who)}</b> {esc(topic)} {esc(tags)} · {days_since(ts)}일째" for i, ts, who, topic, tags in rows)

def later_done(arg):
    c = db()
    row = c.execute("SELECT id, who FROM later WHERE done_ts IS NULL AND (CAST(id AS TEXT)=? OR who=?) ORDER BY ts LIMIT 1",
                    (arg.strip(), arg.strip())).fetchone()
    if not row:
        return "해당 항목이 없어요. /list 로 번호나 이름을 확인해 주세요."
    c.execute("UPDATE later SET done_ts=? WHERE id=?", (datetime.now().strftime("%Y-%m-%d %H:%M"), row[0])); c.commit()
    return f"✅ <b>{esc(row[1])}</b> 보냈네요. 잘했어요."

def later_pattern():
    """What kinds of conversations wait longest — the observation that turns '왜 이럴까' into '이럴 때 이렇구나'."""
    rows = db().execute("SELECT ts, who, tags, done_ts FROM later").fetchall()
    if not rows:
        return "아직 기록이 없어요. /later 로 미루는 대화를 적어두면 패턴이 보이기 시작합니다."
    def wait(ts, done):
        end = datetime.strptime(done, "%Y-%m-%d %H:%M") if done else datetime.now()
        return (end - datetime.strptime(ts, "%Y-%m-%d %H:%M")).total_seconds() / 86400
    by = {}
    for ts, who, tags, done in rows:
        for key in [who] + (tags.split() if tags else []):
            by.setdefault(key, []).append(wait(ts, done))
    lines = [f"{esc(k)}: 평균 {sum(v) / len(v):.1f}일 ({len(v)}건)" for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1]) / len(kv[1]))]
    done_n = sum(1 for r in rows if r[3])
    return f"📈 <b>미룬 대화 패턴</b> (총 {len(rows)}건, 보낸 것 {done_n})\n" + "\n".join(lines[:12])

def draft_text(arg):
    who, _, brief = arg.strip().partition(" ")
    if not brief:
        return "/draft 상대 요지  예) /draft 김영희 회비는 내가 낼게"
    if not os.path.exists(os.path.join(HERE, "data", "style_profile.json")):
        return "아직 말투 프로필이 없어요. 터미널에서: python3 style.py screen 김영희 && python3 style.py profile"
    r = subprocess.run([sys.executable, os.path.join(HERE, "style.py"), "draft", brief, "--to", who], capture_output=True, text=True, timeout=180)
    return "✍️ <b>초안</b> (보내지 않음, 복사해서 쓰세요)\n<pre>" + esc((r.stdout + r.stderr).strip()) + "</pre>"

def nudge(c):
    """Once per slot per day: one gentle line listing what's waiting and the smallest next step."""
    now = datetime.now()
    for t in [t for t in os.environ.get("NUDGE_TIMES", "09:30,18:30").split(",") if t.strip()]:
        key, mark = f"nudged:{t.strip()}", now.strftime("%Y-%m-%d")
        if now.strftime("%H:%M") >= t.strip() and get_state(c, key) != mark:
            set_state(c, key, mark)
            rows = later_open()
            if rows:
                items = " · ".join(f"{esc(who)} {esc(topic)} ({days_since(ts)}일)" for _, ts, who, topic, _ in rows[:4])
                notify("⏳ 미루고 있는 답장", f"{items}\n요지만 써주면 /draft 로 첫 문장 만들어드릴게요.")

# ---------------------------------------------------------------- advice: facts first, then an LLM reads them
# Rules categorize the common merchants; unknown ones go to the LLM once and are cached in merchant_cat.
CATEGORY_RULES = [
    (r"커피|카페|스타벅스|이디야|투썸|메가|컴포즈|빽다방|폴바셋|블루보틀", "카페"),
    (r"쿠팡이츠|배민|배달의민족|요기요|땡겨요", "배달"),
    (r"AWS|Amazon_AWS|CURSOR|VERCEL|OPENAI|ANTHROPIC|GITHUB|APPLE|NETFLIX|YOUTUBE|SPOTIFY|NOTION|GOOGLE|MICROSOFT|ADOBE|CLAUDE|SUPABASE|CLOUDFLARE", "구독/도구"),
    (r"쿠팡|마트|이마트|홈플러스|롯데마트|코스트코|다이소|편의점|GS25|CU|세븐일레븐|이마트24|올리브영", "생활/마트"),
    (r"택시|카카오T|버스|지하철|주유|충전|EV|하이패스|주차|SRT|KTX|코레일", "교통/차"),
    (r"병원|약국|의원|치과|한의원", "의료"),
    (r"식당|김밥|국밥|치킨|피자|버거|맥도날드|롯데리아|버거킹|서브웨이|분식|초밥|고기|포차|주점|호프", "식비"),
    (r"통신|SKT|KT|LG U|유플러스|전기|가스|수도|관리비|보험|생명|화재|카드대금|카드결제", "고정비"),
    (r"이체|송금", "이체"),
]

def categorize(c):
    """Fill merchant_cat for merchants seen in transactions: rules first, one LLM call for the rest."""
    c.executescript("CREATE TABLE IF NOT EXISTS merchant_cat(merchant TEXT PRIMARY KEY, category TEXT, source TEXT);")
    unknown = [m for (m,) in c.execute("SELECT DISTINCT merchant FROM transactions WHERE merchant IS NOT NULL AND merchant NOT IN (SELECT merchant FROM merchant_cat)")]
    todo = []
    for m in unknown:
        cat = next((cat for pat, cat in CATEGORY_RULES if re.search(pat, m, re.I)), None)
        if cat:
            c.execute("INSERT OR REPLACE INTO merchant_cat VALUES(?,?,'rule')", (m, cat))
        else:
            todo.append(m)
    if todo:
        try:
            import llm
            text, _ = llm.complete("가맹점명 목록을 아래 카테고리 중 하나로 분류해 JSON 객체({가맹점: 카테고리})만 출력. 카테고리: 카페, 배달, 식비, 생활/마트, 구독/도구, 교통/차, 의료, 고정비, 이체, 쇼핑, 여가, 기타",
                                   json.dumps(todo[:200], ensure_ascii=False), model=os.environ.get("OPENAI_MODEL_FAST"), max_tokens=1500)
            mapping = json.loads(re.search(r"\{.*\}", text, re.S).group(0))
            for m in todo:
                c.execute("INSERT OR REPLACE INTO merchant_cat VALUES(?,?,'llm')", (m, mapping.get(m, "기타")))
        except Exception as e:                       # no key / bad output: leave them 기타 for now, retry next time
            print(f"categorize: {e}", file=sys.stderr)
            for m in todo:
                c.execute("INSERT OR IGNORE INTO merchant_cat VALUES(?,?,'pending')", (m, "기타"))
            c.execute("DELETE FROM merchant_cat WHERE source='pending'") if False else None
    c.commit()

def summary(c, days=30):
    """Numbers the advice is built on. Spend = approvals - cancels; card/debit spend and account withdrawals kept apart."""
    categorize(c)
    since = (date.today() - timedelta(days=days)).isoformat()
    prev = (date.today() - timedelta(days=2 * days)).isoformat()
    q = lambda sql, *a: c.execute(sql, a).fetchall()
    spend = lambda a, b: q("""SELECT COALESCE(SUM(CASE kind WHEN 'approval' THEN amount WHEN 'cancel' THEN -amount END),0)
                              FROM transactions WHERE ts>=? AND ts<? AND kind IN ('approval','cancel')""", a, b)[0][0]
    by_cat = q("""SELECT COALESCE(mc.category,'기타') cat, SUM(CASE t.kind WHEN 'approval' THEN amount ELSE -amount END) won, COUNT(*) n
                  FROM transactions t LEFT JOIN merchant_cat mc ON mc.merchant=t.merchant
                  WHERE t.ts>=? AND t.kind IN ('approval','cancel') GROUP BY cat ORDER BY won DESC""", since)
    top = q("""SELECT merchant, SUM(amount) won, COUNT(*) n FROM transactions WHERE ts>=? AND kind='approval'
               GROUP BY merchant ORDER BY won DESC LIMIT 10""", since)
    recurring = q("""SELECT merchant, COUNT(DISTINCT substr(ts,1,7)) months, ROUND(AVG(amount)) avg_won FROM transactions
                     WHERE kind='approval' GROUP BY merchant HAVING months>=2 ORDER BY avg_won DESC LIMIT 15""")
    income = q("SELECT COALESCE(SUM(amount),0), COUNT(*) FROM transactions WHERE ts>=? AND kind='deposit'", since)[0]
    withdrawals = q("SELECT COALESCE(SUM(amount),0), COUNT(*) FROM transactions WHERE ts>=? AND kind='withdrawal'", since)[0]
    balances = q("""SELECT app, account, balance, ts FROM snapshots s
                    WHERE shot = (SELECT shot FROM snapshots WHERE app = s.app ORDER BY id DESC LIMIT 1) ORDER BY app, id""")
    first_tx = q("SELECT MIN(ts) FROM transactions")[0][0]
    return {
        "기간": f"최근 {days}일 ({since} ~ {date.today().isoformat()})", "데이터 시작": first_tx,
        "카드/체크카드 지출": spend(since, "9999"), "직전 같은 기간 지출": spend(prev, since),
        "카테고리별": [{"카테고리": cat, "금액": won, "건수": n} for cat, won, n in by_cat],
        "상위 가맹점": [{"가맹점": m, "금액": w, "건수": n} for m, w, n in top],
        "반복 결제(2개월 이상)": [{"가맹점": m, "개월": mo, "평균": a} for m, mo, a in recurring],
        "입금": {"금액": income[0], "건수": income[1]}, "계좌 출금(이체·자동이체 등)": {"금액": withdrawals[0], "건수": withdrawals[1]},
        "잔액(앱별 최근)": [{"앱": title(app), "계좌": acct, "잔액": bal, "시각": ts} for app, acct, bal, ts in balances],
        "증권(토스증권 API)": holdings_summary(c) or "미연결 (.env에 TOSSINVEST 키 필요)",
        "증권(삼성증권·카카오페이증권)": "토스 자산 탭 연결 후 수집 예정",
    }

ADVISE_SYSTEM = """너는 한 사람의 개인 재무 데이터를 읽고 관찰을 정리하는 조력자다. 자문업자가 아니다.
원칙: (1) 숫자는 주어진 데이터에서만, 계산은 보여준다. (2) 특정 종목·상품의 매수·매도·갈아타기 같은 개인 맞춤 투자 권고는 하지 않는다. 대신 사실(집중도, 비상금 개월수, 구독 증가, 수입 대비 지출)을 짚고 '확인해볼 질문'과 '선택지(장단점)'를 준다. (3) 데이터 기간이 짧으면(30일 미만) 그 한계를 먼저 말한다. (4) 비난하지 않는다. 짧고 구체적으로.
출력 형식(텔레그램, 일반 텍스트, 마크다운 금지, 각 항목 1~2줄):
📊 한눈에 — 지출 합계, 전 기간 대비, 가장 큰 카테고리
🔎 눈에 띄는 것 — 최대 3개 (숫자 포함)
🧭 부족한 것 / 확인할 것 — 최대 3개, 질문 형태 포함
✅ 이번 주 할 수 있는 작은 것 — 1개
데이터 한계 — 1줄"""

def advise_text():
    c = db()
    s = summary(c)
    if not c.execute("SELECT 1 FROM transactions LIMIT 1").fetchone():
        return "아직 거래 데이터가 없어요. 수집이 며칠 쌓이면 /advise 가 의미 있어집니다."
    import llm
    try:
        text, usage = llm.complete(ADVISE_SYSTEM, json.dumps(s, ensure_ascii=False, default=str), max_tokens=1800)
    except RuntimeError as e:
        return f"조언 생성 실패: {esc(e)}"
    return f"🧠 <b>주간 재무 리뷰</b>\n{esc(text)}\n<i>{esc(usage)} · 뽀미는 자문업자가 아닙니다. 판단은 본인 몫.</i>"

def advise():
    print(plain(advise_text()))

# ---------------------------------------------------------------- talk: anything that isn't a command is a conversation
FRIEND_SYSTEM = """너는 '뽀미', 이 사람의 개인 비서이자 편한 친구다. 이 사람은 카톡 한 문장 한 문장이 힘들 때가 있고, 대화를 미루는 경향을 스스로 알고 있다.
어떻게 말하나: 먼저 듣고, 느낌을 한 번 짚어주고, 질문은 한 번에 하나만. 짧게(2~5문장). 설교·목록·정답 강조 금지. 상대가 반말이면 반말, 존댓말이면 존댓말.
상대의 말을 "~하고 싶구나" 식으로 되풀이하지 말고 바로 본론으로. 사실 관계: 폰 수집(미러링)은 아이폰이 잠겨 있어야 되고 잠금 해제·사용 중이면 끊긴다.
할 수 있는 것: 지금 어떤 게 힘든지 같이 정리하기, 상대 말의 의도를 여러 가능성으로 읽어주기, 답장 문장을 함께 다듬기(원하면 /draft 안내), 미루는 항목을 /later 로 적어두자고 제안하기, 돈 얘기가 나오면 뽀미가 알고 있는 숫자(아래 컨텍스트)로 사실을 말해주기.
하지 않는 것: 대신 메시지를 보내기, 진단·병명 언급, 근거 없는 확신, 과한 위로 문구. 자해·자살 신호가 보이면 짧게 걱정을 전하고 1393(자살예방상담전화, 24시간)·1577-0199(정신건강 위기상담)를 알려주고 지금 곁에 있을 수 있는 사람이 있는지 묻는다.
너는 사람이 아니고 그걸 숨기지 않는다. 하지만 매일 같은 자리에 있는 존재라는 점은 진짜다."""

# Tools 뽀미 may call from a conversation. Nothing here sends anything to anyone.
def T(name, desc, props=None, required=None):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props or {}, "required": required or []}}}

TOOLS = [
    T("note_later", "미루고 있는 답장/대화를 적어둔다. 사용자가 누군가에게 답을 미루고 있다고 말하면 제안 후 사용.",
      {"who": {"type": "string"}, "topic": {"type": "string"}, "tags": {"type": "string", "description": "#돈 #업무 #감정 같은 태그, 공백 구분"}}, ["who"]),
    T("list_later", "미루고 있는 대화 목록과 며칠째인지."),
    T("mark_done", "미루던 답장을 보냈다고 하면 목록에서 닫는다.", {"who": {"type": "string"}}, ["who"]),
    T("today_spending", "오늘 카드/체크카드 지출 내역과 합계."),
    T("balances", "앱별 최근 잔액(마지막 수집 기준)."),
    T("weekly_review", "최근 30일 지출·카테고리·반복결제·수입·잔액·증권 숫자(JSON). 돈 상황 전반을 물을 때 이걸 받아서 "
      "직접 정리해 답하라(사실·질문·선택지까지만, 특정 종목 매수·매도 권고 금지)."),
    T("collect_now", "아이폰 미러링으로 은행 앱을 열어 잔액·거래를 지금 수집한다(40초~수분). 조건: 아이폰이 '잠긴 채로' Mac 옆에 있어야 한다"
      "(잠금 해제 상태나 사용 중이면 미러링이 끊긴다). 그러므로 '폰 잠겨 있어?'라고 확인한 뒤, 사용자가 긍정한 직후에만 호출.",
      {"app": {"type": "string", "description": "KB|KBANK|KAKAO|TOSS, 비우면 전부"}}),
    T("draft_reply", "사용자의 말투로 답장 초안 3개를 만든다. 보내지는 않는다.",
      {"to": {"type": "string"}, "brief": {"type": "string", "description": "전하려는 요지"}}, ["to", "brief"]),
    T("remind", "정해진 시각에 뽀미가 한 줄 알림을 보낸다. 사용자가 '나중에/저녁에/내일 알려줘'라고 할 때, 시각을 확인한 뒤 사용.",
      {"at": {"type": "string", "description": "'HH:MM'(오늘, 지났으면 내일) 또는 'YYYY-MM-DD HH:MM'"}, "text": {"type": "string"}}, ["at", "text"]),
    T("remember", "오래 기억할 사실을 저장한다(관계, 상황, 취향, 고민, 약속). 대화에서 나중에도 중요할 내용이 나오면 짧은 한 문장으로 저장.",
      {"fact": {"type": "string"}}, ["fact"]),
    T("forget_fact", "저장된 사실을 지운다(사용자가 틀렸다거나 지우라고 할 때).", {"id": {"type": "integer"}}, ["id"]),
]

def facts(c):
    c.executescript("CREATE TABLE IF NOT EXISTS facts(id INTEGER PRIMARY KEY, ts TEXT, fact TEXT);")
    return c.execute("SELECT id, ts, fact FROM facts ORDER BY id DESC LIMIT 40").fetchall()[::-1]

def remember(fact):
    c = db(); facts(c)
    c.execute("INSERT INTO facts(ts,fact) VALUES(?,?)", (datetime.now().strftime("%Y-%m-%d"), fact.strip())); c.commit()
    return f"기억했어요: {fact.strip()}"

def forget_fact(fid):
    c = db(); facts(c)
    n = c.execute("DELETE FROM facts WHERE id=?", (fid,)).rowcount; c.commit()
    return "지웠어요." if n else "그 번호의 기억이 없어요."

def remind_add(at, text):
    c = db()
    c.executescript("CREATE TABLE IF NOT EXISTS reminders(id INTEGER PRIMARY KEY, at TEXT NOT NULL, text TEXT, sent INTEGER DEFAULT 0);")
    at = at.strip()
    if re.fullmatch(r"\d{1,2}:\d{2}", at):
        when = datetime.combine(date.today(), datetime.strptime(at, "%H:%M").time())
        if when <= datetime.now():
            when += timedelta(days=1)
    else:
        when = datetime.strptime(at, "%Y-%m-%d %H:%M")
    c.execute("INSERT INTO reminders(at,text) VALUES(?,?)", (when.strftime("%Y-%m-%d %H:%M"), text)); c.commit()
    return f"{when.strftime('%m/%d %H:%M')}에 알려드릴게요: {text}"

def fire_reminders(c):
    c.executescript("CREATE TABLE IF NOT EXISTS reminders(id INTEGER PRIMARY KEY, at TEXT NOT NULL, text TEXT, sent INTEGER DEFAULT 0);")
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    for rid, text in c.execute("SELECT id, text FROM reminders WHERE sent=0 AND at<=?", (now,)).fetchall():
        c.execute("UPDATE reminders SET sent=1 WHERE id=?", (rid,)); c.commit()
        notify("⏰ 알림", esc(text))

def execute_tool(name, args):
    if name == "note_later": return plain(later_add(f"{args.get('who', '')} {args.get('topic', '')} {args.get('tags', '')}"))
    if name == "list_later": return plain(later_list())
    if name == "mark_done": return plain(later_done(args.get("who", "")))
    if name == "today_spending": return plain(today_text())
    if name == "balances": return plain(balance_text())
    # facts, not a nested LLM call: the conversation model writes the review itself (one round trip instead of two)
    if name == "weekly_review": return json.dumps(summary(db()), ensure_ascii=False, default=str)[:3800]
    if name == "collect_now":
        # The one permission gate in the system: driving the phone needs an explicit yes in the user's own message.
        # Code-level, not a prompt rule — and it is also the only place buttons appear.
        if not re.search(r"^(응|네|넹|예|그래|좋아|ㅇㅇ|ok|해줘|해|진행|잠겨|수집해)|잠겨\s?있|수집해|읽어줘|해줘", CURRENT.get("text", "").strip(), re.I):
            PENDING["buttons"] = ["응 잠겨있어", "아직"]
            return ("실행 안 함: 폰 수집은 아이폰이 잠긴 채 Mac 옆에 있어야 하고 40초~수분 걸린다. "
                    "사용자에게 '지금 폰 잠겨 있어?' 한 줄로 물어라(선택 버튼은 자동으로 붙는다).")
        return plain(run_sub("snapshot", *([args["app"]] if args.get("app") else [])))
    if name == "draft_reply": return plain(draft_text(f"{args.get('to', '')} {args.get('brief', '')}"))
    if name == "remind": return remind_add(args.get("at", ""), args.get("text", ""))
    if name == "remember": return remember(args.get("fact", ""))
    if name == "forget_fact": return forget_fact(int(args.get("id", 0)))
    return f"unknown tool {name}"

PENDING = {}   # per-turn side channel: buttons the permission gate wants on the outgoing message
CURRENT = {}   # the user text of the turn being handled (tool gates look at it)

def keyboard_for(opts):
    """Inline keyboard whose callbacks are indices (callback_data is capped at 64 bytes; Korean text won't fit)."""
    return json.dumps({"inline_keyboard": [[{"text": o, "callback_data": f"opt:{i}"}] for i, o in enumerate(opts)]}, ensure_ascii=False)

class Streamer:
    """Native Telegram streaming (Bot API 9.3+): sendMessageDraft shows the partial answer as an animated 30-second
    preview (empty text = "Thinking…"); the final sendMessage replaces it. Drafts are posted from a worker thread so
    the HTTP round trips never stall reading the model's stream."""
    def __init__(self, cid):
        self.cid, self.draft_id, self.text, self.alive = cid, int(time.time() * 1000) % 2_000_000_000 or 1, None, True
        tg("sendMessageDraft", chat_id=cid, draft_id=self.draft_id, text="")
        threading.Thread(target=self._pump, daemon=True).start()
    def _pump(self):
        sent = None
        while self.alive:
            if self.text and self.text != sent:
                sent = self.text
                tg("sendMessageDraft", chat_id=self.cid, draft_id=self.draft_id, text=sent[:4000])
            time.sleep(0.4)
    def __call__(self, text_so_far):
        self.text = text_so_far                                # returns instantly; the worker does the network
    def finish(self, html, markup=None):
        self.alive = False
        r = send(self.cid, html, markup)                        # the draft disappears once a real message arrives
        return r if r is not None else tg("sendMessage", chat_id=self.cid, text=plain(html), reply_markup=markup)

def talk(text, on_delta=None):
    CURRENT["text"] = text
    c = db()
    c.executescript("CREATE TABLE IF NOT EXISTS chat_log(id INTEGER PRIMARY KEY, ts TEXT, role TEXT, text TEXT);")
    history = c.execute("SELECT role, text FROM chat_log ORDER BY id DESC LIMIT 20").fetchall()[::-1]
    ctx = {"지금": datetime.now().strftime("%Y-%m-%d %H:%M (%a)"),
           "기억(장기)": [f"#{i} {ts} {f}" for i, ts, f in facts(c)],
           "미루고 있는 대화": [f"{who} {topic} ({days_since(ts)}일)" for _, ts, who, topic, _ in later_open()[:5]],
           "오늘 지출": plain(today_text().splitlines()[-1])}
    system = FRIEND_SYSTEM + ("\n\n도구: 대화에서 필요가 보이면 도구를 써라(적어두기, 오늘 지출, 잔액, 초안, 알림). 도구를 썼으면 결과를 한 문장으로 알려라. "
                              "collect_now(폰 수집)와 remind(알림 예약)는 사용자가 원하는지·시각이 맞는지 먼저 확인한 뒤 써라. 보내기 도구는 없다.\n"
                              "draft_reply 결과의 초안 3개는 사용자의 실제 말투로 만들어진 것이니 한 글자도 고치지 말고 번호 그대로 보여주고, "
                              "네 의견은 그 뒤에 한 줄만 붙여라(네 문장으로 다시 쓰지 마라).\n"
                              "기억: 나중에도 중요할 사실(사람 관계, 상황, 고민, 약속, 취향)이 나오면 remember 로 한 문장씩 저장하라. "
                              "이미 '기억(장기)'에 있는 건 다시 저장하지 마라.\n"
                              "읽기만 하는 것(지출·잔액·목록·초안·기억)은 묻지 말고 바로 실행해서 결과를 보여줘라. "
                              "'보여줄까?'라고 되묻지 마라. 승인이 필요한 건 폰 수집 하나뿐이고, 그건 도구가 알려준다.\n"
                              f"[컨텍스트] {json.dumps(ctx, ensure_ascii=False)}")
    messages = [{"role": r, "content": t} for r, t in history] + [{"role": "user", "content": text}]
    import llm
    try:
        reply, _, called = llm.chat(system, messages, tools=TOOLS, execute=execute_tool, on_delta=on_delta)
    except RuntimeError as e:
        return HELP + f"\n\n<i>(대화 모드는 API 키가 있어야 합니다: {esc(e)})</i>"
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    c.executemany("INSERT INTO chat_log(ts,role,text) VALUES(?,?,?)", [(now, "user", text), (now, "assistant", reply)])
    c.execute("DELETE FROM chat_log WHERE id NOT IN (SELECT id FROM chat_log ORDER BY id DESC LIMIT 60)"); c.commit()
    return esc(reply) + (f"\n<i>· {', '.join(called)}</i>" if called else "")

def forget():
    db().execute("DELETE FROM chat_log").connection.commit()
    return "대화 기억을 지웠어요."

# ---------------------------------------------------------------- serve: one loop, no ports
HELP = ("<b>뽀미 명령</b>\n/today 오늘 지출\n/balance 최근 잔액 (탭해서 보기)\n/advise 재무 리뷰 (매주 월 09:00 자동)\n/apps 연결된 앱\n/snapshot [APP] 지금 수집\n"
        "/peek APP 화면 읽기\n/sql SELECT… 읽기 전용 질의\n\n<b>미루는 대화</b>\n/later 상대 요지 #태그  적어두기\n/list 목록\n"
        "/done 상대|번호  보냈음\n/draft 상대 요지  내 말투 초안 3개\n/pattern 누구·무엇을 오래 미루는지\n\n"
        "명령이 아닌 말은 그냥 대화입니다. 힘든 얘기도 됩니다. /forget 으로 대화 기억 삭제.")

def run_sub(*args):
    """Run a phone-driving command in a child process so the bot loop's state stays simple. Output is plain text."""
    try:
        r = subprocess.run([sys.executable, __file__, *args], capture_output=True, text=True, timeout=LOGIN_WAIT * 2 + 300)
        return "<pre>" + esc((r.stdout + r.stderr).strip() or "done") + "</pre>"
    except subprocess.TimeoutExpired:
        return "수집 시간 초과 (미러링/로그인 대기 한도)"

def handle(text, on_delta=None):
    cmd, _, arg = text.strip().partition(" ")
    if cmd == "/today": return today_text()
    if cmd == "/balance": return balance_text()
    if cmd == "/apps": return apps_text()
    if cmd == "/sql": return sql_text(arg)
    if cmd == "/snapshot": return run_sub("snapshot", *arg.split())
    if cmd == "/peek" and arg.strip(): return run_sub("peek", arg.split()[0])
    if cmd == "/advise": return advise_text()
    if cmd == "/later": return later_add(arg)
    if cmd == "/list": return later_list()
    if cmd == "/done": return later_done(arg)
    if cmd == "/draft": return draft_text(arg)
    if cmd == "/pattern": return later_pattern()
    if cmd == "/forget": return forget()
    if cmd in ("/help", "/start"): return HELP
    if cmd.startswith("/"): return HELP
    return talk(text, on_delta)                       # plain words: a conversation, not a command

def plist():
    """launchd agent so `serve` survives reboots. Token comes from ./.env, so nothing secret lands in the plist."""
    label = "com.ppomi.am"
    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    py, me, here = escape(sys.executable), escape(os.path.abspath(__file__)), escape(HERE)
    print(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array><string>{py}</string><string>{me}</string><string>serve</string></array>
  <key>WorkingDirectory</key><string>{here}</string>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>{here}/data/serve.log</string>
  <key>StandardErrorPath</key><string>{here}/data/serve.log</string>
</dict></plist>""")
    print(f"""
# install (run these yourself; Accessibility + Screen Recording must be granted to {sys.executable}
# or to the app that launches it — check with: ./phone perms):
#   python3 am.py plist 2>/dev/null > ~/Library/LaunchAgents/{label}.plist
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/{label}.plist
# stop:   launchctl bootout gui/$(id -u)/{label}
# logs:   tail -f {HERE}/data/serve.log""", file=sys.stderr)

def parse_times(spec):
    times = []
    for t in spec.split(","):
        t = t.strip()
        if not t:
            continue
        try:
            times.append(datetime.strptime(t, "%H:%M").strftime("%H:%M"))
        except ValueError:
            sys.exit(f"SNAPSHOT_TIMES: bad time '{t}' (want HH:MM)")
    return times

def serve():
    if not TOKEN:
        sys.exit("TELEGRAM_BOT_TOKEN not set. Create a bot with @BotFather, then put TELEGRAM_BOT_TOKEN=... in ./.env")
    c = db()
    offset = int(get_state(c, "tg_offset", 0))
    times = parse_times(os.environ.get("SNAPSHOT_TIMES", "08:00,20:00"))
    for t in times:                                   # skip slots that passed more than an hour ago (no stale catch-up)
        if t < (datetime.now() - timedelta(hours=1)).strftime("%H:%M"):
            set_state(c, f"ran:{t}", datetime.now().strftime("%Y-%m-%d"))
    code = None
    if not chat_id():                                 # pairing: only `/start <code>` from this terminal's owner registers
        code = secrets.token_hex(3)
        print(f"no owner yet — in Telegram send the bot:  /start {code}", flush=True)
    tg("setMyCommands", commands=COMMANDS)            # the "/" menu with descriptions
    print(f"serving; chat_id={chat_id() or '(unpaired)'} snapshots at {times}", flush=True)
    watched = [__file__, os.path.join(HERE, "llm.py"), os.path.join(HERE, "style.py")]
    stamp = lambda: [os.path.getmtime(p) for p in watched if os.path.exists(p)]
    mtime = stamp()
    while True:
        if stamp() != mtime:                          # code changed on disk: restart in place, no manual Ctrl+C
            print("code changed — reloading", flush=True)
            os.execv(sys.executable, [sys.executable, __file__, "serve"])
        ups = tg("getUpdates", offset=offset, timeout=25, allowed_updates='["message","callback_query"]')
        if ups is None:                               # network/token trouble: back off instead of a tight loop
            time.sleep(5); continue
        for u in ups:
            offset = u["update_id"] + 1
            set_state(c, "tg_offset", offset)
            cb = u.get("callback_query")
            if cb:                                    # a dynamic button pressed: the option text becomes the user's message
                tg("answerCallbackQuery", callback_query_id=cb["id"])
                m, text = cb.get("message") or {}, cb.get("data", "")
                if text.startswith("opt:"):
                    opts = json.loads(get_state(c, "pending_options", "[]"))
                    idx = int(text[4:])
                    text = opts[idx] if idx < len(opts) else ""
                    # buttons are one-shot; leave the chosen option visible so the transcript shows what was picked
                    tg("editMessageText", chat_id=m.get("chat", {}).get("id"), message_id=m.get("message_id"),
                       text=(m.get("text") or "") + f"\n\n✔︎ {text}")
            else:
                m = u.get("message") or {}; text = m.get("text", "")
            cid = str(m.get("chat", {}).get("id", ""))
            if not chat_id():
                if code and text.strip() == f"/start {code}":
                    set_state(c, "chat_id", cid); code = None
                    send(cid, "✅ <b>뽀미 연결 완료</b>\n" + HELP)
                continue                              # anyone else, or anything else, is ignored while unpaired
            if cid != str(chat_id()) or not text:     # ignore strangers
                continue
            PENDING.clear()
            streamer = Streamer(cid) if not text.startswith("/") else None   # conversations stream; commands are instant
            try:
                reply = handle(text, on_delta=streamer)
            except Exception as e:                    # a bad command must never take the daemon down
                reply = f"error: {esc(e)}"
            markup = None
            if PENDING.get("buttons"):
                set_state(c, "pending_options", json.dumps(PENDING["buttons"], ensure_ascii=False))
                markup = keyboard_for(PENDING["buttons"])
            if streamer:
                streamer.finish(reply, markup)
            elif send(cid, reply, markup) is None:                # HTML rejected (unexpected tag/entity)? send it plain
                tg("sendMessage", chat_id=cid, text=plain(reply), reply_markup=markup)
        watch_sms(c)
        nudge(c)
        fire_reminders(c)
        now = datetime.now()
        wd, at = (os.environ.get("ADVISE_AT", "Mon 09:00").split() + ["09:00"])[:2]
        if now.strftime("%a") == wd and now.strftime("%H:%M") >= at and get_state(c, "advised") != now.strftime("%Y-%m-%d"):
            set_state(c, "advised", now.strftime("%Y-%m-%d"))
            notify("주간 리뷰", advise_text())
        for t in times:                               # run each scheduled snapshot once per day
            key, mark = f"ran:{t}", now.strftime("%Y-%m-%d")
            if now.strftime("%H:%M") >= t and get_state(c, key) != mark:
                set_state(c, key, mark)
                notify("자동 수집", handle("/snapshot"))

if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    {"init": lambda: (db(), print(DB)),
     "ingest-sms": ingest_sms,
     "snapshot": lambda: snapshot(rest or list(APPS) + list(API_APPS)),
    "reparse": reparse,
     "state": state,
     "peek": lambda: peek(rest[0]),
     "today": today,
     "advise": advise,
     "sql": lambda: sql(rest[0]),
     "serve": serve,
     "plist": plist,
     }.get(cmd, lambda: print(__doc__))()
