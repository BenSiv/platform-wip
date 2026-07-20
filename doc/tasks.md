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
| 73 | Add label printing support (ZPL templates per entity schema) | New, larger feature. Port Benchling's workflow: per-schema ZPL label templates, a "Print label" action on any entity, template-embedded SQL to pull entity-specific fields (parameterized/read-only, no injection). Printing likely goes through **Zebra Browser Print** specifically (a local agent + JS SDK that lets a web page discover/print to a Zebra printer directly from the browser, no server-side print-queue plumbing needed) rather than a generic "printer software connection." Needs design: where templates live (schemas dir vs. new template type, matching the `views/`/`templates/` convention), safe SQL substitution, and the Browser Print JS integration. |
| 74 | Enable SQLite WAL mode + continuous off-VM backup (Litestream or cron+gsutil fallback) | Data-durability plan Phase 1 -- see `doc/data-durability.md`. Closes the ~24h RPO gap left by the existing daily disk-snapshot policy; also helps task #57's CGI-concurrency concern (WAL allows concurrent readers alongside a writer). |
| 75 | Write and drill a real restore runbook for the SQLite store | Data-durability plan Phase 2 -- see `doc/data-durability.md`. Must be run for real against a throwaway instance at least once to get a true RTO number, not just documented steps. |
| 76 | Move `/opt/platform/data` onto its own attached persistent disk | Data-durability plan Phase 3 (optional/lower priority) -- see `doc/data-durability.md`. Decouples data lifecycle from the boot disk/OS; not blocking Phases 1-2. |
| 81 | Migrate SQL dialect differences off SQLite (`AUTOINCREMENT`, `datetime('now','localtime')`, `INSERT OR REPLACE/IGNORE`) | MariaDB migration Phase 3 -- see `doc/mariadb-migration.md`. Depends on #80 (done). Full file list and replacement table in the design doc. Unblocks `platform init` succeeding against MariaDB at all, and therefore the first full bats-level MariaDB integration coverage. |
| 82 | Stand up managed MariaDB and cut production over | MariaDB migration Phase 4 -- see `doc/mariadb-migration.md`. Depends on #81. Keep the SQLite file + snapshot policy as a rollback path for one full deploy cycle. |
| 83 | Remove the embedded SQL widget from `/data` | **Ranked 1st among the new batch (2026-07-20).** From user notes: "still have issues with rendering the sql window in data, lets remove it for now" -- a persistent styling problem despite the earlier CSS-placement fix this session; the user's own call is to pull it rather than keep chasing it. Quick, low-effort, removes ongoing user-facing pain immediately. |
| 91 | Research Vertex AI (Google Cloud) data security and compliance posture | **Ranked 2nd.** Cheap (research only, no code) and informs how much further AI-feature investment (e.g. #87) makes sense given this is a lab/LIMS context (Benchling-adjacent) where regulated data may be involved. |
| 92 | Research applicable scientific/lab data compliance requirements in general | **Ranked 3rd.** E.g. 21 CFR Part 11, GLP/GxP, audit-trail/data-integrity standards -- broader than #91, informs schema/retention/audit design choices (ledger's own append-only design may already satisfy some of this, worth checking against real requirements rather than assuming). |
| 84 | Design multivalue field support for entity schemas | **Ranked 4th.** From user notes: "how do we record multivalue data entry in a relational database." `schema.lua`'s `FIELD_TYPES` (text/number/date/select/reference) has no array/multivalue type today -- e.g. an entity needing several lot numbers or several linked reagents has no first-class way to express that. Real architecture question, not yet scoped: a join table per multivalue field? A JSON-array column with app-level validation? Affects schema.md and the projected-table generation model. |
| 88 | Design raw-import vs. operational schema separation | **Ranked 5th.** From user notes: "raw data schema vs operational data schema separation." Benchling-imported data (`import_data_rest.py`/`pull_entries_rest.py`) currently lands directly in the same entity tables the app operates on day-to-day -- worth designing whether raw imported rows should live in their own schema/tables, with operational tables derived/synced from them, vs. today's single-schema model. |
| 87 | Persist full AI prompts/reasoning in the Knowledge Pool | **Ranked 6th (after #91/#92 research).** From user notes: "full ai thinking persistence in knowledge pool including prompts." Today `knowledge_retrieval` logs query text and hit metadata (score/tier/rank), not the full prompt sent to the model or its reasoning -- deliberately deferred, ranked after the compliance research since storing raw model input/reasoning has its own data-governance implications worth knowing first. |
| 86 | Replace `/data`'s connection graph with a real ERD diagram | **Ranked 7th.** From user notes: "add real erd diagram instead of just a connection graph." Today's `/data` diagram is a plain node-per-type/edge-per-reference graph (see `cgi.bats`'s own test description) -- a real ERD would show field names/types and cardinality, not just connectivity. |
| 85 | Migrate platform deployment from Docker to Podman | **Ranked 8th.** From user notes and this session's earlier discussion: rootful Podman is a low-effort drop-in swap (Debian 12 ships it directly, daemonless already closes Docker's biggest attack-surface complaint); fully rootless (matching the user's own dev container) needs a dedicated service account, subuid/subgid ranges, and a `systemctl --user` unit -- decision on which level still open. |
| 89 | Design a consolidated admin/settings interface | **Ranked 9th, needs scoping.** From user notes: "admin and settings interfaces" -- currently spread across `/admin-users`, `/system`, `theme.json`, and various env vars with no single place to see/manage them. Vague as captured; needs a follow-up conversation to scope exactly what "consolidated" should cover before design work starts. |
| 90 | Consolidate schemas/views/extensions/templates-as-code into one navigable, editable UI | **Ranked 10th, needs scoping.** From user notes: "consolidating [schemas/views/extensions/templates] as code into one coherent navigable and editable [interface]" (my interpretation of a terse note -- confirm this reading). Today each lives in its own directory of hand-edited `.lua` files plus CLI commands (`schema add`, `view approve`, ...); this would be an in-app, browsable/editable interface for all of them together. Related to #89 but distinct (this is about the schema/view/extension/template artifacts specifically, not user/system admin). |

## Completed (most recent first)

- 80: MariaDB migration Phase 2 — `src/db.lua` dispatches by `db_path`'s shape (string vs. descriptor table), `db.quote`/`db.literal` kept backend-agnostic via `NO_BACKSLASH_ESCAPES`, `config.lua` gains `db_backend()`/`mariadb_descriptor()`. Verified directly against a live server (query/exec/quote/table_exists/get_tables/get_columns); `platform init` itself still needs Phase 3's dialect migration before it can succeed against MariaDB
- 77: Fixed `entity_id`/`event_id` race in `ledger.lua`'s create/update path — `SELECT MAX(event_id)` replaced with `db.exec`'s connection-scoped `last_insert_rowid()` return value; added a concurrent-load integration test (see `tst/integration/entity.bats`)
- 79: MariaDB migration Phase 1 — persistent-connection wrapper in luam's `lib/database.lua` (`mariadb_query`/`mariadb_update`, one cached connection per descriptor, not open-per-call)
- 78: MariaDB migration Phase 0 — new `lib/mariadb/lmariadb.c` binding in luam (connect/query/exec/escape/ping/close), verified end-to-end against a real local MariaDB server
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
