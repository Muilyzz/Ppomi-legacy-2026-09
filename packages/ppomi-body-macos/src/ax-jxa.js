// Live Mac Accessibility for ppomi-body-macos.
// Same tool names and node shape as Ppomi/Sources/Ppomi/Serve/MacUI.swift (PR #12).
// System Events = AX tree / AXPress; CoreGraphics HID click is the web-content fallback
// (Chrome AXPress on AXWebArea / AXLink is often a no-op).
// argv[0] is a JSON command. stdout is one JSON object.

var NODE_LIMIT = 500;
var DEPTH_LIMIT = 20;
var WALK_MS = 5000;
var LIVE_WINDOW_MIN = 200;
var CLICKABLE = {
  AXButton: true,
  AXLink: true,
  AXCheckBox: true,
  AXRadioButton: true,
  AXPopUpButton: true,
  AXMenuItem: true,
  AXTab: true,
};
var EDITABLE = { AXTextField: true, AXTextArea: true, AXComboBox: true, AXSearchField: true };
var BUNDLES = { Safari: "com.apple.Safari", "Google Chrome": "com.google.Chrome" };
// Tools.payWord without the lookbehind (JavaScriptCore on older macOS lacks it): the same list,
// anchored to the end of a button's text, and "바로구매" only opens an order sheet.
var PAY_WORD = /(결제|구매|주문|송금|이체|입금|충전|구독|가입)\s*(하기|완료|진행)?\s*$/;

function isPayWord(text) {
  var value = String(text == null ? "" : text).replace(/^\s+|\s+$/g, "");
  var match = PAY_WORD.exec(value);
  return !!match && !/바로$/.test(value.substring(0, match.index));
}

function fail(code, message) {
  var err = new Error(message);
  err.code = code;
  throw err;
}

function trusted() {
  try {
    ObjC.import("ApplicationServices");
    return !!$.AXIsProcessTrusted();
  } catch (e) {
    return false;
  }
}

function attr(el, name) {
  try {
    return el.attributes.byName(name).value();
  } catch (e) {
    return null;
  }
}

function prop(el, key) {
  try {
    var value = el[key]();
    return value === undefined ? null : value;
  } catch (e) {
    return null;
  }
}

function limit(text) {
  var value = text == null ? "" : String(text).replace(/^\s+|\s+$/g, "");
  return value.length <= 1024 ? value : value.substring(0, 1024);
}

function shortRole(role) {
  var trimmed = role.indexOf("AX") === 0 ? role.substring(2) : role;
  if (trimmed === "Button") return "button";
  if (trimmed === "Link") return "link";
  if (
    trimmed === "TextField" ||
    trimmed === "TextArea" ||
    trimmed === "ComboBox" ||
    trimmed === "SearchField" ||
    trimmed === "SecureTextField"
  ) {
    return "edit";
  }
  if (trimmed === "StaticText") return "text";
  if (trimmed === "CheckBox") return "checkbox";
  if (trimmed === "RadioButton") return "radio";
  if (trimmed === "WebArea") return "document";
  return trimmed.toLowerCase();
}

function actions(el) {
  var names = [];
  try {
    var list = el.actions();
    var n = list.length;
    for (var i = 0; i < n; i++) names.push(String(list[i].name()));
  } catch (e) {
    /* some nodes expose no actions */
  }
  return names;
}

function childrenOf(el) {
  try {
    return el.uiElements();
  } catch (e) {
    return [];
  }
}

function boundsOf(el) {
  var pos = attr(el, "AXPosition") || prop(el, "position");
  var size = attr(el, "AXSize") || prop(el, "size");
  if (!pos || !size) return { left: 0, top: 0, right: 0, bottom: 0 };
  var x = Number(pos[0]);
  var y = Number(pos[1]);
  var w = Number(size[0]);
  var h = Number(size[1]);
  if (!(w > 0 && h > 0)) return { left: x, top: y, right: x, bottom: y };
  return { left: x, top: y, right: x + w, bottom: y + h };
}

function processOf(app) {
  var se = Application("System Events");
  try {
    var proc = se.processes.byName(app);
    if (!proc.exists()) fail("app_not_found", "app_not_found. " + app);
    return proc;
  } catch (e) {
    if (e && e.code) throw e;
    fail("app_not_found", "app_not_found. " + app);
  }
}

function frontWindow(proc) {
  proc.frontmost = true;
  var windows = proc.windows;
  var count = windows.length;
  var best = null;
  var bestArea = 0;
  for (var i = 0; i < count; i++) {
    var win = windows[i];
    var box = boundsOf(win);
    var width = box.right - box.left;
    var height = box.bottom - box.top;
    if (width < LIVE_WINDOW_MIN || height < LIVE_WINDOW_MIN) continue;
    var area = width * height;
    if (area > bestArea) {
      best = win;
      bestArea = area;
    }
  }
  if (!best) fail("app_not_found", "app_not_found. no live window");
  try {
    best.actions.byName("AXRaise").perform();
  } catch (e) {
    /* raise is best-effort */
  }
  return best;
}

// The identity a node is checked and acted on: role, secure-field flag, and the composed text.
// Shared by the read walk and the live re-check at tap/type time so both see the same string.
function describe(el) {
  var roleRaw = String(attr(el, "AXRole") || prop(el, "role") || "");
  var subrole = String(attr(el, "AXSubrole") || "");
  var password = roleRaw === "AXSecureTextField" || subrole === "AXSecureTextField";
  var title = limit(attr(el, "AXTitle") || prop(el, "title") || prop(el, "name"));
  var description = limit(attr(el, "AXDescription") || prop(el, "description"));
  var value = password ? "" : limit(attr(el, "AXValue") || prop(el, "value"));
  var parts = [];
  if (password) parts.push(title ? title + " [protected]" : "[protected]");
  else {
    if (title) parts.push(title);
    if (value && value !== title) parts.push(value);
    if (description && description !== title && description !== value) parts.push(description);
  }
  return { roleRaw: roleRaw, password: password, text: limit(parts.join(" ")) };
}

// A node id only encodes a pre-order index; the tree may have changed since the read. Act only if the
// live element still has the role and text the caller was allowed to act on.
function verifyLive(el, cmd) {
  var live = describe(el);
  if (cmd.role !== undefined && shortRole(live.roleRaw) !== String(cmd.role)) {
    fail("stale_screen", "stale_screen. role changed");
  }
  if (cmd.label !== undefined && live.text !== String(cmd.label)) {
    fail("stale_screen", "stale_screen. text changed");
  }
  return live;
}

function walkWindow(win) {
  var nodes = [];
  var truncated = false;
  var deadline = Date.now() + WALK_MS;
  var seen = 0;

  function walk(el, ancestors, depth) {
    if (nodes.length >= NODE_LIMIT || seen > 1000 || Date.now() > deadline) {
      truncated = true;
      return;
    }
    seen += 1;
    if (attr(el, "AXHidden") === true) return;
    var described = describe(el);
    var roleRaw = described.roleRaw;
    var password = described.password;
    var enabled = attr(el, "AXEnabled");
    if (enabled == null) enabled = prop(el, "enabled");
    if (enabled == null) enabled = true;
    var box = boundsOf(el);
    var acts = actions(el);
    var press = acts.indexOf("AXPress") >= 0 || !!CLICKABLE[roleRaw];
    var editable = !password && (!!EDITABLE[roleRaw] || acts.indexOf("AXConfirm") >= 0);
    var web = roleRaw === "AXLink" || ancestors.indexOf("AXWebArea") >= 0;
    nodes.push({
      text: described.text,
      role: shortRole(roleRaw),
      clickable: !!(press && enabled && !password),
      editable: !!(editable && enabled),
      password: !!password,
      web: web,
      bounds: box,
    });
    if (depth >= DEPTH_LIMIT || password) return;
    var kids = childrenOf(el);
    var n = kids.length;
    var next = ancestors.concat([roleRaw]);
    for (var i = 0; i < n; i++) {
      walk(kids[i], next, depth + 1);
      if (truncated) return;
    }
  }

  walk(win, [], 0);
  return { nodes: nodes, truncated: truncated };
}

function hidClick(x, y) {
  ObjC.import("CoreGraphics");
  var pt = $.CGPointMake(x, y);
  var down = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, pt, $.kCGMouseButtonLeft);
  var up = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, pt, $.kCGMouseButtonLeft);
  $.CGEventPost($.kCGHIDEventTap, down);
  delay(0.02);
  $.CGEventPost($.kCGHIDEventTap, up);
}

function elementAt(win, index) {
  var found = null;
  var n = -1;
  function find(el, depth) {
    if (found || n > 1000) return;
    if (attr(el, "AXHidden") === true) return;
    n += 1;
    if (n === index) {
      found = el;
      return;
    }
    var roleRaw = String(attr(el, "AXRole") || prop(el, "role") || "");
    var subrole = String(attr(el, "AXSubrole") || "");
    if (roleRaw === "AXSecureTextField" || subrole === "AXSecureTextField" || depth >= DEPTH_LIMIT) return;
    var kids = childrenOf(el);
    for (var i = 0; i < kids.length; i++) find(kids[i], depth + 1);
  }
  find(win, 0);
  if (!found) fail("stale_screen", "stale_screen. node gone");
  return found;
}

function requireTrusted() {
  if (!trusted()) fail("accessibility", "손쉬운 사용 권한이 필요합니다.");
}

function openApp(app, url) {
  var target = Application(app);
  target.activate();
  if (url) {
    try {
      target.openLocation(url);
    } catch (e) {
      Application("System Events").openLocation(url);
    }
    delay(2);
  }
  var proc = processOf(app);
  frontWindow(proc);
  return { opened: true, app: app };
}

function dispatch(cmd) {
  var op = cmd.op;
  if (op === "trusted") return { trusted: trusted() };
  var app = cmd.app;
  if (!app) fail("app_not_found", "app_not_found. app required");
  if (op === "open") return openApp(app, cmd.url);
  requireTrusted();
  var proc = processOf(app);
  var win = frontWindow(proc);
  if (op === "read") {
    var walked = walkWindow(win);
    return {
      appLabel: app,
      packageName: BUNDLES[app] || app,
      truncated: walked.truncated,
      nodes: walked.nodes,
    };
  }
  if (op === "tap") {
    var el = elementAt(win, Number(cmd.index));
    var live = verifyLive(el, cmd);
    // The read-time check covered a node that may have changed; the live element decides.
    if (live.password || isPayWord(live.text)) fail("protected_action", "protected_action. " + live.text);
    var box = boundsOf(el);
    if (!(box.right - box.left >= 2 && box.bottom - box.top >= 2)) {
      fail("stale_screen", "stale_screen. no live frame"); // never click a remembered point
    }
    var x = (box.left + box.right) / 2;
    var y = (box.top + box.bottom) / 2;
    var web = !!cmd.web || live.roleRaw === "AXLink";
    if (web) hidClick(x, y);
    else {
      try {
        el.actions.byName("AXPress").perform();
      } catch (e) {
        hidClick(x, y);
      }
    }
    return { invoked: true };
  }
  if (op === "type") {
    var field = elementAt(win, Number(cmd.index));
    var liveField = verifyLive(field, cmd);
    if (liveField.password) fail("protected_action", "protected_action. " + liveField.text);
    try {
      field.attributes.byName("AXValue").value = String(cmd.text);
    } catch (e) {
      try {
        field.focused = true;
      } catch (ignored) {
        /* focus is best-effort */
      }
      // Keystrokes land on whatever is focused: confirm it is this field, or refuse.
      if (attr(field, "AXFocused") !== true) fail("stale_screen", "stale_screen. field did not take focus");
      Application("System Events").keystroke(String(cmd.text));
    }
    return { typed: true };
  }
  fail("failed", "unknown op " + op);
}

function mapCode(code, message) {
  if (code === "accessibility" || code === "app_not_found" || code === "stale_screen" || code === "protected_action") {
    return code;
  }
  if (/assistive access|AXIsProcessTrusted|-25211|손쉬운 사용|not trusted/i.test(message)) return "accessibility";
  if (/not authorized|-1743|1002/i.test(message)) return "accessibility";
  if (/app_not_found|can’t get|can't get|does not understand/i.test(message)) return "app_not_found";
  return "failed";
}

function run(argv) {
  try {
    var cmd = JSON.parse(argv[0] || "{}");
    return JSON.stringify({ ok: true, result: dispatch(cmd) });
  } catch (e) {
    var message = e && e.message ? String(e.message) : String(e);
    var code = mapCode(e && e.code ? String(e.code) : "failed", message);
    return JSON.stringify({ ok: false, code: code, message: message });
  }
}
