# CORTEX-M Auth Refactor — Development Plan

> **Goal**: Replace the legacy session-cookie auth in `src/cortex/session.py` with JWT + refresh-token rotation, gated behind a feature flag, with parity tests.
> **Owner**: apex
> **Started**: 2026-04-26
> **Target**: 2026-05-10

## Design Intent

The current session module stores opaque session tokens in a server-side
SQLite table. This couples auth state to a single process, blocks horizontal
scaling, and was flagged by legal for non-compliant token storage. We're
moving to short-lived JWT access tokens (15min) + rotating refresh tokens
(7d, single-use) backed by Redis. The `cortex-auth` flag controls cutover;
both stacks must run side-by-side until parity tests pass on prod traffic
shadow.

Bounded contexts: `auth/` is the only module that reads/writes tokens.
Everything else asks `auth.current_user(req)` — no direct token handling
elsewhere. The weekly architecture review must flag any code outside `auth/`
that touches `Authorization` headers or refresh flows.

---

## Phases

### Phase 1 — Scaffolding

- [ ] **Phase 1.1** [research][docs] Document the existing session lifecycle in `docs/auth/legacy-flow.md`
  - Acceptance: file exists, includes a sequence diagram, covers login/refresh/logout/expiry
  - Tier: phase-worker-standard

- [ ] **Phase 1.2** [backend] Create `src/cortex/auth/` module skeleton with explicit `current_user`, `issue_tokens`, `rotate_refresh`, `revoke` interfaces
  - Acceptance: `pytest tests/unit/auth/test_interfaces.py` passes (interface-only tests, no impl)
  - Tier: phase-worker-standard
  - Blocked-by: phase-1.1

### Phase 2 — Implementation

- [ ] **Phase 2.1** [backend][security] Implement JWT issuance with RS256, kid rotation, jti tracking
  - Acceptance: `pytest tests/unit/auth/test_jwt.py` passes; tokens validate against published JWKS
  - Tier: phase-worker-standard
  - Blocked-by: phase-1.2

- [ ] **Phase 2.2** [backend][security] Implement refresh-token rotation with Redis-backed single-use enforcement
  - Acceptance: integration test asserts old refresh token rejected with 401 after rotation
  - Tier: phase-worker-standard
  - Blocked-by: phase-2.1

- [ ] **Phase 2.3** [perf] Benchmark JWT verify p99 vs. legacy session lookup
  - Acceptance: `python scripts/bench_auth.py` produces JSON; new path p99 ≤ 1.2× legacy
  - Tier: phase-worker-light
  - Blocked-by: phase-2.1

### Phase 3 — Cutover

- [ ] **Phase 3.1** [tests] Parity test harness runs both stacks against mirrored traffic
  - Acceptance: `pytest tests/parity/auth/` passes with 0 divergences over 10k requests
  - Tier: phase-worker-heavy
  - Blocked-by: phase-2.2

- [ ] **Phase 3.2** [infra] Feature flag `cortex-auth=jwt` defaults off in prod, on in staging
  - Acceptance: `grep -r "cortex-auth" config/` shows correct env split
  - Tier: phase-worker-light

- [ ] **Phase 3.3** [docs] Write ADR-NNN: "JWT + refresh rotation replaces session cookies"
  - Acceptance: ADR file exists; CLAUDE.md links to it
  - Tier: phase-worker-standard
  - Blocked-by: phase-3.1, phase-3.2

### Phase 4 — Cleanup

- [ ] **Phase 4.1** [refactor] Remove legacy session module after 14d soak with flag at 100%
  - Acceptance: `git grep -q -v "session_cookie"` outside `tests/legacy/`
  - Tier: phase-worker-heavy
  - Blocked-by: phase-3.3

---

## Out-of-scope

- OAuth2 social login (separate plan)
- mTLS for service-to-service (separate plan)
- Migration of existing sessions to refresh tokens (handled lazily; users re-auth on next login)

## Open questions

- @apex: Do we ship a JWKS rotation runbook, or automate it via cert-manager?
