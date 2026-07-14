# Anna's Lists

A group packing-list web app for trips. Groups build lists from reusable packs, track packing progress, coordinate shared gear and pantry items, and use weather-aware packing nudges.

The deployed application is a dependency-free, single-file static app in `index.html`. Local trips remain in `annas-lists-v2`; live-trip metadata and capability secrets are kept separately in `annas-cloud-v1`.

Cloud continuity is opt-in per trip. Guest edit and view-only links work without accounts. Optional organiser accounts use passwordless email and can recover owned trips on another device. Google OAuth is intentionally hidden until its provider credentials are configured.

## Local preview

```bash
python3 -m http.server 8765
```

Then open `http://localhost:8765/`.

## Build and verification

`src/sync-core.js` and `src/cloud-client.js` remain independently testable. The build embeds them and the public Supabase configuration into `index.html`:

```bash
npm test
npm run build
npm run test:hosted
```

The build is idempotent. Supabase migrations, hosted verification notes and the security model are documented in `supabase/README.md`.

## Product and implementation context

Read `HANDOVER.md` and `AGENTS.md` before making changes. The handover contains the current architecture, localStorage schema, locked product constraints, known imperfections, and roadmap.
