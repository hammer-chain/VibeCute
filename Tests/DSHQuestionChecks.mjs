import fs from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
let module;
const handlers = new Map();
vm.runInNewContext(await fs.readFile('Integrations/DSHApprovalBridge/client.js','utf8'), {
  location:{protocol:'dsh-app:',host:'app'},
  window:{__ModuleLoader__:{load(value){module=value.factory();}}}
});
const sessionID='session-11111111-1111-4111-8111-111111111111', id='call_questions';
const questions=[{id:'taxonomy',question:'分类方式',options:[{label:'A',description:'说明'},{label:'B'}]},
  {id:'source',question:'出处字段',options:[{label:'要'},{label:'不要'}]}];
let submissions=0, closed=false;
const card={sessionId:sessionID,callId:id,questions,getSnapshot:()=>({closed,channel:'waterfall'}),
  async answer(batch){submissions++;assert.equal(batch.answers.length,2);closed=true;}};
const ctx={remote:{$on:(event,fn)=>handlers.set(event,fn)},uiSession:{pendingSnapshot:new Map([[sessionID,card]])}};
module.apply(ctx);
const handler=handlers.get('vibecute/question');
const base={sessionID,id,operation:'question-status'};
assert.equal((await handler(base)).questions.length,2);
assert.equal(submissions,0,'Status never answers a real question');
const input={...base,operation:'question-answer',questions:questions.map(q=>({...q,options:q.options.map(o=>({...o,description:o.description??''}))})),
  answers:[{id:'taxonomy',selected:['B']},{id:'source',selected:['要']}]};
assert.equal((await handler({...input,sessionID:'session-22222222-2222-4222-8222-222222222222'})).status,'stale');
assert.equal((await handler({...input,id:'other-call'})).status,'stale');
assert.equal((await handler({...input,answers:[input.answers[0]]})).status,'stale');
assert.equal((await handler({...input,answers:[input.answers[0],input.answers[0]]})).status,'stale');
assert.equal((await handler({...input,questions:[{...input.questions[0],question:'changed'},input.questions[1]]})).status,'stale');
assert.equal((await handler({...input,answers:[{id:'taxonomy',selected:['bad']},input.answers[1]]})).status,'stale');
assert.equal(submissions,0);
card.callId=undefined;
assert.equal((await handler(input)).status,'stale','Legacy card requires host log proof');
input.legacyQuestions=questions;
assert.equal((await handler(input)).status,'ok');
assert.equal(submissions,1);
assert.equal((await handler(input)).status,'stale');
assert.equal(submissions,1,'A closed card cannot be submitted twice');

// DSH multi-select answers retain the native answer-channel shape while
// rejecting duplicates, unknown labels, and multiple choices on single-select questions.
closed=false;
const multiQuestions=[{id:'tags',question:'需要哪些标签',multiSelect:true,options:[{label:'A',description:''},{label:'B',description:''}]},
  {id:'format',question:'格式',multiSelect:false,options:[{label:'短',description:''},{label:'长',description:''}]}];
const multiCard={sessionId:sessionID,callId:id,questions:multiQuestions,getSnapshot:()=>({closed,channel:'waterfall'}),
  async answer(batch){submissions++;assert.equal(batch.answers.length,2);closed=true;}};
ctx.uiSession.pendingSnapshot.set(sessionID,multiCard);
const multiInput={...base,operation:'question-answer',questions:multiQuestions,answers:[
  {id:'tags',selected:['A','B']},{id:'format',selected:['短']}]};
assert.equal((await handler({...multiInput,answers:[{id:'tags',selected:['A','A']},multiInput.answers[1]]})).status,'stale');
assert.equal((await handler({...multiInput,answers:[multiInput.answers[0],{id:'format',selected:['短','长']}]})).status,'stale');
assert.equal((await handler({...multiInput,questions:[{...multiQuestions[0],multiSelect:false},multiQuestions[1]]})).status,'stale');
assert.equal(submissions,1);
assert.equal((await handler(multiInput)).status,'ok');
assert.equal(submissions,2);
assert.equal((await handler(multiInput)).status,'stale');
console.log('PASS: two-question batch, existing live card, exact identities/content/options, no read side effects, stale and duplicate rejection');
