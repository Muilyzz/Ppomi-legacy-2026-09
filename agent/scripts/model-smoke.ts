// Explicit live smoke: synthetic fixture only. No microphone, playback or transcript logs.
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {RealtimeAgent,RealtimeSession,setSensitiveDataLoggingEnabled,tool} from '@openai/agents/realtime';
import {z} from 'zod';
setSensitiveDataLoggingEnabled(false);
const root=new URL('../../',import.meta.url);
const c=JSON.parse(readFileSync(new URL('.ppomi/ssot/mac.json',root),'utf8'));
const login=await fetch(c.url+'/auth/v1/token?grant_type=password',{method:'POST',redirect:'error',headers:{apikey:c.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({email:c.email,password:c.password})});
if(!login.ok)throw new Error('device authentication failed');
const token=(await login.json()).access_token;
async function request(path:string,body:object={}){
 const response=await fetch('https://ppomi-agent.vercel.app'+path,{method:'POST',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(body)});
 if(!response.ok)throw new Error('agent request status '+response.status);
 return response.json();
}
const id=randomUUID();let saved=false;let audioBytes=0;let toolCount=0;let finish!:()=>void;let fail!:(reason:Error)=>void;
const finished=new Promise<void>((resolve,reject)=>{finish=resolve;fail=reject;});
// Read only the literal common policy; do not evaluate source or load any user record.
const source=readFileSync(new URL('../src/voice.ts',import.meta.url),'utf8');
const instructions=source.match(/const instructions = `([\s\S]*?)`;/)?.[1];
if(!instructions)throw new Error('common voice policy not found');
const agent=new RealtimeAgent({name:'뽀미 검증',instructions:instructions+'\n이 세션은 합성 테스트다. 기록 본문은 반드시 [자동 검증용 가상 기록]으로 시작하고 source=ai_inferred로 표시한다. 실제 사용자 정보로 취급하지 않는다.',tools:[tool({name:'save_memory',description:'중요한 한 가지 할 일을 저장한다.',parameters:z.object({kind:z.enum(['fact','preference','decision','todo','result']),text:z.string().max(2000),source:z.enum(['user_reported','tool_observed','ai_inferred']),confidence:z.number().min(0).max(1)}),execute:async args=>{if(!args.text.startsWith('[자동 검증용 가상 기록]')||args.source!=='ai_inferred')throw new Error('fixture boundary');const r=await request('/v1/memories/save',{...args,id});saved=true;toolCount++;return r;}})]});
const credentials=await request('/v1/session');
const session=new RealtimeSession(agent,{transport:'websocket',model:credentials.model,tracingDisabled:true,historyStoreAudio:false,config:{audio:{input:{transcription:null},output:{voice:'marin'}}}});
session.on('error',()=>fail(new Error('realtime session error')));
session.on('audio',event=>{audioBytes+=event.data.byteLength;if(saved&&audioBytes>0)finish();});
session.on('agent_tool_end',()=>{if(saved&&audioBytes>0)finish();});
const timer=setTimeout(()=>fail(new Error('model smoke timeout')),45000);
try{
 await session.connect({apiKey:credentials.clientSecret});credentials.clientSecret='';
 session.sendMessage('자동 검증용 가상 시나리오야. 내일 가상 프로젝트의 파란색 버튼 시안을 검토하기로 결정했어. 할 일로 기억해 둬. 저장하고 짧게 말해 줘.');
 await finished;
 const result=await request('/v1/memories/list');
 if(!result.records.some((r:{id:string})=>r.id===id))throw new Error('model tool save unverified');
 console.log(JSON.stringify({model:'gpt-realtime-2.1',toolCalls:toolCount,audioResponse:audioBytes>0,persistedThroughTool:true,synthetic:true}));
 writeFileSync(new URL('.ppomi/agent/model-proof.json',root),JSON.stringify({checkedAt:new Date().toISOString(),toolCalls:toolCount,audioResponse:audioBytes>0,synthetic:true})+'\n',{mode:0o600});
}finally{
 clearTimeout(timer);session.removeAllListeners();session.close();session.history.splice(0);session.context.context.history.splice(0);
 if(saved)await request('/v1/memories/delete',{id});
}
