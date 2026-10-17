// OpenCode 1.18.32 TUI plugin. Registers only the displayed session and process.
import { createRoot, createEffect } from "solid-js";
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
export const id = "captions-conversation-navigation";
export async function tui(api) {
  const root = join(homedir(), "Library/Application Support/CodexCaptions/OpenCodeNavigation");
  const file = join(root, `${process.pid}.json`);
  const temporary = `${file}.tmp`;
  const processStart = Date.now() / 1000 - process.uptime();
  let previous;
  function clear() { try { unlinkSync(file); } catch {} }
  const dispose = createRoot(dispose => {
    createEffect(() => {
      const route = api.route.current;
      const sessionID = route.name === "session" ? route.params?.sessionID : undefined;
      if (sessionID === previous) return;
      previous = sessionID;
      if (typeof sessionID !== "string" || !/^ses_[A-Za-z0-9]+$/.test(sessionID)) { clear(); return; }
      try {
        mkdirSync(root, { recursive: true, mode: 0o700 });
        const record = { version: 1, sessionID, pid: process.pid, processStart,
          workspace: process.env.CMUX_WORKSPACE_ID, surface: process.env.CMUX_SURFACE_ID };
        writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
        renameSync(temporary, file);
      } catch { /* Navigation must never interrupt the conversation. */ }
    });
    return dispose;
  });
  api.lifecycle.onDispose(() => { dispose(); clear(); });
}
export default { id, tui };
