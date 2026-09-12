// 공개면: Evidence.Panel + Presence / Links / Grid / Preview / ServerMeta.
// globalThis.Evidence 는 OCR 스티치(증거)가 쓴다. 잠금 면은 EvidenceFleet.
import {OFFICIAL, AUX, LINK, HOST, gradeOf, hostLabel, itemLabel, collectedAt, timeShort, timeFull, timeCol, linkState, linkLabel} from './kernel.js';
import {PREVIEW, kind as previewKind, copy as previewCopy} from './preview-kind.js';
import {Presence} from './presence.js';
import {Links} from './links.js';
import {Grid, thumbFilled, timesOf, hostsOf} from './grid.js';
import {Preview} from './preview.js';
import {ServerMeta} from './server-meta.js';
import {Panel} from './panel.js';

export const EvidenceFleet = {
  OFFICIAL, AUX, LINK, HOST, PREVIEW,
  gradeOf, hostLabel, itemLabel, collectedAt, timeShort, timeFull, timeCol,
  linkState, linkLabel, previewKind, previewCopy,
  thumbFilled, timesOf, hostsOf,
  Presence, Links, Grid, Preview, ServerMeta, Panel,
};

globalThis.EvidenceFleet = EvidenceFleet;
