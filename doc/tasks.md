# Task tracker

Snapshot of platform-wip's open/closed work items, kept in the repo so
task state survives across sessions/tools (the interactive task list
used during development is session-scoped and does not itself persist).
Update this file when tasks are added, completed, or reprioritized.

## Pending

| # | Subject | Notes |
|---|---------|-------|
| 45 | Extract escape helpers into `luam/lib/escape.lua` | Deferred by user; a `luam`-level refactor, not platform-wip-specific. |
| 46 | Fix remaining bare cross-file helper calls flagged by the build-time audit | Ranked 3rd among open items at last prioritization pass. |
| 53 | Add attachment support to the chat widget | Deferred, future. |
| 57 | Investigate persistent-process mode to replace CGI-per-request | Deferred, future; would remove the per-request CGI bootstrap cost. |
| 64 | Add `[[title]]` widget-rule support in Toast UI WYSIWYG mode | Ranked 2nd among open items at last prioritization pass. |
| 65 | Add @mention support to the editor | Deferred, future; user-expressed interest. |
| 70 | Add deployment-configurable `system_prompt_extra` for the chat agent | Ranked 1st among open items at last prioritization pass. No current way for a deployment to add use-case-specific instructions to the agent's system prompt; real prior art exists in the fossil-scm fork. |
| 71 | Auto-generate chat titles from first user prompt | New: derive a session title from the first user message (via a system-prompt-driven step) instead of leaving sessions "Untitled" in chat history/knowledge pool listings. |
| 72 | Show chat start timestamp next to title in chat history | New: display each session's start time alongside its title in the chat history / knowledge pool listing. |
| 73 | Add label printing support (ZPL templates per entity schema) | New, larger feature. Port Benchling's workflow: per-schema ZPL label templates, a "Print label" action on any entity, template-embedded SQL to pull entity-specific fields (parameterized/read-only, no injection), printed via the existing Zebra printer software connection. Needs design: where templates live (schemas dir vs. new template type, matching the `views/`/`templates/` convention), safe SQL substitution, and the print hand-off mechanism. |
| 74 | Enable SQLite WAL mode + continuous off-VM backup (Litestream or cron+gsutil fallback) | Data-durability plan Phase 1 -- see `doc/data-durability.md`. Closes the ~24h RPO gap left by the existing daily disk-snapshot policy; also helps task #57's CGI-concurrency concern (WAL allows concurrent readers alongside a writer). |
| 75 | Write and drill a real restore runbook for the SQLite store | Data-durability plan Phase 2 -- see `doc/data-durability.md`. Must be run for real against a throwaway instance at least once to get a true RTO number, not just documented steps. |
| 76 | Move `/opt/platform/data` onto its own attached persistent disk | Data-durability plan Phase 3 (optional/lower priority) -- see `doc/data-durability.md`. Decouples data lifecycle from the boot disk/OS; not blocking Phases 1-2. |

## Completed (most recent first)

- 69: Knowledge Pool Phase 3 — landing page, nav revert (removed dedicated "Chats" rail icon, `/chat` reachable via System → Knowledge Pool)
- 68: Knowledge Pool Phase 2 — lazy note creation, agent tool, CLI (`platform knowledge stats/list/show/promote`)
- 67: Knowledge Pool Phase 1 — wire retrieval logging into `document.search`
- 66: Knowledge Pool Phase 0 — schema + pure logic module (`src/knowledge.lua`)
- 63: Deploy Toast UI Editor integration to production
- 62: Restore "knowledge pool" browsing (chat history / retrieved info) from old fossci
- 61: Add "start new chat" control to chat widget
- 60: Diagnose and fix silent agent-response failure in chat widget
- 59: Fix chat widget resize handle to grow from top-left, not bottom-right
- 56: Add pre-push git hook running the test suite
- 55: Fix deploy metadata-drift gap in deploy.sh/terraform
- 54: Build autoescape-by-default template helper
- 52: Persist chat widget open/closed state across page navigation
- 51: Make the chat widget dynamically resizable
- 50: Clean up dirty/raw output in chat transcript
- 49: Add a working/thinking indicator to the chat widget
- 48: Build a real rich-text (WYSIWYG) editor for Pages
- 47: Deploy real Celleste logo/favicon assets to production
- 39-44: Initial fossci → platform-wip migration (schema/template/view/extension port, Pages migration script, admin user setup, Docker/deployment config, real redeploy + end-to-end verification)

## Recently fixed production bugs (not tracked as tasks — already resolved)

- Universal current-user/current-page context for the chat agent (no owner awareness / auto subject / default due time when creating entities via chat).
- `/sql?embed=1` losing theme styling twice: first missing the `:root{}` theme-variable block entirely, then (after that fix) the block landing in the wrong template placeholder and rendering as visible page text instead of being applied as CSS.
- Home page company logo 404 in production, caused by a `cp -r` nesting bug in `startup-platform.sh.tpl`'s theme-assets copy step.
- Chat widget silently swallowing fetch errors (thinking indicator would disappear with no message sent and no feedback).
- `static/` → `vnd/` rename leaving stale cross-repo references in `~/software`'s Dockerfile/apache config/startup script, causing a real Cloud Build failure.
