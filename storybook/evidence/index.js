// 공개면: Evidence.Panel + Presence / Links / Grid / Preview / ServerMeta.
// OCR 스티치(증거)도 Evidence.mount 를 쓴다. 덮어쓰지 않고 붙인다.
import {OFFICIAL, AUX, LINK, HOST, gradeOf, hostLabel, itemLabel, collectedAt, timeShort, timeFull, timeCol, linkState, linkLabel} from './kernel.js';
import {PREVIEW, kind as previewKind, copy as previewCopy} from './preview-kind.js';
import {Presence} from './presence.js';
import {Links} from './links.js';
import {Grid, thumbFilled, timesOf, hostsOf} from './grid.js';
import {Preview} from './preview.js';
import {ServerMeta} from './server-meta.js';
import {Panel} from './panel.js';

export const Evidence = {
  OFFICIAL, AUX, LINK, HOST, PREVIEW,
  gradeOf, hostLabel, itemLabel, collectedAt, timeShort, timeFull, timeCol,
  linkState, linkLabel, previewKind, previewCopy,
  thumbFilled, timesOf, hostsOf,
  Presence, Links, Grid, Preview, ServerMeta, Panel,
};

globalThis.Evidence = Object.assign(globalThis.Evidence || {}, Evidence);
