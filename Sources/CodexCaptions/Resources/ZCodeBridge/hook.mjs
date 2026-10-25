import net from 'node:net';
import fs from 'node:fs';

// The hook is deliberately inert when VibeCute is absent. Empty stdout hands
// control back to zcode's own confirmation UI.
let raw = '';
for await (const chunk of process.stdin) {
  raw += chunk;
  if (raw.length > 65536) process.exit(0);
}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); }
if (input.hook_event_name !== 'PermissionRequest') process.exit(0);
const socketPath = `/tmp/vibecute-zcode-${process.getuid()}.sock`;
try {
  const info = fs.lstatSync(socketPath);
  if (!info.isSocket() || info.uid !== process.getuid() || (info.mode & 0o777) !== 0o600) process.exit(0);
} catch { process.exit(0); }
const socket = net.connect(socketPath);
let received = '';
const fallback = setTimeout(() => socket.destroy(), 295000);
socket.setEncoding('utf8');
socket.on('connect', () => socket.write(JSON.stringify(input) + '\n'));
socket.on('data', chunk => {
  received += chunk;
  if (received.length > 32768) socket.destroy();
});
socket.on('end', () => {
  clearTimeout(fallback);
  try {
    const result = JSON.parse(received);
    if (result?.hookSpecificOutput?.hookEventName === 'PermissionRequest')
      process.stdout.write(JSON.stringify(result));
  } catch {}
});
socket.on('error', () => { clearTimeout(fallback); });
