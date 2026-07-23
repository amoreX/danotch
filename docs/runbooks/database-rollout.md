# Runbook: Database Rollout

**Scope:** Ordered migration deployment, idempotency verification, RLS validation, and rollback.

---

## Pre-flight

1. **Snapshot the current schema** (on staging first):
   ```bash
   cd backend
   npm run db:snapshot
   git diff -- schema.sql   # must be empty if no pending migrations
   ```
2. **Fingerprint any manually bootstrapped database** before its first automated migration:
   ```bash
   npm run db:fingerprint
   ```
   This records checksums without altering objects. Required once per existing environment; skip on clean deploys.
3. **Verify staging passes all RLS integration tests**:
   ```bash
   DATABASE_URL=<staging-url> npm run test:db
   ```
4. Confirm CI is green on the branch being deployed (migrations job and DB integration tests both pass).

---

## Deployment — Expand/Migrate/Contract

Perch migrations follow expand-then-contract. Never apply a contract migration to an environment where the old client version is still running.

### Step 1 — Apply migrations

```bash
cd backend
DATABASE_URL=<prod-url> npm run db:migrate
```

Expected output: each migration prints `applied: <name>`. A second run of the same command must print `already applied: <name>` for all rows — **idempotency is required**.

Run it twice to confirm:
```bash
DATABASE_URL=<prod-url> npm run db:migrate
DATABASE_URL=<prod-url> npm run db:migrate   # must change nothing
```

### Step 2 — Verify (read-only)

```bash
DATABASE_URL=<prod-url> npm run db:verify
```

This confirms checksums match and no objects have drifted. It **does not mutate** the database.

### Step 3 — Schema snapshot drift check

```bash
npm run db:snapshot
git diff -- schema.sql
```

The diff must be empty after a successful migration. If it is not, the snapshot generator and the migration are out of sync — halt and investigate.

### Step 4 — RLS smoke test (staging only; against a populated staging DB)

```bash
DATABASE_URL=<staging-url> npm run test:db
```

All tenant isolation and policy tests must pass before promoting to production.

---

## Rollback

**Migrations are forward-only.** To roll back:

1. **Deploy the prior release** of the backend service. This restores the code that understands the previous schema.
2. If the migration added columns or tables (expand), the prior release ignores them safely — no schema change is required.
3. If the migration removed columns or tables (contract), rollback is not safe without a restore — this is why contract migrations are only applied after the one-release backward-compatibility window.
4. For emergency schema recovery from a point-in-time backup:
   ```
   - Take a snapshot of the current state before restoring.
   - Restore from Supabase point-in-time recovery.
   - Re-apply only the non-destructive migrations from the restore point.
   - Re-run db:verify to confirm checksums.
   ```

---

## Monitoring

After migration:
- Check Supabase dashboard for query errors or RLS rejections in the next 15 minutes.
- Verify `/health` on the backend returns `"db": "ok"` and `"migrations": "verified"`.
- Confirm no `500` errors on tenant-facing routes in the first 5 minutes of traffic.

---

## Credential Rotation

Database passwords and service keys are stored in environment secrets (never committed). Rotation steps:
1. Generate new credential in Supabase dashboard.
2. Update the secret in the deployment environment.
3. Redeploy the service (zero-downtime rolling deploy).
4. Verify the old credential no longer works by attempting a connection with it.
5. Record rotation in the incident/change log.
