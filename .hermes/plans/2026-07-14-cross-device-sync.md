# Cross-device Sync and Optional Accounts Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add safe cross-device trip continuity, capability-link collaboration, and optional Google/email-magic-link organiser accounts without breaking local/offline use.

**Architecture:** Keep `annas-lists-v2` as the durable offline model. Add a Supabase RPC boundary around versioned JSON trip snapshots, using high-entropy read/edit capabilities for guest access and nullable authenticated ownership for recovery. The browser pulls before editing, pushes changes with an expected version, polls while visible, and preserves every conflict as a separate local recovery copy rather than silently overwriting data.

**Tech stack:** Existing dependency-free HTML/CSS/vanilla JS; Supabase Postgres/Auth; SQL migrations; Node's built-in test runner; optional Supabase JS browser client loaded defensively so local mode still works if it is unavailable.

---

### Task 1: Record the approved constraint change

**Objective:** Preserve the historical handover while documenting the approved optional-account exception and forward-only migration.

**Files:**
- Create: `docs/decisions/0001-optional-accounts-cross-device-sync.md`
- Modify: `AGENTS.md`

**Verification:**
- `HANDOVER.md` remains byte-for-byte unchanged.
- `AGENTS.md` points to the decision and retains every other locked constraint.

### Task 2: Add testable cloud-state primitives

**Objective:** Implement pure functions for capability generation, cloud metadata, URL parsing, version handling and conflict-copy naming before wiring network behaviour.

**Files:**
- Create: `src/sync-core.js`
- Create: `tests/sync-core.test.js`
- Create: `package.json`

**Steps:**
1. Write failing Node tests for live-link parsing, old snapshot-link non-interference, metadata migration, token entropy inputs, and conflict-copy creation.
2. Run `npm test` and verify the expected failures.
3. Implement the smallest dependency-free UMD module usable from Node and the browser.
4. Run `npm test`; expect all tests to pass.

### Task 3: Define and test the Supabase RPC contract

**Objective:** Create a least-privilege SQL schema supporting guest capability access, optional ownership and optimistic version checks.

**Files:**
- Create: `supabase/migrations/202607140001_cross_device_sync.sql`
- Create: `supabase/tests/cross_device_sync.sql`
- Create: `supabase/config.toml`

**Schema/RPCs:**
- `trips`: UUID ID, short ID, nullable owner, JSONB payload, version, token hashes, timestamps.
- `create_cloud_trip(data, read_token, edit_token)`
- `read_cloud_trip(short_id, token)`
- `write_cloud_trip(short_id, edit_token, expected_version, data)`
- `claim_cloud_trip(short_id, edit_token)`
- `list_owned_cloud_trips()`
- `rotate_cloud_trip_tokens(short_id)` for authenticated owners.
- Revoke all direct anon/authenticated table privileges; expose only the functions required by each role.

**Verification:**
- Run locally with Supabase CLI/Docker if available.
- Otherwise execute SQL parser/static checks and run the contract against the hosted project before production deployment.
- Confirm stale writes return a structured conflict and do not mutate the row.

### Task 4: Add the defensive Supabase client and session UI

**Objective:** Let users sign in optionally without making local use depend on authentication or the network.

**Files:**
- Create: `src/cloud-client.js`
- Create: `tests/cloud-client.test.js`
- Modify/generated integration: `index.html`

**Behaviour:**
- Config is read from a public inline object containing project URL and publishable key.
- If config or SDK is absent, the app remains fully local and hides/disables cloud controls with honest copy.
- Header account control offers Google and email magic-link sign-in; no passwords.
- Auth callback restores the prior route.
- Signing out never clears `annas-lists-v2`.

**Verification:**
- Node tests mock fetch/auth boundaries.
- Browser test with backend unavailable proves existing local behaviour still works and produces no console errors.

### Task 5: Add opt-in trip sync

**Objective:** Make a local trip live, open live links on another device and keep sequential desktop/mobile edits current.

**Files:**
- Modify: `index.html`
- Modify: `src/cloud-client.js`
- Extend: `tests/cloud-client.test.js`

**Behaviour:**
- Trip page offers **Sync this trip**; no automatic uploads.
- Creation stores `{localTripId, shortId, readKey, editKey, version, lastSynced}` under new key `annas-cloud-v1`.
- Sharing offers live edit and view-only links when synced; old snapshot sharing remains available for local trips.
- Opening `?trip=<short-id>#key=<token>` imports/opens the cloud trip without requiring sign-in.
- Pull on page load, focus and visibility restoration; poll only while the trip view is visible and never overlap requests.
- Debounced push after local saves when an edit capability exists.
- Visible states: saved, saving, offline, newer cloud version, local recovery copy created.

**Verification:**
- Automated tests cover create, pull, sequential push, offline queue, stale version and read-only capability.
- Two isolated browser contexts demonstrate desktop create/edit followed by mobile pull/edit.

### Task 6: Preserve conflicts and data

**Objective:** Ensure concurrent or offline edits cannot silently destroy either device's state.

**Files:**
- Modify: `src/sync-core.js`
- Modify: `src/cloud-client.js`
- Modify: `index.html`
- Extend corresponding tests.

**Behaviour:**
- A stale write never retries as last-write-wins.
- Before replacing local state with newer cloud data, save the unsynced local trip as `<name> — recovery copy <date/time>` with new local IDs where required.
- Present a styled conflict dialog describing what happened and where the copy is.
- Never rewrite packs or status semantics during conflict handling.

**Verification:**
- Tests prove both payloads survive a conflict.
- Browser QA confirms the recovery copy is visible on the home screen and the cloud trip remains open.

### Task 7: Provision hosted infrastructure

**Objective:** Create and configure the real free-tier Supabase project.

**Steps:**
1. Simon signs into Supabase once; Hermes performs the remaining project configuration where the authenticated session/API permits.
2. Apply the migration.
3. Configure canonical site URL and redirect URLs for `https://annaslists.xyz` and localhost QA.
4. Enable Google provider only after its OAuth client ID/secret is configured; enable email magic links independently.
5. Place only the public project URL/publishable key in the generated app.
6. Verify service-role credentials are absent from git and browser output.

### Task 8: Production QA and deployment

**Objective:** Ship only after local/offline/cross-device behaviour has been exercised.

**Verification:**
- JS syntax and `npm test` pass.
- SQL contract tests pass against the hosted project.
- Existing localStorage migration and old snapshot imports still work.
- Local-only use works with network blocked.
- Desktop and 390px mobile layouts have no overflow or clipping.
- Browser console is clean.
- Production weather still works.
- Two isolated production browser contexts complete a cross-device round trip.
- GitHub Pages build completes; live source contains expected version markers.
