# Lessons learned

What the stand taught that is not obvious from the code. One entry per lesson, newest
first; the phase and date say when it was learned.

- **2026-09-27, Phase 6.4 — backup, restore and the patch-upgrade lab.** *A consistent
  backup can still restore inconsistently, and one occurrence is not a cause.* The first
  restore brought eight instances back without `startDate` although the snapshot held them
  complete. The source reading — the exporter re-processing its unacknowledged tail after a
  restore, and the archiver's overwriting reindex moving hours-old finished instances within
  seconds of the start — explains it, but two clean round-trips with the exporter-sync wait in
  place did not reproduce it, and the wait never had to hold, so they exercised a quiet stand,
  not the mitigation. What can be claimed: the snapshot was intact, the loss happened after
  `bin/restore`, and it did not recur in 2 of 2 clean runs. What cannot: that the mechanism
  is confirmed, or that the wait is what prevented it. The wait stays because it removes the
  one measurable cause; the field-level check (`verify-state.sh` newest-instance lines) stays
  because counts alone would have missed the loss; and a suspected backup gap is diagnosed by
  restoring the snapshot into a renamed index before blaming the backup. *Ownership before
  recreate:* a backup path not writable by uid 1001 left partition 1 without a leader for
  ~70 min while the container reported `healthy` — healthy means the management port
  answers, not that a partition processes; the smoke's writability checks run before any
  `--force-recreate` that adds backup keys. *Screenshots come from the browser only:*
  terminal captures carry the prompt (user, host) and were dropped from the evidence;
  terminal output is quoted from the run logs instead. Details:
  `docs/runbooks/backup-restore.md` §3, §5, §6; `docs/ops/upgrade.md` §3.
- **2026-09-27, Phase 6.4 — the minor-upgrade path 8.8 → 8.9 was not rehearsed.** ADR-002
  planned a disposable 8.8 lab to see the unified-configuration remapping and the index
  migration on real data. The stand started on 8.9 (ADR-002's own choice), so the lab was
  reused for the **patch** path instead (8.9.19 → 8.9.21, `docs/ops/upgrade.md`). A minor
  upgrade on this stand will be the first one, with the 8.10 migration guide and a backup as
  the only safety net.
