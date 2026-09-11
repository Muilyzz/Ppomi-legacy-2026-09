import { createAuth } from './auth.js';
import { createRecordClient, createDeviceStore } from './records.js';
import { createRecordSession } from './record-session.js';
import { renderRecords, clearRecords, showRecordMessage } from './record-views.js';
import { timelineProjection } from './timeline-projection.js';

const el = id => document.getElementById(id);
const status = el('auth-status'), signIn = el('sign-in'), signOut = el('sign-out');
const tabs = [...document.querySelectorAll('[data-record-view]')];
const names = {timeline:'타임라인',evidence:'증빙·전표',accounting:'분개장',playbooks:'플레이북',health:'건강',spatial:'건축물 3D'};
const deviceStore = createDeviceStore();
let auth, busy = false, restoreQueued = false, selected = 'timeline';

function showStatus(message = '', error = false) { status.textContent = message; status.dataset.state = error ? 'error' : 'normal'; }
function showUser(user) {
  el('user-name').textContent = user?.name || (user ? '내 계정' : '');
  el('user-email').textContent = user?.email || '';
  el('app-shell').hidden = !user; el('sign-in-panel').hidden = Boolean(user);
}
const errors = {
  storage:'브라우저 저장 공간을 사용할 수 없어요. Safari 설정을 확인한 뒤 다시 열어 주세요.',
  connection:'연결을 확인하지 못했어요. 인터넷에 연결한 뒤 다시 시도해 주세요.',
  authentication:'로그인을 다시 확인해 주세요. Google 로그인 버튼으로 시작할 수 있어요.',
  unavailable:'로그인은 ppomi.muilyzz.com에서 시작해 주세요.',
  cleanup:'계정 전환을 마치지 못했어요. 이 창을 닫고 다시 열어 주세요.',
  unsupported:'이 브라우저는 기록을 여는 암호화 기능을 지원하지 않아요. 최신 Safari 또는 Chrome에서 열어 주세요.',
  permission:'이 기기의 기록 접근을 확인하지 못했어요. 같은 계정의 Mac에서 기록 연결 상태를 확인해 주세요.',
  invalid:'기록의 암호화 또는 형식을 확인하지 못했어요. Mac의 공유 상태를 확인한 뒤 다시 시도해 주세요.',
  oversized:'이 기록은 브라우저에서 열 수 있는 크기를 넘었어요. Mac 앱에서 확인해 주세요.',
  render:'기록 화면을 열지 못했어요. 새로고침한 뒤 다시 시도해 주세요.',
};
// This adapter knows labels, DOM and renderers. The session knows only record
// names and public connection state; it never depends on this layout.
function showRecordState(state) {
  el('refresh-records').disabled = state.status === 'idle' || state.busy;
  if (state.status === 'idle') {
    for (const id of ['workspace-status','device-status','sync-status','record-status','record-version']) el(id).textContent = '';
    return;
  }
  if (state.connection) {
    el('workspace-status').textContent = state.connection.workspace.name;
    el('device-status').textContent = '웹 브라우저 · 읽기';
  }
  if (state.status === 'connecting') {
    el('workspace-status').textContent = 'Google 로그인 완료'; el('device-status').textContent = '기기 확인 중';
    el('sync-status').textContent = '공유된 기록에 연결하고 있습니다.';
    showRecordMessage('기록을 연결하고 있습니다', '처음 연결할 때는 Mac이 켜져 있어야 합니다.');
  } else if (state.status === 'waiting-key') {
    el('sync-status').textContent = 'Mac이 이 브라우저에 기록 키를 연결하기를 기다리고 있어요.';
    el('record-status').textContent = '기록 키 연결 대기';
    showRecordMessage('사용 중인 Mac에서 뽀미를 열어 주세요', '같은 Google 계정으로 로그인된 Mac이 켜져 있으면 기록이 연결됩니다. 연결이 끝나면 이 화면에 자동으로 표시됩니다.', {link:true});
  } else if (state.status === 'reading') {
    el('record-status').textContent = '최신 기록을 확인하고 있습니다.'; el('record-version').textContent = '';
  } else if (state.status === 'ready' && state.record) {
    const updated = state.record.updatedAt && new Date(state.record.updatedAt);
    el('record-status').textContent = updated && Number.isFinite(+updated) ? `Mac에서 공유 · ${updated.toLocaleString('ko-KR')}` : '공유된 기록';
    el('record-version').textContent = `버전 ${state.record.version}`;
    el('sync-status').textContent = '기록 연결됨 · 보고 있는 기록을 자동으로 확인합니다.';
  } else if (state.status === 'missing') {
    showRecordMessage('아직 공유되지 않은 기록입니다', state.error?.code === 'unshared'
      ? 'Mac의 뽀미에서 이 기록을 공유하면 여기에 표시됩니다.' : 'Mac에서 기록을 공유하면 이곳에 표시됩니다.');
    el('record-status').textContent = '공유된 기록 없음';
  } else if (state.status === 'error') {
    if (state.error.phase === 'connect') {
      el('sync-status').textContent = errors[state.error.code] || errors.invalid;
      el('record-status').textContent = '기록 연결 확인 필요';
      showRecordMessage('기록 연결을 확인해 주세요', errors[state.error.code] || errors.invalid);
    } else {
      showRecordMessage('기록을 열지 못했습니다', errors[state.error.code] || errors.render);
      el('record-status').textContent = '다시 시도할 수 있습니다.';
    }
  }
}
const recordSession = createRecordSession({
  createClient: user => createRecordClient({auth, user, deviceStore}),
  clearKey: owner => deviceStore.clear(owner),
  clearPresentation: clearRecords,
  hasPresentation: () => Boolean(el('main-content').querySelector('iframe')),
  present: (recordName, record, {signal}) => {
    const name = recordName === 'ledger' ? 'timeline' : recordName;
    const payload = name === 'timeline' ? {data:timelineProjection(record.json)} : {data:record.json ?? record.text};
    return renderRecords(name, payload, {signal});
  },
  onState: showRecordState,
  visible: !document.hidden,
  setTimeout, clearTimeout,
});
async function restore() {
  if (busy) return;
  busy = true; signIn.disabled = true; recordSession.stop(); showUser(null); showStatus('로그인 상태를 확인하고 있습니다.');
  try { const session = await auth.loadSession(); showUser(session?.user); showStatus(); if(session)recordSession.start(session.user); }
  catch(error) { recordSession.stop(); showUser(null); if(error?.code!=='cancelled')showStatus(errors[error?.code]||errors.authentication,true); }
  finally { busy=false;signIn.disabled=false;if(restoreQueued){restoreQueued=false;queueMicrotask(restore);} }
}
for(const tab of tabs) {
  tab.addEventListener('click',()=>{
    const next=tab.dataset.recordView;if(next===selected)return;
    selected=next;
    for(const button of tabs){const on=button===tab;button.setAttribute('aria-selected',String(on));button.tabIndex=on?0:-1;}
    el('main-content').setAttribute('aria-labelledby',tab.id);el('record-title').textContent=names[next];el('record-version').textContent='';
    recordSession.select(next === 'timeline' ? 'ledger' : next);
  });
  tab.addEventListener('keydown',event=>{
    const index=tabs.indexOf(tab);let next;
    if(['ArrowDown','ArrowRight'].includes(event.key))next=(index+1)%tabs.length;
    else if(['ArrowUp','ArrowLeft'].includes(event.key))next=(index+tabs.length-1)%tabs.length;
    else if(event.key==='Home')next=0;else if(event.key==='End')next=tabs.length-1;
    if(next!==undefined){event.preventDefault();tabs[next].focus();tabs[next].click();}
  });
}
el('refresh-records').addEventListener('click',recordSession.refresh);
document.addEventListener('visibilitychange',()=>recordSession.setVisible(!document.hidden));
window.addEventListener('pagehide',()=>{recordSession.stop();showUser(null);});
try {
  auth=createAuth({
    clearSecrets:async({previousUserId})=>{
      showUser(null); await recordSession.clearPrivate(previousUserId);
    },
    onChange:event=>{
      if(event.type==='signed-out'){recordSession.stop();showUser(null);showStatus();}
      else if(event.type==='session-changed'){if(busy)restoreQueued=true;else queueMicrotask(restore);}
    },
  });
  signIn.addEventListener('click',async()=>{
    if(busy)return;busy=true;signIn.disabled=true;showStatus('Google 로그인으로 이동합니다.');
    try{await auth.signIn();}catch(error){showStatus(errors[error?.code]||errors.authentication,true);busy=false;signIn.disabled=false;}
  });
  signOut.addEventListener('click',async()=>{
    signOut.disabled=true;
    try{await auth.signOut();showStatus('이 브라우저에서 로그아웃했습니다.');}
    catch(error){showStatus(errors[error?.code]||errors.cleanup,true);}finally{signOut.disabled=false;}
  });
  window.addEventListener('pageshow',event=>{if(event.persisted){busy=false;restore();}});
  window.addEventListener('online',restore);restore();
}catch{recordSession.stop();showUser(null);showStatus(errors.storage,true);}
if('serviceWorker'in navigator&&window.isSecureContext)navigator.serviceWorker.register('/service-worker.js',{scope:'/',updateViaCache:'none'}).catch(()=>{});
