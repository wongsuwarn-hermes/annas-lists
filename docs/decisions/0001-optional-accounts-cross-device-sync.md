# Decision 0001: Optional accounts and cross-device sync

**Status:** Approved by Simon on 2026-07-14

## Decision

Anna's Lists will support cross-device cloud continuity and live-ish collaboration through a hybrid model:

- A person may create and use trips locally without an account.
- A person may opt a trip into cloud sync and receive unguessable read/edit capability links.
- Participants may open a capability link, choose a group nickname, and collaborate without registering.
- Optional Google sign-in and email magic-link sign-in will let an organiser recover owned trips and open them on other devices.
- Email/password authentication will not be implemented.
- An account will never be required to open or edit a capability-linked trip.

This supersedes only the original handover's blanket prohibition on accounts. The original `HANDOVER.md` remains preserved as the historical handover.

## Product rationale

Trip creation is often better on a desktop while packing and trip-day use are better on a phone. Durable cross-device access is therefore a core use case, not an edge case. Requiring every invited participant to register would still damage the group-chat invitation loop, so accounts remain optional and organiser-oriented.

## Authorisation model

- Cloud trips have short public IDs plus separate high-entropy read and edit capabilities.
- Capability secrets are held in URL fragments and sent explicitly to backend RPCs; they are never stored in plaintext by the backend.
- Authenticated owners may recover and list their trips without the capability link.
- Direct table access is denied; access is mediated by narrow database functions.
- The first release uses optimistic versions and preserves conflicts as local copies rather than silently overwriting either side.

## Forward-only migration

1. Existing `annas-lists-v2` data remains the local source of truth until the user explicitly chooses **Sync this trip**.
2. No existing trip or pack is uploaded automatically.
3. Opting in creates a cloud copy and records only cloud metadata in a new `annas-cloud-v1` key.
4. Existing `#share=` and `#sharepack=` snapshot links continue to import exactly as before.
5. New live links use `?trip=<short-id>#key=<capability>` and do not reinterpret old snapshot links.
6. On a version conflict, the client stores its unsynced state as a separate local recovery copy before accepting or replacing cloud state.
7. Signing in may associate selected cloud trips with the account; it never deletes local trips or packs.
8. Signing out removes the session but does not wipe local trip data.

## Operational constraints

- Supabase is the initial backend because its free tier combines Postgres, Auth and server-side RPCs.
- The app must continue to load and edit local data when Supabase, authentication or the network is unavailable.
- Public Supabase URL/publishable-key configuration is not a secret; service-role credentials must never enter the browser or repository.
- Production remains on free tiers unless Simon explicitly approves a change.
