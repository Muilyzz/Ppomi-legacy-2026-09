/* Read-only projection of SpatialAsset v1, in metres. No network, persistence,
 * accounting, ownership inference, or generated geometry. The caller validates
 * SpatialArchive.formatVersion === 1 and unit === 'm' before mounting an asset. */
(function () {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg', EPS = 1e-8;
  const mounts = new WeakMap();
  const kinds = Object.freeze({
    measured: {label: '실측 · 출처 기재', color: '#277a7e'},
    estimated: {label: '추정', color: '#a56829'},
    schematic: {label: '개략', color: '#79669c'},
    unknown: {label: '출처 구분 미확인', color: '#747b86'}
  });
  const text = (value, fallback = '') => typeof value === 'string' && value.trim() ? value.slice(0, 2000) : fallback;
  const finite = (value, bound) => typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= bound;
  const cross = (a, b, c) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  const onSegment = (a, b, p) => Math.abs(cross(a, b, p)) <= EPS &&
    p.x >= Math.min(a.x, b.x) - EPS && p.x <= Math.max(a.x, b.x) + EPS &&
    p.y >= Math.min(a.y, b.y) - EPS && p.y <= Math.max(a.y, b.y) + EPS;
  function intersects(a, b, c, d) {
    const x = cross(a, b, c), y = cross(a, b, d), z = cross(c, d, a), w = cross(c, d, b);
    return (((x > EPS && y < -EPS) || (x < -EPS && y > EPS)) &&
      ((z > EPS && w < -EPS) || (z < -EPS && w > EPS))) ||
      onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b);
  }
  function geometryIssue(part) {
    if (!part || !finite(part.height, 10000) || part.height <= 0) return '높이 미입력 또는 지원 범위 밖';
    if (!finite(part.elevation, 10000)) return '기준면 높이 미입력 또는 지원 범위 밖';
    const p = part.footprint;
    if (!Array.isArray(p) || p.length < 3 || p.length > 256) return '외곽선 꼭짓점은 3~256개 필요';
    if (p.some(v => !v || !finite(v.x, 1000000) || !finite(v.y, 1000000))) return '유효한 미터 좌표 필요';
    for (let i = 0; i < p.length; i++) {
      const a = p[i], b = p[(i + 1) % p.length], c = p[(i + 2) % p.length];
      if (Math.hypot(a.x - b.x, a.y - b.y) <= 0.0001) return '외곽선 꼭짓점 중복 또는 간격 부족';
      if (Math.abs(cross(a, b, c)) <= EPS && (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) < 0) return '외곽선 변 겹침';
      for (let j = i + 1; j < p.length; j++) {
        if (j === i + 1 || (i === 0 && j === p.length - 1)) continue;
        if (intersects(a, b, p[j], p[(j + 1) % p.length])) return '외곽선 교차 또는 접촉';
      }
    }
    let twiceArea = 0;
    for (let i = 1; i < p.length - 1; i++) twiceArea += cross(p[0], p[i], p[i + 1]);
    return Math.abs(twiceArea) / 2 > 0.0001 ? null : '외곽선 면적 부족';
  }
  function element(tag, value) {
    const node = document.createElement(tag);
    if (value != null) node.textContent = value;
    return node;
  }
  function svgElement(tag, attrs) {
    const node = document.createElementNS(NS, tag);
    for (const [key, value] of Object.entries(attrs || {})) node.setAttribute(key, String(value));
    return node;
  }
  function mount(container, asset) {
    if (!container || typeof container.append !== 'function') throw new TypeError('Spatial preview container required');
    mounts.get(container)?.destroy();
    const panel = element('section'), title = text(asset?.title, '공간 자료');
    panel.className = 'spatial-preview';
    panel.setAttribute('aria-label', title + ' · 형상 미리보기');
    Object.assign(panel.style, {margin: '18px 0', padding: '14px', border: '1px solid var(--line, #d8dce3)', borderRadius: '12px'});
    const result = {destroy() { panel.remove(); if (mounts.get(container) === result) mounts.delete(container); }};
    mounts.set(container, result); container.append(panel);
    const message = value => { const p = element('p', value); Object.assign(p.style, {fontSize: '12px', lineHeight: '1.6', margin: '6px 0'}); panel.append(p); return p; };
    message(asset?.isSynthetic === true ? '가상 자료 · 실제 자산 아님' : '공유된 외곽선과 입력 높이의 윤곽 미리보기');
    if (!Array.isArray(asset?.parts) || !asset.parts.length) { message('제공된 형상이 없습니다.'); return result; }
    if (asset.parts.length > 100 || asset.parts.reduce((n, p) => n + (Array.isArray(p?.footprint) ? p.footprint.length : 0), 0) > 20000) {
      message('형상 수 또는 꼭짓점 수가 미리보기 지원 범위를 넘습니다. 원본 자료에서 확인해 주세요.'); return result;
    }
    const parts = [], issues = [], ids = new Set();
    for (const part of asset.parts) {
      const label = text(part?.title, text(part?.id, '이름 미기재 형상'));
      const issue = geometryIssue(part) || (part.id != null && ids.has(part.id) ? '형상 ID 중복' : null);
      if (part?.id != null) ids.add(part.id);
      if (issue) { issues.push(label + ': ' + issue); continue; }
      const suppliedKind = part.provenance?.kind;
      const kind = typeof suppliedKind === 'string' && Object.hasOwn(kinds, suppliedKind) ? suppliedKind : 'unknown';
      // Work on a separate geometry buffer; imported coordinates remain untouched.
      parts.push({label, footprint: part.footprint.map(p => ({x: p.x, y: p.y})), height: part.height,
        elevation: part.elevation, kind, source: text(part.provenance?.sourceRecordID, '출처 기록 미기재'),
        note: text(part.provenance?.note, '치수 근거 미기재')});
    }
    if (issues.length) {
      message(`표시하지 못한 형상 ${issues.length}개 · 아래 원본 치수와 출처를 확인해 주세요.`);
      const details = element('details'); details.append(element('summary', '표시하지 못한 이유'));
      const list = element('ul'); for (const issue of issues) list.append(element('li', issue)); details.append(list); panel.append(details);
    }
    if (!parts.length) { message('표시할 수 있는 외곽선·높이·기준면 조합이 없습니다.'); return result; }
    const legend = element('div'); Object.assign(legend.style, {display: 'flex', flexWrap: 'wrap', gap: '8px 14px', fontSize: '12px'});
    for (const kind of new Set(parts.map(p => p.kind))) {
      const key = element('span', '● ' + kinds[kind].label); key.style.color = kinds[kind].color; legend.append(key);
    }
    panel.append(legend);
    if (asset.isSynthetic === true && parts.some(p => p.kind !== 'schematic')) message('가상 자료 표시와 형상 출처 구분이 일치하지 않습니다. 원본의 출처를 확인해 주세요.');
    const svg = svgElement('svg', {viewBox: '0 0 720 420', role: 'img', 'aria-label': `${title} · ${parts.length}개 형상 · 가려진 변을 포함한 윤곽`});
    Object.assign(svg.style, {display: 'block', width: '100%', height: 'auto', maxHeight: '420px', margin: '8px 0', background: 'var(--surface, transparent)'});
    panel.append(svg);
    const bounds = {minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity, low: Infinity, high: -Infinity};
    for (const p of parts) {
      for (const v of p.footprint) { bounds.minX = Math.min(bounds.minX, v.x); bounds.maxX = Math.max(bounds.maxX, v.x); bounds.minY = Math.min(bounds.minY, v.y); bounds.maxY = Math.max(bounds.maxY, v.y); }
      bounds.low = Math.min(bounds.low, p.elevation); bounds.high = Math.max(bounds.high, p.elevation + p.height);
    }
    const center = {x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2, z: (bounds.low + bounds.high) / 2};
    const radius = Math.max(Math.hypot(bounds.maxX - center.x, bounds.maxY - center.y, bounds.high - center.z), 0.001);
    let yaw = 45, pitch = 35, zoom = 1;
    const shapes = parts.map(part => {
      const group = svgElement('g', {'data-spatial-kind': part.kind});
      const tooltip = svgElement('title'); tooltip.textContent = `${part.label} · ${kinds[part.kind].label}\n높이 ${part.height} m · 기준면 ${part.elevation} m\n${part.source}\n${part.note}`;
      const line = {fill: 'none', stroke: kinds[part.kind].color, 'stroke-width': 1.5, 'vector-effect': 'non-scaling-stroke', 'stroke-linejoin': 'round'};
      const bottom = svgElement('path', {...line, 'stroke-opacity': 0.4, 'stroke-dasharray': '4 3'});
      const vertical = svgElement('path', {...line, 'stroke-opacity': 0.6});
      const top = svgElement('path', {...line, fill: kinds[part.kind].color, 'fill-opacity': 0.07});
      group.append(tooltip, bottom, vertical, top); svg.append(group); return {part, bottom, vertical, top};
    });
    const controls = element('div'); Object.assign(controls.style, {display: 'flex', flexWrap: 'wrap', gap: '10px', alignItems: 'center'}); panel.append(controls);
    function slider(label, max, value, change) {
      const wrapper = element('label', label + ' '), input = element('input'); input.type = 'range'; input.min = '0'; input.max = String(max); input.step = '1'; input.value = String(value);
      input.setAttribute('aria-label', label); input.style.width = '110px'; input.style.verticalAlign = 'middle';
      input.addEventListener('input', () => { change(Number(input.value)); draw(); }); wrapper.append(input); controls.append(wrapper); return input;
    }
    const yawInput = slider('회전', 360, yaw, value => { yaw = value; });
    const pitchInput = slider('내려다보기', 90, pitch, value => { pitch = value; });
    function button(label, action) { const b = element('button', label); b.type = 'button'; b.addEventListener('click', () => { action(); draw(); }); controls.append(b); return b; }
    button('위에서', () => { pitch = 90; pitchInput.value = '90'; });
    const smaller = button('−', () => { zoom = Math.max(0.5, zoom / 1.25); }); smaller.setAttribute('aria-label', '형상 축소');
    const larger = button('+', () => { zoom = Math.min(2.5, zoom * 1.25); }); larger.setAttribute('aria-label', '형상 확대');
    button('시점 초기화', () => { yaw = 45; pitch = 35; zoom = 1; yawInput.value = '45'; pitchInput.value = '35'; });
    message(`단위 m · ${parts.length}/${asset.parts.length}개 형상 표시 · 윤곽선은 가려진 변도 표시합니다. 실측은 출처의 분류입니다.`);
    function draw() {
      const angle = yaw * Math.PI / 180, tilt = pitch * Math.PI / 180, scale = 180 / radius * zoom;
      const project = (p, z) => {
        const dx = p.x - center.x, dy = p.y - center.y;
        const horizontal = dx * Math.cos(angle) - dy * Math.sin(angle), depth = dx * Math.sin(angle) + dy * Math.cos(angle);
        return [(360 + horizontal * scale).toFixed(3), (210 + (depth * Math.sin(tilt) - (z - center.z) * Math.cos(tilt)) * scale).toFixed(3)].join(' ');
      };
      for (const {part, bottom, vertical, top} of shapes) {
        const low = part.footprint.map(p => project(p, part.elevation)), high = part.footprint.map(p => project(p, part.elevation + part.height));
        bottom.setAttribute('d', 'M' + low.join('L') + 'Z'); top.setAttribute('d', 'M' + high.join('L') + 'Z');
        vertical.setAttribute('d', low.map((p, i) => 'M' + p + 'L' + high[i]).join(''));
      }
      smaller.disabled = zoom <= 0.5; larger.disabled = zoom >= 2.5;
    }
    draw(); return result;
  }
  globalThis.SpatialPreview = Object.freeze({mount});
})();
