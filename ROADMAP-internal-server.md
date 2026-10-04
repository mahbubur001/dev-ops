[← Back to Home](README.md)

# Infrastructure Roadmap — `internal-server`

Forward-looking plan for the AWS box (`internal-server`) hosting **bikribd** + **radiustask**. Nothing here is urgent — the current setup works. This captures the hardening steps and the long-term direction so we can act when traffic or incidents justify it.

> **Status:** current setup left as-is (2026-09-28). Implement items below later, in priority order.

---

## Current State (as of 2026-09-28)

| | Detail |
|---|---|
| **Box** | AWS t4g.medium — 2 vCPU / 4GB RAM / 30GB gp3 / 6GB swap (arm64, Ubuntu 24.04) |
| **Apps** | bikribd (:4000, bun) + radiustask (:3010, pnpm) — Next.js, PM2 |
| **Data** | PostgreSQL 18 (local) + Redis (local) |
| **Edge** | Cloudflare (proxied) → Nginx (Let's Encrypt) → PM2 → Next.js |
| **Deploy** | bikribd = **off-box build** (arm64 runner → rsync → swap+reload). radiustask = **on-box build** (SKIP_TS_CHECK, still to be moved off-box) |

**Known constraints:**
- 4GB shared by 2 Next apps + 3 workers + Postgres + Redis — fine for light traffic, tight for growth.
- Off-box build fixes deploy-time load only; **runtime** memory contention is unaddressed.
- On a memory-constrained box, `next build` tsc pass OOMs → mitigated with `SKIP_TS_CHECK`.

---

## Near-Term Hardening (low effort, do when convenient)

- [ ] **Pin runner Node to 22** in the bikribd off-box job (`actions/setup-node@v4`, `node-version: 22`) — removes the native-module ABI mismatch risk (runner-built binaries must match the server's Node major).
- [ ] **Move radiustask to off-box build** — same pattern as bikribd, but pnpm variant: `pnpm/action-setup`, `pnpm install --frozen-lockfile`, `pnpm build`, and also rsync `dist/` (the built workers). Keep `SKIP_TS_CHECK`.
- [ ] **Read-only DB user for build-time queries** — the off-box build tunnels to the prod DB; give it a read-only role instead of the app user to shrink the blast radius.
- [ ] **Pin `encryptionKey`** in each app's `next.config` (from `.env`, stable across deploys) — quiets the post-deploy "Failed to find Server Action" errors from stale clients.
- [ ] **Serialize deploys** — never let a bikribd and radiustask build overlap (each already has its own concurrency group; keep it that way). Two concurrent builds would OOM.
- [ ] **`max_memory_restart` sizing** — keep caps above each app's real working set (Next SSR ≈ 650MB). Sum of all caps must stay under RAM+swap. Current: bikribd 1200M, radiustask-saas 1G, workers 256–512M.

---

## Long-Term Direction (when traffic / revenue / incidents justify the spend)

The durable answer is **containerize + right-size + offload data services**. Each piece stands alone; adopt in this order for best ROI.

### 1. Move Postgres off the app box → managed (RDS) or dedicated DB box
**Biggest single reliability win.** Frees ~1GB+ on the app box and ends the DB-vs-app RAM fight. Managed RDS also gives automated backups, PITR, and painless version upgrades.

### 2. Dockerize the apps, build images in CI
Replaces the rsync/tunnel/SSH-write-key deploy with a clean image pipeline:
- `docker buildx` (arm64) builds the image in CI → push to a registry (GHCR / ECR)
- Server does `docker pull && docker compose up -d` (atomic, rolling)
- Kills every off-box wart at once: reproducible, arch-correct, atomic, no prod `.env`/DB exposed to CI, no partial-sync window.

### 3. Right-size / split compute
- Either **one 8GB instance** (on-box builds become viable again), or
- **One box per app** (full isolation — a runaway in one app can't starve the other).

### Target end-state
Each Next app in a container on an 8GB (or dedicated) instance · Postgres on RDS · Redis managed or co-located · deploys = build image in CI → pull → rolling restart. Boring and bulletproof.

---

## Decision Triggers

Act on the long-term items when **any** of these show up:

- `health-check.sh` shows **swap climbing at peak traffic** (runtime contention, not just build-time).
- Deploys or incidents start **causing user-visible downtime**.
- Either app becomes **revenue-bearing** enough that an OOM is unacceptable.
- Adding a **third app** to the box.

Until then: the hardened off-box build on the 4GB box is a reasonable place to sit. Don't over-engineer ahead of need.

---

*Last reviewed: 2026-09-28*
