import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
const endpoint='https://ppomi-agent.vercel.app';
const root=new URL('../../',import.meta.url);
const config=name=>JSON.parse(readFileSync(new URL(`.ppomi/ssot/${name}.json`,root),'utf8'));
async function login(c){const r=await fetch(c.url+'/auth/v1/token?grant_type=password',{method:'POST',redirect:'error',headers:{apikey:c.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({email:c.email,password:c.password})});if(!r.ok)throw new Error('Device login failed '+r.status);return(await r.json()).access_token;}
const mac=config('mac'),fold=config('fold');
const token=await login(mac),other=await login(fold);
async function call(path,body={},auth=token){const r=await fetch(endpoint+path,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+auth,'Content-Type':'application/json'},body:JSON.stringify(body)});const json=await r.json();if(!r.ok){const e=new Error('Agent request failed '+r.status+' '+(json.error?.code??''));e.status=r.status;throw e;}return json;}
const check=(yes,label)=>{if(!yes)throw new Error('Verification failed: '+label);console.log('PASS '+label);};
const id=randomUUID();let saved=false;
try{
 const secret=await call('/v1/session');check(secret.clientSecret.startsWith('ek_')&&secret.model==='gpt-realtime-2.1','authenticated ephemeral voice credential');secret.clientSecret='';
 const input={id,kind:'result',text:'[자동 검증용 가상 기록] 음성 서버의 저장·조회 연결 검사.',source:'tool_observed',confidence:1};
 const first=(await call('/v1/memories/save',input)).record;saved=true;
 check(first.id===id&&first.text===input.text&&first.source===input.source,'encrypted record save and source preservation');
 const retry=(await call('/v1/memories/save',input)).record;
 check(first.createdAt===retry.createdAt,'same operation is idempotent');
 let conflict=false;try{await call('/v1/memories/save',{...input,text:'changed'});}catch(e){conflict=e.status===409;}check(conflict,'different input cannot reuse operation ID');
 const listed=await call('/v1/memories/list',{},other);check(listed.records.some(r=>r.id===id&&r.text===input.text),'Fold identity reads same server record');
 await call('/v1/memories/delete',{id});saved=false;
 const after=await call('/v1/memories/list');check(!after.records.some(r=>r.id===id),'deleted record absent');
 let removedConflict=false;try{await call('/v1/memories/save',input);}catch(e){removedConflict=e.status===409;}check(removedConflict,'deleted operation cannot be replayed');
 writeFileSync(new URL('.ppomi/agent/smoke-proof.json',root),JSON.stringify({endpoint,checkedAt:new Date().toISOString(),passed:7,testRecordId:id,removed:true})+'\n',{mode:0o600});
}finally{if(saved)await call('/v1/memories/delete',{id});}
