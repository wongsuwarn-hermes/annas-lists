# Anna's Lists — agent operating context

Read `HANDOVER.md` before changing product behaviour or user-visible design.

## Source of truth

- `index.html` is the complete v7 application supplied in the Claude handover.
- Preserve the original handover in `HANDOVER.md`.
- Until a deliberate refactor is approved, edit and deploy `index.html` directly.

## Locked product constraints

1. No user accounts. Identity remains a self-chosen group nickname plus trust.
2. The product must remain free to run and must not require user-funded API keys.
3. The deployed app must stay offline-first and usable from one URL.
4. Never wipe or silently invalidate localStorage. Migrations are forward-only and safe.
5. Preserve `annas-lists-v2`, migration from `annas-lists-v1`, `annas-theme`, and `annas-hint` unless an explicit migration plan has been approved.
6. Anna's Camping Essentials remains built-in and starred. Keep the dedication quiet; do not add celebratory copy about Anna or “Anna's method.”
7. Preserve the five item statuses and their semantics: `to_pack`, `packed`, `buy`, `tomorrow`, `not_needed`.
8. Packs are snapshots, not subscriptions.
9. Do not alter stored/user-visible semantics without first presenting the change and migration plan.

## Execution rules

- Treat the supplied visual design and copy as settled unless Simon explicitly asks for a redesign.
- Before deploying a change, syntax-check JavaScript, serve locally, inspect browser console, and verify desktop and mobile layouts.
- Weather must be tested against the production origin because sandboxed previews can block it.
- Keep hosting/deployment on free tiers.
- Make a clean baseline commit before roadmap implementation.
