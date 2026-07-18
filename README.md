# platform-wip

A traceable, extensible data-entry and record-keeping platform:
define your own record types, get full audit history and validated
data entry for free, and extend behavior for your own domain without
touching the core. It's a single, self-contained web application --
its own login/sessions and its own rendering, no external identity
system or separate version-control layer to run alongside it.

**Working name only.** `platform` (the binary name) and this
directory's name are both placeholders pending a real project name.

## Status

- **Record types as code, full event history, ad hoc querying,
  extensible behavior** -- done. See `doc/architecture.md`/
  `doc/schema.md`/`doc/extensibility.md`.
- **Nothing is ever deleted, only archived** -- done. See
  "Traceability" below.
- **Accounts, sessions, and permissions** -- done. See "Auth" below.
- Hosting under a real web server, storage consolidation, a
  document/notebook record type, and an assistant/chat layer are not
  built yet.

## Building

Written in [Luam](https://github.com/BenSiv/luam); requires a sibling
`luam` checkout, already built (`obj/liblua.a` present). By default
`bld/build.sh` looks for it at `../luam`; override with the `LUAM_DIR`
env var if yours lives elsewhere.

```sh
./bld/build.sh          # -> bin/platform
./bld/build.sh -v       # same, with full compiler output (default logs to a temp file)
```

## Testing

Requires `bats` on PATH (`apt install bats` / `brew install
bats-core`).

```sh
./bld/test.sh
```

Runs the unit tests (`tst/unit/*.lua`, standalone scripts that exit
non-zero on failure) and the integration tests (`tst/integration/*.bats`,
which build and exercise the real binary end to end, including real
web-request-shaped input -- see `tst/integration/test_helper.bash`).

## CLI

```
platform init                                   # create .store/ (the database) here
platform schema add <file.lua>                   # register/update a record type
platform schema list
platform entity create <type> field=value ...
platform entity list <type> [--include-archived]
platform entity show <type> <id>
platform entity update <type> <id> field=value ...
platform entity archive <type> <id>              # never a delete -- see below
platform entity unarchive <type> <id>
platform ledger show|history <entity_id>
platform extension list|show|approve|revoke|run-pending <name>
platform view list|show|approve|revoke <name>
platform user add <login> <password> [cap]
platform user passwd <login> <new_password>
platform user capabilities <login> <cap_string>
platform user list [--include-archived]
platform user archive|unarchive <login>
```

Running with no arguments uses this CLI dispatch; running under a real
(or test-simulated) web request runs the request-handling path instead
-- see `src/main.lua`.

Record types need an explicit `schema add` to register (that's what
generates/migrates the type's own table). Saved queries and behavior
extensions are just files dropped into `views/<name>.lua` /
`extensions/<name>/{manifest,main}.lua` and picked up automatically --
`approve`/`revoke` is the only CLI step they need before they're live.

## Auth

`platform user add <login> <password> [cap]` creates a login. `/login`
and `/logout` are the only routes reachable without an active session;
every other route requires one. Permissions are re-checked from the
account's current record on every request rather than trusted from
anything the session itself carries, so changing or revoking someone's
permissions (or archiving their account) takes effect on their very
next request, not only once their existing session expires. See
`doc/architecture.md`'s "Auth" section for the full session/CSRF
design, and `src/auth.lua` itself.

## Traceability

Nothing is ever deleted. Every record carries a nullable "archived"
timestamp; archiving/unarchiving are additive history entries, never a
removal. Listing/counting records excludes archived ones by default
(an opt-in flag brings them back); looking up a record directly, or its
full history, always works regardless of archive state. The same
convention applies to accounts.

## Docs

- `doc/architecture.md` -- the record-history model, how record types
  and extensions run sandboxed, and the auth/session design.
- `doc/schema.md` -- defining record types: field types, sandboxed
  loading, what a definition generates.
- `doc/extensibility.md` -- the extension system: manifest format,
  event hooks, capability sandboxing.
