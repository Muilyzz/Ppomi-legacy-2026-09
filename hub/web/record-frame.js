// Read-only adapters for source archives. Financial arithmetic stays in the vendored Journal renderer.
(() => {
  'use strict';
  const root = document.getElementById('records');
  const channel = location.hash.slice(1);
  const parentOrigin = new URL(location.href).origin;
  const names = new Set(['timeline', 'accounting', 'evidence', 'playbooks', 'health', 'spatial']);
  const arr = (v) => Array.isArray(v) ? v : [];
  const str = (v, fallback = '') => v == null ? fallback : String(v);
  const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = String(text); if (cls) el.className = cls; return el; };
  const add = (el) => { root.append(el); return el; };
  const note = (text) => add(node('p', text, 'view-notice'));
  const empty = (text) => { const el = node('div', null, 'empty'); el.append(node('h2', text)); add(el); };
  const date = (value) => { const d = new Date(value); return value && Number.isFinite(+d) ? d.toLocaleString('ko-KR') : str(value, '시각 미기재'); };
  const escape = (value) => str(value).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
  const labelScope = (scope, ownerID) => {
    const s = scope || {kind: 'unclassified', ownerID};
    return [({personal: '개인', business: '사업', unclassified: '미분류'})[s.kind] || '미분류', s.ownerID, s.businessID].filter(Boolean).join(' · ');
  };
  function exactJSON(value, depth = 0) {
    if (typeof value === 'bigint') return value.toString();
    if (value === null || typeof value !== 'object') return JSON.stringify(value) ?? 'null';
    const indent = '  '.repeat(depth), inner = indent + '  ';
    if (Array.isArray(value)) return value.length ? '[\n' + value.map(v => inner + exactJSON(v, depth + 1)).join(',\n') + '\n' + indent + ']' : '[]';
    const entries = Object.entries(value);
    return entries.length ? '{\n' + entries.map(([k, v]) => inner + JSON.stringify(k) + ': ' + exactJSON(v, depth + 1)).join(',\n') + '\n' + indent + '}' : '{}';
  }
  const raw = (value, label = '원본 기록 보기') => { const d = node('details'); d.append(node('summary', label), node('pre', exactJSON(value))); return d; };
  function exactAmount(value, unit) {
    let text = String(value), sign = '';
    if (text.startsWith('-')) { sign = '−'; text = text.slice(1); }
    if (!/^\d+$/.test(text) || !Number.isInteger(unit.scale) || unit.scale < 0 || unit.scale > 12) return '값 확인 필요';
    text = text.padStart(unit.scale + 1, '0');
    const integer = unit.scale ? text.slice(0, -unit.scale) : text;
    const fraction = unit.scale ? '.' + text.slice(-unit.scale) : '';
    return sign + integer.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + fraction + ' ' + unit.symbol;
  }
  const fields = (items) => { const dl = node('dl'); for (const [k, v] of items) { dl.append(node('dt', k), node('dd', v == null || v === '' ? '미기재' : v)); } return dl; };
  const selector = (label, values, callback) => {
    const wrapper = node('label', label), select = node('select');
    values.forEach(([value, text]) => { const option = node('option', text); option.value = value; select.append(option); });
    select.addEventListener('change', () => callback(select.value)); wrapper.append(select); return {wrapper, select};
  };
  function paged(items, render, mount) {
    if (!items.length) { mount.append(node('p', '이 범위에 기록이 없습니다.', 'context')); return; }
    const list = node('div', null, 'source-list'), more = node('button', '더 보기'); let shown = 0;
    const next = () => { const stop = Math.min(shown + 60, items.length); while (shown < stop) list.append(render(items[shown++])); more.hidden = shown === items.length; more.textContent = `더 보기 (${shown} / ${items.length})`; };
    more.addEventListener('click', next); mount.append(list, more); next();
  }

  function accounting(data) {
    if (!data || data.formatVersion !== 1 || !Array.isArray(data.books) || !Array.isArray(data.accounts) || !Array.isArray(data.entries) || !globalThis.Journal) throw new Error('archive');
    // Refuse archives the JS numeric representation cannot preserve. This is a display boundary, not a second ledger engine.
    for (const e of data.entries) {
      if (!Array.isArray(e.postings)) throw new Error('postings');
      for (const p of e.postings) if (!((typeof p.amount === 'bigint' && p.amount >= 0n) || (Number.isSafeInteger(p.amount) && p.amount >= 0))) throw new Error('precision');
    }
    function withinJournalRange(entries) {
      let bound = 0n;
      for (const e of entries) for (const p of e.postings) { if (typeof p.amount === 'bigint') return false; bound += BigInt(p.amount); }
      return bound <= BigInt(Number.MAX_SAFE_INTEGER);
    }
    function originalEntries(book, entries, mount) {
      mount.append(node('p', '큰 수량을 포함한 장부입니다. 합산 화면 대신 정확한 원본 분개와 평가 이력을 보여드립니다.', 'view-notice'));
      const accounts = new Map(data.accounts.filter(a => a.bookID === book.id).map(a => [a.id, a.name]));
      paged(entries, entry => {
        const card = node('article', null, 'source-card');
        card.append(node('span', entry.layer === 'recorded' ? '원본 분개' : '평가 조정 · 이력', 'source-badge'), node('h2', entry.memo || entry.eventID), fields([['발생 시각', date(entry.occurredAt)], ['활동 ID', entry.eventID], ['출처', entry.source], ['원본 기록', entry.sourceRecordID]]));
        for (const posting of entry.postings) card.append(fields([[`${posting.side === 'debit' ? '차변' : '대변'} · ${accounts.get(posting.accountID) || posting.accountID}`, exactAmount(posting.amount, book.unit)]]));
        if (entry.assessment) card.append(fields([['평가 근거', entry.assessment.rationale], ['모델·평가자', entry.assessment.model], ['교체한 평가', entry.assessment.replacesEntryID]]));
        card.append(raw(entry)); return card;
      }, mount);
    }
    const prohibited = new Set(['__proto__', 'constructor', 'prototype']);
    for (const item of [...data.books, ...data.accounts, ...data.entries]) if (typeof item.id !== 'string' || prohibited.has(item.id)) throw new Error('id');
    for (const b of data.books) if (!b.unit || !Number.isInteger(b.unit.scale) || b.unit.scale < 0 || b.unit.scale > 12 || typeof b.unit.symbol !== 'string') throw new Error('unit');
    for (const e of data.entries) if (e.assessment && !Number.isFinite(e.assessment.confidenceBasisPoints)) throw new Error('assessment');
    if (!data.books.length) return empty('공유된 장부가 없습니다.');
    const filters = add(node('div', null, 'filters')), context = add(node('p', '', 'context')), journal = add(node('div')); journal.id = 'journal';
    let kind = '', selected = data.books[0].id;
    const scope = selector('구분', [['', '전체 장부'], ['personal', '개인'], ['business', '사업'], ['unclassified', '미분류']], value => { kind = value; updateBooks(); });
    const book = selector('장부', [], value => { selected = value; draw(); }); book.wrapper.className = 'book-filter'; filters.append(scope.wrapper, book.wrapper);
    const shown = () => data.books.filter(b => !kind || (b.scope?.kind || 'unclassified') === kind);
    function updateBooks() {
      const books = shown(); book.select.replaceChildren();
      books.forEach(b => { const option = node('option', `${b.name} · ${labelScope(b.scope, b.ownerID)} · ${b.unit.symbol}`); option.value = b.id; book.select.append(option); });
      if (!books.some(b => b.id === selected)) selected = books[0]?.id || '';
      book.select.value = selected; book.select.disabled = !books.length; draw();
    }
    function draw() {
      const b = shown().find(b => b.id === selected); journal.replaceChildren();
      if (!b) { context.textContent = '이 범위에는 장부가 없습니다.'; return; }
      context.textContent = `${labelScope(b.scope, b.ownerID)}\n단위: ${b.unit.name} (${b.unit.symbol}) · 장부 ID: ${b.id}`;
      // A selected book is the whole rendering boundary. No totals combine owners, scopes, or units.
      const archive = {formatVersion: 1, books: [{...b, unit: {...b.unit, symbol: escape(b.unit.symbol)}}], accounts: data.accounts.filter(a => a.bookID === b.id), entries: data.entries.filter(e => e.bookID === b.id)};
      const mount = node('div'); journal.replaceChildren(mount);
      if (withinJournalRange(archive.entries)) globalThis.Journal.mount(mount, {archive, bookID: b.id, unit: 'all', depth: 1, layer: 'recorded'});
      else originalEntries(b, archive.entries, mount);
    }
    updateBooks();
  }

  function timeline(data) {
    if (!data || data.formatVersion !== 1 || !Array.isArray(data.transactions) || !Array.isArray(data.snapshots)) throw new Error('archive');
    note('공유된 원본 거래를 시간순으로 보여드립니다. 잔액 계산과 계좌 흐름 화면은 Mac 앱에서 확인할 수 있어요.');
    const transactions = data.transactions.slice().sort((a, b) => new Date(b.ts) - new Date(a.ts));
    if (!transactions.length && !data.snapshots.length) return empty('공유된 거래 기록이 없습니다.');
    const kind = {approval: '승인', cancel: '취소', deposit: '입금', withdrawal: '출금'};
    const list = add(node('section')); list.setAttribute('aria-label', '원본 거래');
    paged(transactions, tx => {
      const card = node('article', null, 'source-card'); card.append(node('h2', tx.merchant || '거래'));
      card.append(fields([['발생 시각', date(tx.ts)], ['기록 종류', kind[tx.kind] || tx.kind], ['원본 금액', Number.isSafeInteger(tx.amount) ? `${tx.amount.toLocaleString('ko-KR')}원` : '숫자 정밀도 확인 필요'], ['출처', [tx.app, tx.tag].filter(Boolean).join(' · ')], ['원본 ID', tx.uid]]), raw(tx)); return card;
    }, list);
    const snapshots = node('details'); snapshots.append(node('summary', `잔액 관측 원본 (${data.snapshots.length})`));
    paged(data.snapshots, s => { const card = node('article', null, 'source-card'); card.append(node('h2', s.account), fields([['관측 시각', date(s.ts)], ['출처', s.app], ['원본 잔액', Number.isSafeInteger(s.balance) ? `${s.balance.toLocaleString('ko-KR')}원` : '숫자 정밀도 확인 필요']]), raw(s)); return card; }, snapshots); add(snapshots);
  }

  function health(data) {
    const archive = data?.archive;
    if (!archive || archive.formatVersion !== 1 || !Array.isArray(archive.records) || !Array.isArray(archive.entities)) throw new Error('archive');
    note('공유된 건강 기록의 측정값과 출처를 그대로 보여드립니다. 입력되지 않은 값은 채우지 않습니다.');
    const records = archive.records.filter(r => !['financialSnapshot', 'financialTransaction'].includes(r.kind));
    if (!records.length) return empty('공유된 건강 기록이 없습니다.');
    const subjects = [...new Set(records.map(r => r.subjectID))], filters = add(node('div', null, 'filters')), list = add(node('section'));
    const kinds = {measurement: '몸의 변화', meal: '식사', exercise: '운동', checkIn: '컨디션', habit: '습관'};
    const methods = {api: 'API에서 가져옴', ocr: '화면·결과지에서 읽음', manual: '직접 기록', legacyImport: '기존 장부에서 가져옴', aiEstimate: 'AI 추정'};
    const person = selector('기록 대상', subjects.map(id => [id, archive.entities.find(e => e.id === id)?.name || id]), draw);
    filters.append(person.wrapper); person.select.value = subjects.includes(data.selfID) ? data.selfID : subjects[0];
    function draw() {
      list.replaceChildren();
      paged(records.filter(r => r.subjectID === person.select.value).sort((a,b) => new Date(b.occurredAt)-new Date(a.occurredAt)), r => {
        const card = node('article', null, 'source-card');
        card.append(node('span', methods[r.method] || r.method, 'source-badge'), node('span', r.review === 'userConfirmed' ? '사용자 확인' : '사용자 미확인', 'source-badge'), node('h2', `${kinds[r.kind] || r.kind} · ${date(r.occurredAt)}`));
        if (r.activityStatus) card.append(node('p', r.activityStatus === 'retracted' ? '완료 기록 철회됨' : `활동 상태: ${r.activityStatus}`));
        if (arr(r.metrics).length) card.append(fields(r.metrics.map(m => [m.title || m.code, typeof m.value === 'number' && Number.isFinite(m.value) ? `${m.value} ${m.unit}` : '값 확인 필요'])));
        else card.append(node('p', '측정값 미입력', 'context'));
        if (r.note) card.append(node('p', r.note));
        card.append(fields([['출처', r.sourceName], ['원본 기록', r.sourceRecordID], ['대상 ID', r.subjectID], ['기록 시각', date(r.recordedAt)]]), raw({record: r, revisions: arr(archive.revisions).filter(v => v.recordID === r.id)})); return card;
      }, list);
    }
    draw();
  }

  function spatial(data) {
    if (!data || data.formatVersion !== 1 || data.unit !== 'm' || !Array.isArray(data.assets)) throw new Error('archive');
    note('공유된 외곽선과 높이로 공간의 윤곽을 보여드립니다. 치수·출처·소유·사용 근거를 함께 확인할 수 있어요.');
    if (!data.assets.length) return empty('공유된 공간 자료가 없습니다.');
    const filters = add(node('div', null, 'filters')), list = add(node('section'));
    const filter = selector('사용 구분', [['', '전체'], ['personal', '개인'], ['business', '사업'], ['unclassified', '미분류']], draw); filters.append(filter.wrapper);
    const share = bp => bp == null ? '미입력' : `${bp / 100}%`;
    const provenance = {measured: '실측', estimated: '추정', schematic: '개략'};
    function draw() {
      list.replaceChildren();
      const assets = data.assets.filter(a => !filter.select.value || (arr(a.usages).length ? a.usages.some(u => u.scope?.kind === filter.select.value) : filter.select.value === 'unclassified'));
      paged(assets, asset => {
        const card = node('article', null, 'source-card'); if (asset.isSynthetic) card.append(node('span', '가상 자료', 'source-badge'));
        card.append(node('h2', asset.title), fields([['자료 ID', asset.id], ['자산 참조', asset.entityID]]));
        const preview = node('div'); card.append(preview); globalThis.SpatialPreview?.mount(preview, asset);
        arr(asset.parts).forEach(part => { card.append(node('h3', part.title || part.id), fields([['출처 구분', provenance[part.provenance?.kind] || '미기재'], ['높이', `${part.height} m`], ['기준면 높이', `${part.elevation} m`], ['출처 기록', part.provenance?.sourceRecordID], ['근거', part.provenance?.note]])); });
        card.append(node('h3', '소유 근거'));
        if (!arr(asset.ownerships).length) card.append(node('p', '소유 근거 미입력', 'context'));
        arr(asset.ownerships).forEach(o => card.append(fields([['소유자 ID', o.ownerID], ['지분', share(o.shareBasisPoints)], ['출처 기록', o.sourceRecordID], ['근거', o.note]])));
        card.append(node('h3', '사용 근거'));
        if (!arr(asset.usages).length) card.append(node('p', '미분류 · 사용 근거 미입력', 'context'));
        arr(asset.usages).forEach(u => card.append(fields([['사용 구분', labelScope(u.scope)], ['배분 비율', share(u.allocationBasisPoints)], ['출처 기록', u.sourceRecordID], ['근거', u.note], ['장부·계정 참조', arr(u.accountLinks).map(l => `${l.bookID} / ${l.accountID}`).join('\n')]])));
        if (arr(asset.accountIDs).length) card.append(fields([['이전 미검증 참조', asset.accountIDs.join('\n')]]));
        card.append(raw(asset)); return card;
      }, list);
    }
    draw();
  }

  function playbooks(data) {
    if (!data || !Array.isArray(data.entries) || !globalThis.Playbook) throw new Error('archive');
    note('Mac에서 공유한 플레이북과 당시의 발자국입니다. 이 화면에서 앱을 실행하거나 기기를 제어하지 않습니다.');
    if (!data.entries.length) return empty('공유된 플레이북이 없습니다.');
    const filters = add(node('div', null, 'filters')), content = add(node('section'));
    const choose = selector('플레이북', data.entries.map((e, i) => [String(i), e.manifest?.name || e.manifest?.id || `플레이북 ${i + 1}`]), draw); filters.append(choose.wrapper);
    function draw() {
      const item = data.entries[Number(choose.select.value)]; content.replaceChildren(); if (!item?.manifest) return;
      const view = node('div'); content.append(view); globalThis.Playbook.mount(view, {manifest: item.manifest, footprints: arr(item.footprints)});
      if (item.guide) { const details = node('details'); details.append(node('summary', '사용 절차 읽기'), node('pre', item.guide)); content.append(details); }
      content.append(raw(item));
    }
    draw();
    if (data.common) { const common = node('details'); common.append(node('summary', '공통 안내'), node('pre', data.common)); add(common); }
    if (arr(data.issues).length) { const issues = node('details'); issues.append(node('summary', '공유된 확인 사항'), node('pre', data.issues.join('\n'))); add(issues); }
  }

  // Only the serialized E object is read from a legacy evidence document. No supplied script executes.
  function evidenceObject(html) {
    if (typeof html !== 'string' || html.length > 96 * 1024 * 1024) throw new Error('evidence');
    const marker = /\bvar\s+E\s*=\s*(?:\/\*EVIDENCE\*\/\s*)?/.exec(html);
    if (!marker) throw new Error('evidence');
    let start = marker.index + marker[0].length, depth = 0, quoted = false, escaped = false;
    if (html[start] !== '{') throw new Error('evidence');
    for (let i = start; i < html.length; i++) {
      const c = html[i];
      if (quoted) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') quoted = false; }
      else if (c === '"') quoted = true;
      else if (c === '{' || c === '[') depth++;
      else if (c === '}' || c === ']') { if (--depth === 0) return JSON.parse(html.slice(start, i + 1)); }
    }
    throw new Error('evidence');
  }
  const imageData = value => typeof value === 'string' && /^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=\r\n]+$/.test(value);
  function evidenceColumn(html) {
    // Template contents are inert; copying a small allowlist drops URLs, SVG, handlers, links, and all executable elements.
    const template = document.createElement('template'); template.innerHTML = str(html);
    const allowed = new Set(['DIV', 'SPAN', 'IMG']); let count = 0;
    const walk = source => {
      if (++count > 100000) throw new Error('evidence');
      if (source.nodeType === Node.TEXT_NODE) return document.createTextNode(source.textContent);
      if (source.nodeType !== Node.ELEMENT_NODE || !allowed.has(source.tagName)) return null;
      const result = document.createElement(source.tagName.toLowerCase());
      if (source.className && typeof source.className === 'string') result.className = source.className.split(/\s+/).filter(x => ['col', 'row', 'peek', 'box', 'warn', 'bad', 'on'].includes(x)).join(' ');
      for (const property of ['left', 'right', 'top', 'bottom', 'width', 'height', 'font-size', 'color']) {
        const value = source.style.getPropertyValue(property);
        if (/^-?\d+(?:\.\d+)?(?:px|%)$/.test(value) || (property === 'color' && /^(?:#[a-fA-F0-9]{3,8}|rgb\([0-9.,% ]+\))$/.test(value))) result.style.setProperty(property, value);
      }
      if (source.tagName === 'IMG') { if (!imageData(source.getAttribute('src'))) return null; result.src = source.getAttribute('src'); result.alt = '공유된 원본 화면'; result.hidden = true; }
      for (const child of source.childNodes) { const safe = walk(child); if (safe) result.append(safe); }
      return result;
    };
    const out = node('div', null, 'evidence-column'); for (const child of template.content.childNodes) { const safe = walk(child); if (safe) out.append(safe); }
    const column = out.querySelector('.col'); if (column?.style.height) out.style.height = column.style.height;
    return out;
  }
  function evidence(data) {
    const archive = typeof data === 'string' ? evidenceObject(data) : data;
    if (!archive || !Array.isArray(archive.apps)) throw new Error('evidence');
    if (!archive.apps.length) return empty('공유된 증빙이 없습니다.');
    if (archive.sub) note(archive.sub);
    const filters = add(node('div', null, 'filters')), content = add(node('section'));
    const choose = selector('증빙', archive.apps.map((a, i) => [String(i), [a.title, a.account].filter(Boolean).join(' · ')]), draw); filters.append(choose.wrapper);
    function draw() {
      const app = archive.apps[Number(choose.select.value)]; content.replaceChildren();
      const area = node('div', null, 'evidence-area'), column = evidenceColumn(app.col); area.append(column); content.append(area);
      const images = [...column.querySelectorAll('img')];
      if (images.length) { const originals = node('details'); originals.append(node('summary', `원본 화면 보기 (${images.length})`)); const list = node('div', null, 'evidence-originals'); images.forEach(image => { const copy = node('img'); copy.src = image.src; copy.alt = image.alt; list.append(copy); }); originals.append(list); content.append(originals); }
    }
    draw();
  }

  const renderers = {timeline, accounting, health, spatial, playbooks, evidence};
  let received = false;
  const report = stage => parent.postMessage({type: 'ppomi-record-frame', channel, stage}, parentOrigin);
  if (window.parent === window || !/^[a-f0-9]{32}$/.test(channel)) { root.replaceChildren(); return; }
  window.addEventListener('message', event => {
    const m = event.data;
    if (received || event.source !== parent || event.origin !== parentOrigin || !m || typeof m !== 'object' || Array.isArray(m)) return;
    if (m.type !== 'ppomi-record-render' || m.channel !== channel || !names.has(m.name) || Object.keys(m).length !== 4) return;
    received = true; root.replaceChildren();
    try { renderers[m.name](m.data); report('rendered'); }
    catch { root.replaceChildren(node('p', '기록 형식을 확인하지 못했습니다.', 'view-notice')); report('error'); }
  });
  report('ready');
})();
