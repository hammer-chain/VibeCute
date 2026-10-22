import net from 'node:net';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
export const name = 'vibecute-approval-bridge';
export const inject = ['approval'];
export async function apply(ctx, config = {}) {
  const socketPath = config.socketPath ?? path.join(os.homedir(), '.dsh/vibecute/approval.sock');
  const directory = path.dirname(socketPath);
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await fs.lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) throw Error('Unsafe bridge directory');
  await fs.chmod(directory, 0o700);
  let previous;
  try { previous = await fs.lstat(socketPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (previous) {
    if (!previous.isSocket() || previous.uid !== process.getuid()) throw Error('Unsafe existing bridge socket');
    const alive = await new Promise((resolve, reject) => {
      const probe = net.connect(socketPath);
      probe.setTimeout(1000, () => { probe.destroy(); reject(Error('Bridge probe timed out')); });
      probe.once('connect', () => { probe.destroy(); resolve(true); });
      probe.once('error', error => error.code === 'ECONNREFUSED' ? resolve(false) : reject(error));
    });
    if (alive) throw Error('Another DSH bridge is already running');
    let current;
    try { current = await fs.lstat(socketPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (current) {
      if (current.ino !== previous.ino) throw Error('Bridge socket changed');
      await fs.unlink(socketPath);
    }
  }
  const pending = new Map(), requests = new WeakMap(), clients = new Set();
  const key = (sessionID, id) => JSON.stringify([sessionID, id]);
  const frame = value => { const body = Buffer.from(JSON.stringify(value)); const size = Buffer.alloc(4); size.writeUInt32LE(body.length); return Buffer.concat([size, body]); };
  const remoteQuestion = async input => {
    const gateway = ctx.get?.('typertGateway');
    if (typeof input.sessionID !== 'string' || !/^session-[0-9a-f-]{36}$/i.test(input.sessionID)
        || typeof input.id !== 'string' || !input.id || !gateway?.hasLiveClient?.()) return { status: 'unavailable' };
    // Older desktop cards omit callId. Bind them to the exact currently unresolved
    // ask_user_question in the owning live root's authoritative Session log.
    const root = ctx.get?.('agents')?.roots?.().find(agent => agent.session.id === input.sessionID);
    let legacyCall;
    if (root) {
      const settled = new Set();
      for (let seq = root.session.seq - 1; seq >= 0 && seq >= root.session.seq - 512; seq--) {
        const event = root.session.eventAt(seq);
        if (event?.type === 'tool/result') {
          const message = event.data.message;
          settled.add(message?.toolCallId ?? message?.source?.callId);
        }
        if (event?.type === 'tool/call' && event.data.name === 'ask_user_question' && !settled.has(event.data.callId)) {
          if (event.data.callId === input.id) {
            try { legacyCall = JSON.parse(event.data.arguments).questions; } catch {}
          }
          break;
        }
      }
    }
    const controller = new AbortController(), subject = {};
    const timer = setTimeout(() => controller.abort(), 2500);
    try {
      return await new Promise(resolve => gateway.startRemoteEvent({
        event: 'vibecute/question', request: { ...input, legacyQuestions:legacyCall ?? null, agent:subject, signal:controller.signal },
        context: { value:ctx, subject, agentId:input.sessionID },
        resolve: result => resolve(result.kind === 'result' && result.value?.id === input.id
          ? result.value : { status:'unavailable' }),
        reject: () => resolve({ status:'uncertain' })
      }));
    } finally { clearTimeout(timer); }
  };
  // Explicit settings-page check only; no sessions, answers or approvals are touched.
  const bridgeStatus = async () => {
    const gateway = ctx.get?.('typertGateway');
    if (!gateway?.hasLiveClient?.()) return {status:'disconnected', revision:config.revision};
    const controller = new AbortController(), subject = {};
    const timer = setTimeout(() => controller.abort(), 2500);
    try {
      return await new Promise(resolve => gateway.startRemoteEvent({
        event:'vibecute/status', request:{agent:subject, signal:controller.signal},
        context:{value:ctx, subject, agentId:'vibecute-bridge-status'},
        resolve:result => resolve({status:result.kind === 'result' && result.value?.clientVersion === 'v11' ? 'ok' : 'disconnected',
          revision:config.revision, clientVersion:result.value?.clientVersion ?? null}),
        reject:() => resolve({status:'disconnected', revision:config.revision})
      }));
    } finally { clearTimeout(timer); }
  };
  const navigate = async sessionID => {
    const gateway = ctx.get?.('typertGateway');
    if (typeof sessionID !== 'string' || !/^session-[0-9a-f-]{36}$/i.test(sessionID)
        || !gateway?.hasLiveClient?.()) return { status: 'unavailable' };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 2500);
    const subject = {};
    try {
      return await new Promise(resolve => {
        gateway.startRemoteEvent({
          event: 'vibecute/navigate',
          request: { agent: subject, sessionID, signal: controller.signal },
          context: { value: ctx, subject, agentId: sessionID },
          resolve: result => resolve(result.kind === 'result' && result.value?.opened === true
            && result.value.sessionID === sessionID ? { status: 'ok', sessionID } : { status: 'unavailable' }),
          reject: () => resolve({ status: 'unavailable' })
        });
      });
    } finally { clearTimeout(timer); }
  };
  const server = net.createServer(socket => {
    if (clients.size >= 8) { socket.destroy(); return; }
    clients.add(socket); socket.on('close', () => clients.delete(socket)); socket.on('error', () => {});
    socket.setTimeout(5000, () => socket.destroy());
    let buffer = Buffer.alloc(0), handled = false;
    socket.on('data', async bytes => {
      if (handled) return;
      buffer = Buffer.concat([buffer, bytes]);
      if (buffer.length > 65540) { socket.destroy(); return; }
      if (buffer.length < 4) return;
      const size = buffer.readUInt32LE();
      if (!size || size > 65536) { socket.destroy(); return; }
      if (buffer.length < size + 4) return;
      handled = true;
      let reply = { status: 'stale' };
      try {
        const input = JSON.parse(buffer.subarray(4, size + 4));
        const record = pending.get(key(input.sessionID, input.id));
        if (input.version !== 1) reply = { status: 'incompatible' };
        else if (input.operation === 'bridge-status') reply = await bridgeStatus();
        else if (input.operation === 'navigate') reply = await navigate(input.sessionID);
        else if (['question-status','question-answer'].includes(input.operation)) reply = await remoteQuestion(input);
        else if (record && !record.claimed && !record.signal?.aborted && record.reason === input.reason && record.toolName === input.toolName
            && ['allowed-once', 'rejected'].includes(input.outcome)) {
          record.claimed = true;
          record.resolve(input.outcome);
          reply = await record.confirm;
        }
      } catch { reply = { status: 'uncertain' }; }
      if (!socket.destroyed) socket.end(frame(reply));
    });
  });
  // Never unlink another running host's socket.
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  await fs.chmod(socketPath, 0o600);
  const exposed = ctx.approval;
  const service = exposed[Symbol.for("cordis.original")] ?? exposed;
  const original = service.request;
  const wrapped = async function(req) {
    const controller = new AbortController();
    const onAbort = () => controller.abort(req.signal?.reason);
    req.signal?.addEventListener('abort', onAbort, { once: true });
    if (req.signal?.aborted) onAbort();
    const borrowed = { ...req, signal: controller.signal };
    const record = { seq: req.agent.session.seq, session: req.agent.session, controller };
    requests.set(borrowed, record);
    try {
      const outcome = await original.call(this, borrowed);
      const audit = record.session.eventAt(record.seq + 1);
      // Other events may interleave; locate only this exact audit ID.
      let confirmed = audit?.type === 'approval/decided' && audit.data.id === record.id && audit.data.outcome === outcome;
      for (let seq = record.session.seq - 1; !confirmed && seq >= record.seq && seq >= record.session.seq - 128; seq--) {
        const event = record.session.eventAt(seq);
        confirmed = event?.type === 'approval/decided' && event.data.id === record.id && event.data.outcome === outcome;
      }
      record.ack?.({ status: confirmed ? 'ok' : 'uncertain', outcome });
      return outcome;
    } catch (error) { record.ack?.({ status: 'uncertain' }); throw error; }
    finally {
      if (record.id) pending.delete(key(record.session.id, record.id));
      // Cancel the still-mounted DSH UI only after its authoritative service has committed.
      controller.abort(); req.signal?.removeEventListener('abort', onAbort);
    }
  };
  service.request = wrapped;
  ctx.on('approval/request', (req, next) => {
    const record = requests.get(req), event = record?.session.eventAt(record.seq);
    if (!record || event?.type !== 'approval/asked' || pending.size >= 64) return next();
    record.id = event.data.id;
    record.reason = req.reason ?? '';
    record.toolName = req.toolName;
    record.signal = req.signal;
    const answer = new Promise(resolve => { record.resolve = resolve; });
    record.confirm = new Promise(resolve => { record.ack = resolve; });
    pending.set(key(record.session.id, record.id), record);
    return Promise.race([Promise.resolve().then(next), answer]);
  }, { prepend: true });
  ctx.effect(() => () => {
    if (service.request === wrapped) service.request = original;
    for (const record of pending.values()) { record.ack?.({ status: 'uncertain' }); record.controller.abort(); }
    for (const socket of clients) socket.destroy();
    server.close(() => fs.unlink(socketPath).catch(() => {}));
  });
}
