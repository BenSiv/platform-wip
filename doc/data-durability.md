# Data durability & recovery plan

## Problem

Everything platform-wip stores lives in one SQLite file
(`.store/store.db`, i.e. `/data/.store/store.db` inside the container,
which is bind-mounted from `/opt/platform/data` on `fossci-app-prod`'s
own boot disk -- see `elab/infra/modules/fossci_compute/templates/
startup-platform.sh.tpl`). There is no separate data disk, no
replica, and no application-level backup step anywhere in the deploy
pipeline today. If that one disk is lost or corrupted, everything it
holds -- users, ledger history, pages, chat sessions, the knowledge
pool -- goes with it, unless GCE's own disk snapshot happens to cover it.

## What already exists (don't re-solve this)

`elab/infra/modules/fossci_compute/main.tf` already attaches a daily
snapshot policy to the boot disk:

```
google_compute_resource_policy.snapshot: daily @ 04:00, 7-day retention,
storage_locations = [var.region]
google_compute_disk_resource_policy_attachment.snapshot: attached to
the instance's boot disk
```

This is a real, working baseline, not a gap to fix from scratch:

- **Regional storage** (`storage_locations = [var.region]`) means a
  snapshot survives loss of the whole zone (`europe-west1-b`), not just
  the disk.
- **Crash-consistent** GCE disk snapshots are safe for SQLite even
  mid-write: a snapshot is equivalent to a power-cut, and SQLite's own
  rollback-journal (or WAL, if that's ever enabled -- see below)
  recovery on next open handles that correctly, the same guarantee
  SQLite gives across a real power loss. No special quiescing is needed
  before a snapshot.
- `deletion_protection = true` on the prod instance stops an accidental
  `terraform destroy`/console delete of the VM (though not of the disk
  independently, or of the snapshots themselves).

**What this baseline does NOT give you:**

1. **Up to ~24 hours of data loss (RPO)** -- a snapshot only exists once
   a day; anything written between the last snapshot and a failure is
   gone.
2. **No tested restore path (RTO unknown)** -- a snapshot no one has
   ever restored from is a hypothesis, not a plan. There's currently no
   documented or scripted procedure for "disk is gone, bring the app
   back from the latest snapshot."
3. **No independent backup of just the data** -- the snapshot is of the
   whole 50GB boot disk (OS + app binary + the SQLite file together),
   not something you could restore into a fresh VM without also
   reverting the OS/app state to that point.
4. **Single instance, single zone actually serving traffic** -- the
   snapshot protects the *data*, but a zone outage still means real
   downtime until someone manually provisions a replacement instance.

## Recommended plan (phased, cheapest/highest-value first)

### Phase 1 -- Continuous off-VM backup (closes the RPO gap)

Add [Litestream](https://litestream.io/) (or, as a lower-effort
first cut, a cron job doing `sqlite3 store.db ".backup /tmp/x.db"` +
`gsutil cp` on a tight interval -- see "Fallback" below) running
inside the platform container, streaming every committed change in
`store.db` to a versioned GCS bucket continuously instead of once a
day.

- Requires switching SQLite to **WAL mode** (`PRAGMA journal_mode=WAL;`)
  -- Litestream replicates the WAL, and WAL mode is also the right fix
  for a separate, already-tracked concern (task #57, CGI-per-request +
  SQLite locking) since WAL allows concurrent readers alongside a
  writer, unlike the current default rollback-journal mode which can
  serialize/lock more aggressively under concurrent CGI processes.
  Worth doing together, not as two separate migrations.
- RPO drops from ~24h to effectively **seconds** (Litestream's default
  sync interval).
- Restoring is `litestream restore` into a fresh file -- scriptable,
  fast, and independent of whatever state the VM's boot disk happens to
  be in, unlike a full-disk snapshot restore.
- Cost: one small GCS bucket, versioned, with a lifecycle rule to
  expire old generations after e.g. 30 days.

**Fallback if Litestream is judged too much new surface area for now:**
a plain systemd timer (matching the existing `chown` unit's own pattern
in `startup-platform.sh.tpl`) running SQLite's *online backup API* via
`sqlite3 .store/store.db ".backup /tmp/backup.db"` every 15 minutes,
then `gsutil cp` to a GCS bucket with per-timestamp object names. Safe
to run against a live database (the backup API takes its own read
lock, doesn't block writers indefinitely, and never risks a torn
copy the way `cp`-ing the raw file would). Coarser RPO (~15 min instead
of seconds) but zero new dependencies, shippable same-day.

### Phase 2 -- Documented, tested restore runbook

Whichever backup mechanism Phase 1 lands with, write the actual restore
steps down (`doc/data-durability.md`, this file, gets a "Restore
procedure" section) and **run it for real at least once** against a
throwaway VM/instance before trusting it:

1. Provision a fresh instance (or reuse a stopped one) from the current
   image.
2. Pull the latest backup/snapshot.
3. Bring the container up pointed at the restored `store.db`.
4. Confirm login works and spot-check a few known records/ledger
   entries survived.
5. Time the whole thing -- that duration is your real RTO, not a guess.

Also worth a `platform ledger verify`-style integrity check (if one
doesn't exist yet, a small CLI addition) that walks the ledger and
confirms every projected table still matches its log, so a restored
backup's integrity is machine-checked, not just "app started
successfully."

### Phase 3 (optional, only if warranted) -- Decouple data from the boot disk

Move `/opt/platform/data` onto its own attached persistent disk instead
of the boot disk. `main.tf`'s own comment explains today's choice
(boot disk already gives real block-device semantics, no need for a
second disk) -- that reasoning still holds for *correctness*, but a
separate data disk would let you:

- Snapshot just the data, on its own schedule, independent of the OS
  disk's lifecycle.
- Replace/rebuild the VM (OS upgrade, machine-type change, image
  rebuild) without any risk to the attached data disk.
- Reattach the same data disk to a brand-new instance in a DR scenario
  without replaying a full-disk restore.

Lower priority than Phases 1-2 -- worth doing eventually, not blocking
the RPO/RTO fixes above, and it's a real (if modest) infra change
against a `deletion_protection`'d prod instance, so it deserves its own
planning pass rather than folding into this one.

### Not recommended (for now)

- **Moving off SQLite to a managed DB (Cloud SQL, etc.)** -- a genuine
  option if concurrency/scale ever demands it (already flagged as the
  reason `src/db.lua` is a thin adapter, see `doc/architecture.md`'s
  "Storage" section), but this is a full architecture change unrelated
  to the durability question asked here: Phases 1-2 give strong
  durability guarantees *for SQLite as-is*, at a fraction of the cost
  and risk of a storage-engine migration.
- **Multi-zone hot standby / automatic failover** -- meaningful added
  complexity (leader election, replication lag, split-brain handling)
  that a single-company internal LIMS tool likely doesn't need; a
  documented, drilled restore-from-backup runbook (Phase 2) with a
  known RTO of, say, 15-30 minutes is probably the right tradeoff
  point unless there's an explicit uptime SLA driving a stricter
  requirement. Revisit if that changes.

## Critical files
- `/root/software/elab/infra/modules/fossci_compute/main.tf` -- existing snapshot policy, instance definition
- `/root/software/elab/infra/modules/fossci_compute/templates/startup-platform.sh.tpl` -- where a backup timer/unit would be added, alongside the existing chown/init systemd units
- `/root/projects/platform-wip/src/db.lua` -- where a `PRAGMA journal_mode=WAL` call would be added
- `/root/projects/platform-wip/doc/architecture.md` -- "Storage" section, should reference this doc once a phase ships
