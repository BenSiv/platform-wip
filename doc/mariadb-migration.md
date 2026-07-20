# Moving off SQLite to MariaDB

## Why (recap)

Raised alongside `doc/data-durability.md`: SQLite is an embedded library,
not a client/server database -- there is no network protocol to connect
to it remotely, and the file must never sit on a network filesystem
(broken POSIX locking risks silent corruption). MariaDB solves that
directly (real network access, real auth/TLS), gives real row-level
concurrency instead of SQLite's coarser locking, and -- if run as a
managed service (Cloud SQL) -- gets automated backups/PITR/failover
essentially for free, which is a stronger durability story than
Phases 1-3 of the durability plan.

**This is a bigger undertaking than "swap the driver".** Two repos,
three real phases, and it surfaces one genuine, already-live bug along
the way (see "Bug found during this investigation" below).

## Current state (verified against both repos, not assumed)

### Luam has zero client-server DB bindings today

`src/db.lua`'s own header says "v0 runs on SQLite ... doc/architecture.md,
'SQLite now, **Postgres** later'" -- not MariaDB. Checked
`/root/projects/luam`: the only database binding that exists is
`lib/sqlite/lsqlite3.c`, a large vendored SQLite amalgamation compiled
*statically* into the `platform` binary via `src/Makefile`'s own
`linux:` target (producing `bin/sqlite3.so`) -- not via the generic
`bld/build_libs.sh` dynamic-linking path that path even describes as
"secondary/unused" for sqlite specifically.

The *actual* template for a new binding is the small ones:
`lib/bcrypt/bcrypt.c` (~100 lines, one `luaL_Reg` table, links
`-lcrypt`) and `lib/hmac/hmac.c` (~68 lines, links `-lcrypto`), both
built by the generic `build_libs.sh` path as standalone `.so` files. A
MariaDB binding (`lib/mariadb/lmariadb.c`, linking `-lmariadb` against
Debian's `libmariadb-dev`) is much closer to these in size than to
sqlite's -- SQLite is unusually large because it vendors the whole
amalgamation; a real client library binding is normal C-binding-sized
work.

Module resolution is stock Lua 5.1 `require`
(`loadlib.c`'s `loader_C`/`loader_Croot`, driven by `LUA_CPATH`) -- a
new `lib/mariadb.so` (or `lib/mariadb/mariadb.so`) with a
`luaopen_mariadb` entry point just works, no bundler/manifest changes
needed anywhere.

### `lib/database.lua`'s calling convention -- the thing that actually constrains scope

- `local_query`/`local_update` (called by `src/db.lua`'s `db.query`/
  `db.exec`, i.e. everywhere in platform-wip) open a **fresh connection
  per call** -- not per request, per *query* -- set a couple of
  redundant-but-harmless PRAGMAs, run it, then unconditionally close.
  For SQLite (no handshake, just an `open()` syscall) this is free.
  **For MariaDB, a real TCP+auth handshake on every single query would
  be a severe, likely disqualifying latency regression** unless paired
  with connection pooling or a persistent process -- this makes task
  #57 (investigate persistent-process mode to replace CGI-per-request)
  a hard prerequisite for a usable MariaDB migration, not a nice-to-have
  optimization anymore.
- Queries are built via `string.format` + manual escaping
  (`database.escape_sqlite`, a naive `'`→`''` gsub; `src/db.lua`'s
  `db.quote`/`db.literal` wrap it) -- **string interpolation, not bound
  parameters** -- even though the underlying C binding exposes real
  `bind`/`bind_values`. A MariaDB binding is a natural place to switch
  to real prepared-statement parameter binding instead of carrying the
  same escaping convention forward; see "Design decisions" below.

### Dialect differences (grep'd across `src/*.lua`, not guessed)

| SQLite (current) | Count | MariaDB equivalent |
|---|---|---|
| `INTEGER PRIMARY KEY AUTOINCREMENT` | 6 (`agent.lua` x2, `knowledge.lua` x3, `extension.lua`, `ledger.lua`, `schema.lua`) | `INT PRIMARY KEY AUTO_INCREMENT` |
| `datetime('now', 'localtime')` | ~25 across `auth.lua`, `ledger.lua`, `schema.lua`, `entity.lua`, `document.lua`, `knowledge.lua`, `view.lua`, `extension.lua`, `agent.lua` | `NOW()` (or `UTC_TIMESTAMP()` if switching to UTC storage -- worth deciding once, not per-callsite) |
| `INSERT OR REPLACE INTO ...` | 6 (`document.lua` x2, `extension.lua`, `view.lua`, `schema.lua` x2, `knowledge.lua`) | `INSERT ... ON DUPLICATE KEY UPDATE ...` (semantically closer -- `REPLACE INTO` is actually DELETE+INSERT under the hood, which would needlessly burn AUTOINCREMENT ids and could disturb foreign-key cascade behavior these tables don't have yet but might) |
| `INSERT OR IGNORE INTO ...` | a few, same files | `INSERT IGNORE INTO ...` |

`SQL_TYPE` (`schema.lua:15`) is a simple 5-entry map (`text→TEXT,
number→REAL, date→TEXT, select→TEXT, reference→INTEGER`) -- clean,
disciplined usage, maps to MariaDB's `TEXT/DOUBLE/TEXT/TEXT/INT`
without any surprises. `schema.sync_table`'s "detect via
`db.table_exists`/`db.get_columns`, `ALTER TABLE ADD COLUMN` if
missing, never drop/rename" migration model is already
engine-abstracted through `db.lua` -- should port with no logic
changes, just the DDL string generation.

**FTS5 is a non-issue, corrected from an earlier assumption:** searched
for it -- `document.lua:335-337`'s own comment says FTS5 *was*
evaluated but this luam sqlite build doesn't have it compiled in, so
`document.search` already does its lexical+embedding scoring in plain
Lua over rows, not via a SQLite virtual table. Nothing to replace here.

### Bug found during this investigation (real, live, independent of this migration)

`ledger.lua:71-79`, the entity-creation path:

```lua
-- database.lua opens a fresh connection per call (see db.lua), so
-- last_insert_rowid() would be scoped to a connection that never
-- did the insert. MAX(event_id) is connection-independent and safe
-- here: v0 is a single-process CLI, no concurrent writers.
rows = db.query(db_path, "SELECT MAX(event_id) AS id FROM entity_event;")
entity_id = tonumber(rows[1].id)
db.exec(db_path, string.format(
    "UPDATE entity_event SET entity_id = %d WHERE event_id = %d;", entity_id, entity_id
))
```

The comment's own stated assumption -- "single-process CLI, no
concurrent writers" -- **is false for the actual deployed system**: this
runs today under Apache mod_cgid, a genuinely concurrent, multi-process
web server (confirmed by this session's own earlier work on concurrent
chat sessions/CSRF/capability checks). Two simultaneous entity-creation
requests can both read the same `MAX(event_id)`, then both assign the
same `entity_id` to two different rows -- silent data corruption, not a
crash, so it may not have been noticed yet. **This should be fixed
independent of any MariaDB work** (raised as its own task, #77, in
`doc/tasks.md`), most simply by wrapping the insert+update in a
transaction with `BEGIN IMMEDIATE` (SQLite) to serialize writers, or by
switching to a real per-request persistent connection and
`last_insert_rowid()` (SQLite) / `LAST_INSERT_ID()` (MariaDB), which
are both connection-scoped and safe under concurrency. This is also
exactly the fix that falls out for free once persistent connections
exist for the MariaDB work (task #57 territory again).

## Design decisions to make before implementing (flagging now, not blocking this doc)

- **Bound parameters vs. string interpolation**: recommend the new
  MariaDB binding expose real `mysql_stmt_bind_param`-style binding,
  with `src/db.lua` gaining a parameterized-query path used by new/
  touched call sites, rather than replicating `escape_sqlite`'s naive
  escaping for a second SQL dialect. This can land incrementally --
  existing `string.format`-built call sites keep working unchanged
  (still just as safe as they are today) while new code uses real
  binding; not an all-or-nothing rewrite.
- **Per-installation model**: "one SQLite file per installation" ->
  "one MariaDB *database* per installation on a shared server" is the
  natural equivalent (matches `architecture.md`'s stated isolation
  intent), rather than one full server/instance per installation.
- **UTC vs. localtime storage**: current schema stores `datetime('now',
  'localtime')` everywhere (server-local time, not UTC) -- worth
  deciding once, up front, whether to keep that convention or switch to
  UTC storage (`UTC_TIMESTAMP()`) as part of this migration, since
  every touched DDL/query needs the replacement anyway.
- **`db_path` becomes a connection descriptor**: every function
  signature across the codebase takes `db_path` as its first argument
  (by design, per `db.lua`'s own comment -- "only this file needs to
  change"). For MariaDB this becomes a connection config (host/port/
  user/password/database) rather than a filesystem path. `src/db.lua`
  can keep accepting a single opaque value (e.g. a DSN string or a
  small config table) so call sites elsewhere don't change at all --
  confirms the original adapter design is holding up as intended.

## Phased plan

### Phase 0 -- `luam`: new MariaDB C binding
- New `lib/mariadb/lmariadb.c`, following `bcrypt.c`/`hmac.c`'s shape
  (small `luaL_Reg` table, `luaopen_mariadb` entry point), linking
  Debian's `libmariadb-dev` (`-lmariadb`).
- Exposes: connect (host/port/user/pass/db) -> connection handle,
  query (returns rows), exec (returns affected-rows/insert-id), escape,
  close, error message retrieval. Mirror `lsqlite3.c`'s `nil, err`
  cross-boundary convention for consistency with the existing sqlite
  binding's calling style.
- Build wiring: add to `bld/build_libs.sh`'s generic pattern (not
  `src/Makefile`'s special-cased sqlite path).
- Tests: mirror `tst/test_database.lua`'s `pcall(require, "mariadb")`-
  gated pattern -- module loads even where the C lib isn't present,
  functional tests skip gracefully rather than failing the whole suite.

### Phase 1 -- `luam`: `lib/database.lua`-equivalent wrapper + connection lifecycle
- New Lua-level wrapper (`lib/mariadb.lua` or extend `database.lua`)
  exposing the same shape `src/db.lua` already calls
  (`query`/`exec`/`escape`), but backed by a **persistent connection
  per process** (opened once, reused across calls) instead of
  open-per-call -- this is the change that makes the whole migration
  viable latency-wise, and is the same underlying fix task #57 already
  wants for CGI-per-request generally. If #57's persistent-process work
  hasn't landed yet, this phase should include at least a
  request-scoped (not query-scoped) connection as a minimum bar.

### Phase 2 -- platform-wip: `src/db.lua` adapter swap
- `src/db.lua` gains a MariaDB-backed implementation behind the same
  `db.query`/`db.exec`/`db.quote`/`db.literal`/`db.table_exists`/
  `db.get_tables`/`db.get_columns` surface -- per the file's own design
  intent, this should be the only platform-wip file whose *internals*
  change; every caller elsewhere keeps calling the same functions.
- Config: `config.lua` gains connection-config resolution (env vars,
  matching the existing `PLATFORM_VENDOR_DIR`-style convention) instead
  of `config.db_path`'s filesystem-path resolution.

### Phase 3 -- platform-wip: dialect migration
- Mechanical DDL/query replacements per the table above, file by file
  (`agent.lua`, `auth.lua`, `document.lua`, `entity.lua`, `extension.lua`,
  `knowledge.lua`, `ledger.lua`, `schema.lua`, `view.lua`).
- Fix the `ledger.lua` `MAX(event_id)` race properly here (or earlier,
  independently -- see task #77) using `LAST_INSERT_ID()` against the
  now-persistent connection.
- Full `./bld/test.sh` pass required against a real MariaDB instance
  (local `mariadb` Docker/Podman container for dev+CI), not just SQLite,
  before this phase is considered done.

### Phase 4 -- cutover
- Stand up managed MariaDB (Cloud SQL for MySQL, MariaDB-compatible, or
  self-managed) alongside the existing SQLite deployment.
- One-time data migration script (dump SQLite tables, load into
  MariaDB, verify row counts + spot-check ledger integrity per
  installation).
- Cut `fossci-app-prod`'s startup script over to the new connection
  config; keep the SQLite file + its existing snapshot policy around,
  untouched, as a rollback path for one full deploy cycle.

## Feature-parity check: does anything here actually need Postgres?

Went through the codebase's real usage, not a generic feature matrix,
since that's the only comparison that matters for this migration:

- **Embeddings/vector retrieval** -- `document.lua`'s `document_embedding`
  table stores `vector_json` as a plain `TEXT` column; `document.search`
  decodes it with `json.decode` and computes `cosine_similarity` in
  **pure Lua**, row by row (`document.lua:411,471`). No SQLite-specific
  vector extension (no `sqlite-vss`, no virtual table) is in use today --
  this was evaluated for FTS5 and dropped, and the same "just use plain
  columns + application code" choice was made for vectors too. Nothing
  here relies on a feature MariaDB lacks.
  - Bonus, worth knowing either way: **MariaDB gained a native `VECTOR(N)`
    type + `VECTOR INDEX`** (modified HNSW, cosine/euclidean distance,
    up to 16,383 dimensions), GA in the 11.7/11.8 LTS line (2025) --
    already stable well before now. If the Lua-side `cosine_similarity`
    scan ever becomes a real bottleneck (large document/knowledge-pool
    counts), there's a legitimate first-party path to move that
    similarity search into the database itself, comparable to Postgres's
    `pgvector` -- not something to build now, just good to know it's not
    a dead end.
- **Document tree hierarchy** (`html.lua`'s `build_document_tree_index`)
  -- built with one flat query + a Lua-side parent-child index, not a
  recursive CTE. Both engines support recursive CTEs anyway (MariaDB
  since 10.2, 2016), so this wouldn't have been a blocker either way.
- **JSON fields** (`ledger.lua`'s `field_changes`, `agent.lua`'s tool-call
  payloads, `knowledge.lua`, etc.) -- always stored as an opaque `TEXT`
  blob, `json.encode`/`json.decode`d in Lua, **never queried inside the
  JSON at the SQL level** anywhere in this codebase. Postgres's JSONB
  (richer indexing, path queries) genuinely outclasses MariaDB's JSON
  support here -- but since nothing here uses SQL-level JSON querying
  either way, that gap doesn't touch this project.
- **The one real, if speculative, gap**: Postgres's `LISTEN`/`NOTIFY`
  (async cross-connection pub/sub) has no MariaDB equivalent. Not used
  today (no persistent process yet), but if task #57's persistent-process
  work ever wants "notify other workers a schema/theme changed" without
  polling, Postgres would give that for free and MariaDB would need
  polling or an external broker (Redis, etc.) instead. Worth remembering
  if #57 gets designed, not a reason to reconsider now.
- **Row-level security** is Postgres-only (not in MariaDB) but irrelevant
  here -- every access check in this codebase is application-level
  (`auth.lua` capabilities), never a database-enforced policy.

**Bottom line**: nothing currently built or concretely planned needs a
Postgres-only capability. The MariaDB choice holds up under scrutiny of
actual usage, not just in the abstract.

## Not recommended as part of this

- **Postgres instead of MariaDB**: same cross-repo binding-writing cost
  either way (Postgres has no existing luam binding either). Your stated
  reasoning -- wanting a purely relational engine specifically to avoid
  the feature-creep/data-mess risk Postgres's flexibility (JSONB,
  extensions, procedural languages, etc.) invites -- holds up: everything
  audited above is deliberately plain relational + application code
  already, so MariaDB's narrower feature set isn't a constraint you'd be
  fighting, it's already the shape this codebase is written in. Postgres
  usage *could* be limited to an equivalent relational-only subset by
  convention (no JSONB columns, no extensions, no stored
  procedures/triggers, no `LISTEN`/`NOTIFY`) -- but that's a policy the
  team has to keep enforcing by discipline/code review; MariaDB removes
  the temptation structurally by not offering those features at all,
  which is the actual guarantee you're after, not just a preference.
- **Skipping Phase 1's persistent-connection work**: technically
  possible to ship Phase 0+2+3 with open-per-query connections, but per
  "current state" above, this would likely make every page load
  noticeably slower than it is today -- not a real option for a
  production system, just noted so it's not silently skipped under
  time pressure.

## Critical files
- `/root/projects/luam/lib/sqlite/lsqlite3.c` -- registration pattern to mirror
- `/root/projects/luam/lib/bcrypt/bcrypt.c`, `/root/projects/luam/lib/hmac/hmac.c` -- actual size/shape template for the new binding
- `/root/projects/luam/lib/database.lua` -- wrapper to extend/mirror
- `/root/projects/luam/bld/build_libs.sh` -- where the new binding's build step goes
- `/root/projects/platform-wip/src/db.lua` -- the one platform-wip file meant to absorb this change
- `/root/projects/platform-wip/src/config.lua` -- connection-config resolution
- `/root/projects/platform-wip/src/ledger.lua:61-80` -- the live race condition to fix
- `/root/projects/platform-wip/src/schema.lua:15-21,198-230` -- DDL generation/type mapping
- Every `src/*.lua` file listed in the dialect table above
