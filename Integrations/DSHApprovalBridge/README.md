# Optional DSH approval bridge

The subtitle offers **Allow once** and **Reject** for a DSH permission request.
An optional plugin inside DSH owns submission; transcript files remain read only.

Install only after the user authorizes modifying their DSH desktop profile:

```sh
python3 scripts/install_dsh_approval_bridge.py
```

The installer backs up `cordis.patch.yml`, copies this module into the profile,
and appends one independent loader entry. The installed DSH profile enables
configuration hot reload; no DSH restart is requested by the installer.

The plugin wraps the live ApprovalService and races the existing DSH responder
against a user decision from the local socket. It binds the exact audit ID,
session ID, tool name, and reason. It returns success only after DSH commits
the matching `approval/decided` event. Only `allowed-once` and `rejected` are
accepted. Duplicate, mismatched, and cancelled requests fail closed.

The socket lives in the user's DSH directory (directory mode 0700, socket 0600).
It grants local processes running as that user a decision entry point; installing
it is a persistent extension of the DSH approval boundary. It exposes no network
listener, performs no automatic approvals, and does not add a polling loop.
The protocol limits input to 64 KiB, connections to eight, and pending requests
to 64. The original DSH UI works without a connected VibeCute client.

This integration relies on private APIs verified against the installed DSH
0.2.1-rc.2 (Cordis 4.0.5). It unwraps Cordis's traced service before wrapping the
method, and restores the original method when unloaded. Requests already pending
before the plugin loads remain handled by DSH. A missing bridge leaves the
subtitle's **Open DSH** fallback available; an uncertain result disables resubmission.

To remove: delete the block between the `BEGIN VibeCute approval bridge` and
`END VibeCute approval bridge` comments from the DSH profile patch, then remove
the copied plugin directory. Configuration reload disposes the bridge; disposal
cancels any bridge-owned pending requests. Keep the backup for rollback.

Portable protocol checks:

```sh
node Tests/DSHApprovalBridgeChecks.mjs
```

`DSH_APPROVAL_SERVICE_MODULE` can point to the installed approval module when
running the checks with DSH's Electron in Node mode. `DSH_SWIFT_CHECK` can point
to a native transport check executable to verify the Swift client as well.

## Exact desktop conversation navigation

The package also ships a DSH client contribution. A user click requests navigation
by session ID over the same private socket. The host forwards a bounded Remote
waterfall to the client; the client checks session existence, calls the installed
`uiWorkspace.openSession`, and returns success only after `mainReference.sessionId`
matches. Only the `dsh-app://app` desktop client handles this event; other connected
preview clients delegate. This avoids switching an unrelated browser preview.
Navigation has a 2.5-second event timeout and a four-second native deadline, with
no idle polling. It does not send messages, create sessions, or decide approvals.

The installer now places this package in the desktop profile's local node_modules
and records its content revision in an independent v3 loader entry. This allows
DSH's client loader to discover the `./client` export. Simply changing the module
name under the original entry did not reload the old bridge; the migration changes
the loader identity. The earlier standalone plugin file is left unused for rollback.

## DSH question cards

The bridge also forwards explicit `question-status` and `question-answer` clicks
to the existing desktop question card. The native UI reads only
`ask_user_question` arguments, renders one complete batch, and matches session,
call, question IDs, text, option labels and descriptions before sending it.
Single-choice and multi-select batches are supported; free-text-only questions
keep the DSH reply link. Nothing selects an option until the user clicks it.

Older desktop cards omit their call ID. For those, the host verifies the newest
unresolved `ask_user_question` in the exact live root's last 512 Session events,
then the client compares the entire question batch. A closed, changed, claimed
or unmatchable card fails closed. Current live cards are reused, so upgrading
the bridge does not require cancelling or reissuing pending questions.

Only the explicit reply operation settles the card; status is read-only. Both
use the existing private socket and bounded Remote event deadline, with no idle
polling. Success means the existing DSH answer channel accepted the batch; an
uncertain result disables repeat submission and directs the user to DSH.

Checks: `node Tests/DSHQuestionChecks.mjs`;
`bash scripts/dsh_question_checks.sh --log /absolute/path/to/session.v4.jsonl.zstd`.
The native check uses a local callback and never sends the real session answers.
Module identity v11 invalidates older cached client contributions.
The primary action guides users through all questions before sending the batch.

## Setup in VibeCute

Open **Settings → AI tools and characters → DeepSeek Harness** to enable or repair
interaction. The same control is available in first-run onboarding, even before
DSH has produced its first session. Users may choose subtitle tracking alone.
If the desktop profile is not initialized, open DSH once and check again.

The app bundles all plugin files in both signed profiles; no Python, Node or
terminal is needed on the receiving machine. Setup backs up the current patch,
replaces only the VibeCute block, checks for concurrent config changes, and
refuses symbolic-link destinations. Unchanged installations do not rewrite the
patch or create another backup. Never restore an entire old patch to repair a
missing bridge: that could overwrite newer settings for other plugins.

An explicit `bridge-status` request checks host revision and desktop client
version without selecting a conversation or answering a card. Checks run only
when setup is shown, the app returns to the foreground while setup is shown, or
the user requests one. Installing schedules one deferred check; there is no idle
polling or silent config rewriting.
