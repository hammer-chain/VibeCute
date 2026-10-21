import fs from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
let module, handler, opened;
vm.runInNewContext(await fs.readFile('Integrations/DSHApprovalBridge/client.js', 'utf8'), {
  location: { protocol: 'dsh-app:', host: 'app' },
  window: { __ModuleLoader__: { load(value) { module = value.factory(); } } }
});
const first = 'session-11111111-1111-4111-8111-111111111111';
const second = 'session-22222222-2222-4222-8222-222222222222';
const ctx = {
  remote: { $on(event, fn) { if (event === 'vibecute/navigate') handler = fn; } },
  sessions: { list: { getSnapshot: () => ({ byId: { [first]: { title: 'Same title' }, [second]: { title: 'Same title' } } }) } },
  uiWorkspace: { openSession(id) { opened = id; this.mainReference = { sessionId: id }; } }
};
module.apply(ctx);
assert.equal(handler({ sessionID: first }).opened, true);
assert.equal(opened, first);
assert.equal(handler({ sessionID: second }).opened, true);
assert.equal(opened, second);
assert.equal(handler({ sessionID: 'session-33333333-3333-4333-8333-333333333333' }).opened, false);
assert.equal(opened, second);
ctx.uiWorkspace.openSession = () => {};
assert.equal(handler({ sessionID: first }).opened, false, 'A requested navigation is not success until the selected identity matches');
console.log('PASS: exact DSH session IDs, same-title conversations, missing session and selected-ID readback');
