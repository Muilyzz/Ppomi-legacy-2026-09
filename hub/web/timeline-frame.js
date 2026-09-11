(() => {
  'use strict';
  const channel = location.hash.slice(1), origin = new URL(location.href).origin;
  if (parent === window || !/^[a-f0-9]{32}$/.test(channel)) { document.body.replaceChildren(); return; }
  const report = stage => parent.postMessage({type:'ppomi-record-frame',channel,stage},origin);
  const node = (tag, value) => { const el=document.createElement(tag); if(value!=null)el.textContent=String(value); return el; };
  const amount = value => (typeof value === 'bigint' || Number.isSafeInteger(value)) ? `${value.toLocaleString('ko-KR')}원` : '미기재';
  const date = value => Number.isFinite(Date.parse(value)) ? new Date(value).toLocaleString('ko-KR') : '시각 미기재';
  function sources(rows, snapshots) {
    const section = document.getElementById('source-transactions'); section.hidden=false;
    section.append(node('h2',snapshots?'잔액 관측 원본':'원본 거래'));
    const wrap=node('div');wrap.className='source-scroll';const table=node('table'),head=node('thead'),tr=node('tr');
    for(const s of ['시각','내용','금액','출처','원본 ID'])tr.append(node('th',s));head.append(tr);table.append(head);
    const body=node('tbody');table.append(body);wrap.append(table);section.append(wrap);let shown=0;
    const more=node('button','더 보기');more.type='button';section.append(more);
    const sorted=rows.slice().sort((a,b)=>String(b.ts).localeCompare(String(a.ts)));
    const next=()=>{ const stop=Math.min(shown+80,sorted.length);while(shown<stop){ const r=sorted[shown++], row=node('tr');
      for(const s of [date(r.ts),snapshots?r.account:[r.merchant,({approval:'승인',cancel:'취소',deposit:'입금',withdrawal:'출금'})[r.kind]].filter(Boolean).join(' · '),amount(snapshots?r.balance:r.amount),r.app,r.uid || '미기재'])row.append(node('td',s));body.append(row);}
      more.hidden=shown===sorted.length;more.textContent=`더 보기 (${shown} / ${sorted.length})`;};more.addEventListener('click',next);next();
    if(!rows.length)section.append(node('p','공유된 원본 기록이 없습니다.'));
  }
  let received=false;
  addEventListener('message',event=>{
    const m=event.data;
    if(received||event.source!==parent||event.origin!==origin||!m||Object.keys(m).length!==4||m.type!=='ppomi-record-render'||m.channel!==channel||m.name!=='timeline')return;
    received=true;
    try {
      const {projection,observedOnly,preciseSourceOnly,snapshots,transactions}=m.data;
      if(projection)window.updateTimeline(projection);else document.querySelector('main').hidden=true;
      if(observedOnly||preciseSourceOnly){const note=document.getElementById('source-note');note.hidden=false;
        note.textContent=preciseSourceOnly?'원본 수량을 정확하게 표시합니다. 이 기록의 합계와 그래프는 Mac에서 확인할 수 있어요.':'Mac이 공유한 잔액 화면과 원본 거래입니다. 거래 흐름을 포함한 전체 타임라인은 Mac 앱을 업데이트하면 함께 표시됩니다.';
        document.getElementById('range-title').closest('section').hidden=true;document.getElementById('panel').hidden=true;
        if(preciseSourceOnly)sources(snapshots,true);sources(transactions,false);
      }
      report('rendered');
    }catch{document.body.replaceChildren(node('p','타임라인 형식을 확인하지 못했습니다.'));report('error');}
  });report('ready');
})();
