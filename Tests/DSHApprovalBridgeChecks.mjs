import assert from 'node:assert/strict';
import net from 'node:net';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { apply } from '../Integrations/DSHApprovalBridge/index.mjs';
const modulePath = process.env.DSH_APPROVAL_SERVICE_MODULE;
const real = modulePath ? (await import(modulePath)).ApprovalService.prototype : null;
const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'vc-dsh-'));
const socketPath = path.join(folder, 'bridge.sock');
const cleanups = []; let listener, uiAnswer;
const ctx = {
  on(name, fn) { assert.equal(name, 'approval/request'); listener = fn; },
  effect(fn) { cleanups.push(fn()); },
  waterfall(_scope, _name, req) {
    return listener(req, () => new Promise(resolve => {
      uiAnswer = resolve;
      req.signal.addEventListener('abort', () => resolve('cancelled'), { once: true });
    }));
  }
};
ctx.approval = { ctx, effectivePolicy: () => 'ask',
  decide: real?.decide ?? (async function(req) {
    return Promise.race([this.ctx.waterfall(null, 'approval/request', req), new Promise(resolve => req.signal.addEventListener('abort', () => resolve('cancelled'), { once: true }))]);
  }),
  request: real?.request ?? (async function(req) {
    const id = 'request-' + req.agent.session.seq;
    req.agent.session.append('approval/asked', { id, toolName: req.toolName, reason: req.reason });
    const outcome = await this.decide(req, req.agent.session);
    req.agent.session.append('approval/decided', { id, outcome }); return outcome;
  })
};
await apply(ctx, { socketPath, revision:'fixture-revision' });
function exchange(input) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath); let data = Buffer.alloc(0);
    socket.on('error', reject); socket.on('connect', () => {
      const body = Buffer.from(JSON.stringify(input)), header = Buffer.alloc(4); header.writeUInt32LE(body.length);
      socket.write(Buffer.concat([header, body]));
    });
    socket.on('data', chunk => { data = Buffer.concat([data, chunk]); if (data.length >= 4 && data.length >= 4 + data.readUInt32LE()) resolve(JSON.parse(data.subarray(4))); });
  });
}
function ask() {
  const events = [{ type: 'turn/start', data: {} }];
  const session = { id: 'test-session', get seq() { return events.length; }, eventAt: i => events[i], append: (type, data) => events.push({ type, data }) };
  const req = { agent: { session }, toolName: 'bash', reason: 'test permission', signal: new AbortController().signal };
  const result = ctx.approval.request(req);
  return { session, events, result };
}
async function pending() { await new Promise(resolve => setImmediate(resolve)); }
for (const outcome of ['allowed-once', 'rejected']) {
  const request = ask(); await pending();
  const id = request.events.find(e => e.type === 'approval/asked').data.id;
  const input = { version: 1, sessionID: 'test-session', id, toolName: 'bash', reason: 'test permission', outcome };
  assert.equal((await exchange({ ...input, sessionID: 'wrong-session' })).status, 'stale');
  assert.equal((await exchange({ ...input, reason: 'changed' })).status, 'stale');
  const native = process.env.DSH_SWIFT_CHECK;
  const response = native ? await promisify(execFile)(native, [socketPath, id, outcome]).then(() => ({ status: 'ok', outcome })) : await exchange(input);
  assert.deepEqual(response, { status: 'ok', outcome });
  assert.equal(await request.result, outcome);
  assert.equal(request.events.at(-1).data.outcome, outcome);
  assert.equal((await exchange(input)).status, 'stale');
}
const fromUI = ask(); await pending();
uiAnswer('rejected');
assert.equal(await fromUI.result, 'rejected', 'DSH native UI remains functional without a bridge client');
assert.equal((await fs.stat(socketPath)).mode & 0o777, 0o600);
let live = false, clientVersion = 'v11';
ctx.get = name => name === 'typertGateway' ? {
  hasLiveClient: () => live,
  startRemoteEvent: ({event,request,context,resolve}) => {
    assert.equal(context.agentId,'vibecute-bridge-status');
    assert.equal(event,'vibecute/status');
    assert.equal(request.sessionID,undefined,'Health checks never navigate or access a session');
    resolve({kind:'result',value:{clientVersion}});
  }
} : undefined;
assert.equal((await exchange({version:1,operation:'bridge-status'})).status,'disconnected');
live=true;
assert.deepEqual(await exchange({version:1,operation:'bridge-status'}),{
  status:'ok',revision:'fixture-revision',clientVersion:'v11'});
clientVersion='v9';
assert.equal((await exchange({version:1,operation:'bridge-status'})).status,'disconnected');
for (const cleanup of cleanups.reverse()) cleanup();
await new Promise(resolve => setTimeout(resolve, 50));
await fs.rm(folder, { recursive: true, force: true });
console.log(`PASS: DSH bridge allow/reject, durable acknowledgment, exact request/content binding, duplicate rejection, private socket${real ? ', installed ApprovalService' : ''}`);
