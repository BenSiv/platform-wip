# Task tracker

Snapshot of platform-wip's open/closed work items, kept in the repo so
task state survives across sessions/tools (the interactive task list
used during development is session-scoped and does not itself persist).
Update this file when tasks are added, completed, or reprioritized.

## Pending

Full reprioritization pass on 2026-07-20 (previous per-item "Ranked Nth" notes superseded by
this single ordering, top to bottom = highest to lowest priority):

| # | Subject | Notes |
|---|---------|-------|
| 95 | Confirm the Google Cloud Data Processing Addendum (CDPA) is accepted for this project | **1st.** Cheap to check (for whoever has GCP Org/Billing Account admin access), real legal/contractual gap (not a design one), and foundational -- #74 (GCS backups) and #82 (possible Cloud SQL) both implicitly depend on this being settled. No `gcloud` CLI surface exists to check/accept it; I can't do this myself. See `~/software/docs/ai-agent-and-lab-data-compliance-research.md`. |
| 64 | Add `[[title]]` widget-rule support in Toast UI WYSIWYG mode | **4th.** |
| 74 | Enable SQLite WAL mode + continuous off-VM backup (Litestream or cron+gsutil fallback) | **5th.** Data-durability plan Phase 1 -- see `doc/data-durability.md`. Closes the ~24h RPO gap left by the existing daily disk-snapshot policy; also helps task #57's CGI-concurrency concern (WAL allows concurrent readers alongside a writer). Writes to GCS, same as everything else here -- covered under the same CDPA as #95, not a separate agreement. |
| 90 | Reorganize templated deployment configs in `~/software` (housekeeping) | **6th, newly elevated.** NOT an in-app UI -- repo-level housekeeping. `~/software/elab/schema/platform/`'s templated configs (`schemas/`, `views/`, `extensions/`, `templates/`, `theme.json`, Dockerfile, `apache-platform.conf`, `startup-platform.sh.tpl`, etc.) are organized ad hoc; consolidate into one coherent, navigable structure. Elevated this pass: the compliance research surfaced real, confusing overlap between this (platform-wip's actual deployment configs) and the separate `elab/docs/01-07` eLabFTW design series (a different, not-yet-built architecture -- the GCP project is even still named "Celleste eLabFTW") -- worth reconciling which is the intended direction before it compounds further. Distinct from #89 (that's an in-app admin UI). |
| 87 | Persist full AI prompts/reasoning in the Knowledge Pool | **7th. Unblocked -- #91/#92 research done, no showstopper found.** From user notes: "full ai thinking persistence in knowledge pool including prompts." Today `knowledge_retrieval` logs query text and hit metadata (score/tier/rank), not the full prompt sent to the model or its reasoning. Same audit-trail expectations (attributable/timestamped/complete) that already apply to the ledger would apply here too, nothing new. |
| 96 | Confirm/obtain a Google Cloud HIPAA BAA, if PHI is ever in scope | **8th.** Same console location as #95, separate "Review and Accept" action. Contingent -- needs a deliberate "is PHI ever in scope" yes/no first, rather than being actionable on its own. |
| 75 | Write and drill a real restore runbook for the SQLite store | **9th.** Data-durability plan Phase 2 -- see `doc/data-durability.md`. Must be run for real against a throwaway instance at least once to get a true RTO number, not just documented steps. Depends on #74. |
| 84 | Design multivalue field support for entity schemas | **10th.** From user notes: "how do we record multivalue data entry in a relational database." `schema.lua`'s `FIELD_TYPES` (text/number/date/select/reference) has no array/multivalue type today -- e.g. an entity needing several lot numbers or several linked reagents has no first-class way to express that. Real architecture question, not yet scoped: a join table per multivalue field? A JSON-array column with app-level validation? Affects schema.md and the projected-table generation model. |
| 88 | Design separation between science-analysis data and operational/audit data | **11th.** From user notes: "raw data schema vs operational data schema separation" -- corrected: NOT about Benchling import data, but about the platform's own data. The distinction is between user-entered scientific data meant for analysis (entity/reagent/experiment/sample rows, etc.) and operational data whose purpose is auditing (the `entity_event` ledger, user/session/admin activity). Today both live in one undifferentiated schema/storage model -- worth designing whether they should be separated (storage location, access patterns, retention/backup policy) given their different purposes. |
| 82 | Stand up managed MariaDB and cut production over | **12th.** MariaDB migration Phase 4 -- see `doc/mariadb-migration.md`. Depends on #81 (done) and ideally #95 first. Keep the SQLite file + snapshot policy as a rollback path for one full deploy cycle. Also needs `libmariadb-dev` added to `elab/schema/platform/Dockerfile`'s builder stage -- the production binary is currently built without MariaDB support compiled in (gracefully, not an error) since that image doesn't have the header yet. |
| 73 | Add label printing support (ZPL templates per entity schema) | **13th.** New, larger feature. Port Benchling's workflow: per-schema ZPL label templates, a "Print label" action on any entity, template-embedded SQL to pull entity-specific fields (parameterized/read-only, no injection). Printing likely goes through **Zebra Browser Print** specifically (a local agent + JS SDK that lets a web page discover/print to a Zebra printer directly from the browser, no server-side print-queue plumbing needed) rather than a generic "printer software connection." Needs design: where templates live (schemas dir vs. new template type, matching the `views/`/`templates/` convention), safe SQL substitution, and the Browser Print JS integration. |
| 94 | Evaluate a tamper-evidence/immutability layer for the ledger | **14th.** Found during #92's research. Today `entity_event`'s append-only guarantee is enforced only by application code + ordinary DB access control -- no cryptographic signing or WORM storage the way the (separate, not-yet-built) eLabFTW design doc's GCS Object Lock bucket has. Reasonable for current scale/threat model; revisit if formal GLP/21 CFR Part 11 certification is ever pursued. |
| 86 | Replace `/data`'s connection graph with a real ERD diagram | **15th.** From user notes: "add real erd diagram instead of just a connection graph." Today's `/data` diagram is a plain node-per-type/edge-per-reference graph (see `cgi.bats`'s own test description) -- a real ERD would show field names/types and cardinality, not just connectivity. |
| 85 | Migrate platform deployment from Docker to Podman | **16th.** From user notes and this session's earlier discussion: rootful Podman is a low-effort drop-in swap (Debian 12 ships it directly, daemonless already closes Docker's biggest attack-surface complaint); fully rootless (matching the user's own dev container) needs a dedicated service account, subuid/subgid ranges, and a `systemctl --user` unit -- decision on which level still open. |
| 89 | Design a consolidated admin/settings interface | **17th, needs scoping.** From user notes: "admin and settings interfaces" -- currently spread across `/admin-users`, `/system`, `theme.json`, and various env vars with no single place to see/manage them. Vague as captured; needs a follow-up conversation to scope exactly what "consolidated" should cover before design work starts. |
| 76 | Move `/opt/platform/data` onto its own attached persistent disk | **18th, explicitly low priority.** Data-durability plan Phase 3 -- see `doc/data-durability.md`. Decouples data lifecycle from the boot disk/OS; not blocking Phases 1-2. |
| 45 | Extract escape helpers into `luam/lib/escape.lua` | Deferred by user; a `luam`-level refactor, not platform-wip-specific. |
| 53 | Add attachment support to the chat widget | Deferred, future. |
| 57 | Investigate persistent-process mode to replace CGI-per-request | Deferred, future; would remove the per-request CGI bootstrap cost. |
| 65 | Add @mention support to the editor | Deferred, future; user-expressed interest. |

## Completed (most recent first)

- 93: "Reason for change" field for the ledger's update/archive events — nullable `entity_event.reason` column; per-schema opt-in via `require_reason_on_update`/`require_reason_on_archive` type-level flags (`entity.update`/`entity.archive` reject the change when required and missing); wired into `/api/update`/`/api/archive` (plain query/form param) and the chat agent's `entity.update` tool; reason renders on `/detail`'s history. Note: only the touchpoints with a real caller today were wired (CGI routes, agent's `entity.update` tool) — `entity.archive` isn't an agent tool, and there's no separate web edit/archive form beyond the CGI routes, so no automated-sync-path default string was needed either.
- 70: Deployment-configurable `system_prompt_extra` — `theme.json` field appended verbatim to `agent.default_system_prompt`, matching fossil-scm's own prior art
- 91/92: Vertex AI + general lab-data compliance research done — see `~/software/docs/ai-agent-and-lab-data-compliance-research.md` (deliberately placed outside the separate `elab/docs/01-07` eLabFTW design series, which describes a different, not-yet-built system). No blockers found; surfaced two concrete future gaps (tasks #93, #94) and unblocked #87.
- 46: Fixed the 3 bare cross-file helper calls flagged by the build-time audit (luam's `gnuplot.lua`/`utils.lua`/`user.lua`) — two were real, fixed by calling through the module table properly; the third (`escape_string` in `user.lua`) turned out to be referenced only from commented-out dead code, deleted rather than "fixed"
- 83: Removed `/data`'s embedded SQL widget (persistent styling problem, explicit call to stop chasing it) — `/sql` itself untouched, still reachable via `/system`
- 72: Chat history sidebar now shows each session's start timestamp under its title
- 71: Sessions with no explicit title now get one auto-generated from their first real message (reuses `knowledge.guess_title_from_body`)
- 81: MariaDB migration Phase 3 — every SQLite-dialect DDL/DML token routed through new `db.lua` helpers; found and fixed two dialect gaps a live server surfaced (TEXT-as-key needs `VARCHAR(255)`, TEXT-in-index needs a prefix length); `bld/build.sh` now conditionally compiles MariaDB support into the binary itself; luam gained `CLIENT_MULTI_STATEMENTS` support. `platform init` + full entity CRUD + the concurrent-create race check all verified end-to-end against a live MariaDB server; automated bats coverage added (`tst/integration/mariadb_backend.bats`)
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
