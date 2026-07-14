# Anna's Lists — handover brief

**To:** the implementing agent (running on gpt-5.6-sol)
**From:** Simon (product owner) — built collaboratively with Claude
**Accompanying file:** `annas-lists.html` (complete, working, single-file application)

## What this is

A group packing-list web app, born from a friend's (Anna's) camping spreadsheet. Groups of
people going on a trip together each build a packing list from reusable "packs", see each
other's progress, and coordinate shared items so the trip doesn't end up with four ice boxes
and no gas. It currently serves one friend group but is intended to grow into a general
lists product at its own domain (annaslists.xyz or similar — you will manage hosting and
domain).

A note on tone: the site is named for Anna as a quiet dedication. She is somewhat
anti-technology, and the product's job is to demonstrate — never announce — how useful her
list becomes with help. Do not add copy that celebrates "Anna's method" or makes the
dedication louder. The name, and her starred pack in the library, is the whole tribute.

## Non-negotiable constraints

These are deliberate product decisions. Propose alternatives if you believe they are wrong,
but do not silently violate them.

1. **No accounts.** Nobody signs up, ever. Sync (see roadmap) must use anonymous access.
   Identity is a self-chosen group nickname plus trust — the "trust check" dialog on pack
   editing ("is that you?") is the intended enforcement level, not a placeholder for auth.
2. **Free to run.** No API keys the user pays for; no services beyond generous free tiers.
   Weather uses Open-Meteo specifically because it needs no key.
3. **Works as a plain static file.** Whatever build tooling you introduce, the deployed
   output must keep working offline-first from a single URL, and local data must never be
   lost by a deploy.
4. **Data migrations are one-way and safe.** Users' localStorage must survive every change.
   Existing keys and shapes are documented below; migrate forward, never wipe.
5. **Anna's Camping Essentials pack ships built-in and starred.** Its content came from her
   real spreadsheet (genericised); treat it as editorial content, not sample data.

## Current architecture (v7, the accompanying file)

Single HTML file: CSS in `<style>`, vanilla JS in `<script>`, no dependencies, no build
step. Google Fonts (Bricolage Grotesque / Atkinson Hyperlegible / IBM Plex Mono) via CDN.

**State** lives in localStorage under key `annas-lists-v2` (with in-memory fallback if
storage is unavailable). Shape:

```
{ trips: [ { id, name, where, start, end,            // dates as yyyy-mm-dd strings
             groups: [ { id, name, color, packs: [packId],
                         items:  [ { id, cat, name, qty, status, src } ],
                         charge: [ { id, name, status } ],
                         shop:   [ { id, name, status } ] } ],
             communal: [ { id, name, claimedBy: groupId|null } ],
             pantry:   [ { id, name, claimedBy: groupId|null } ] } ],
  packs: { customPackId: { name, creator, items: [[category, itemName, qty?]] } } }
```

Older keys: `annas-lists-v1` (auto-migrated on load), `annas-theme` (`"dark"` / `"light"` /
absent = follow device; dark styles hang off the `dark` class on `<html>`), and
`annas-hint` (`"1"` once the person has changed any item's status; suppresses the
first-use hint).

**Item statuses** cycle through five states: `to_pack → packed → buy → tomorrow →
not_needed`. These came from Anna's spreadsheet and are core UX, not arbitrary. `buy` items
auto-appear on the Shopping tab; `tomorrow` items surface in the day-before banner;
`not_needed` is a recorded decision (struck through, excluded from progress) — deliberately
distinct from deleting an item.

**Item source tags** (`src`): every item records the pack it came from (`packId`,
`"custom"`, or `"rain"` for weather-nudge additions). A retro-tagger at boot back-fills
older data by matching. This powers pack removal — removing a pack deletes only "untouched"
items (status `to_pack`, qty 1) and reports what it kept — and is exactly the metadata a
sync backend will want.

**Packs** are snapshots, not subscriptions: adding a pack copies its items; later edits to
the pack do not propagate into existing lists. Keep this semantic.

**Sharing** currently encodes the entire trip (plus any referenced custom packs) as base64
JSON in a `#share=` URL fragment; `#sharepack=` does the same for a single pack. This is a
stopgap, not a design choice — see roadmap item 1.

**Weather:** Open-Meteo geocoding + forecast APIs, client-side fetch, in-memory cache.
Forecast strip renders per trip when destination + dates are set and the trip is within ~16
days; a rain nudge offers one-tap addition of the Wet weather pack to all groups.

**Theming:** light theme ("aurora": drifting blurred radial gradients under frosted-glass
cards) and dark theme ("night camp": deep forest, amber progress bars), auto-following the
device with a manual 3-state toggle in the header. `prefers-reduced-motion` is respected
throughout, including the confetti fired when a list first reaches 100% packed.

## Roadmap, in priority order

1. **Live sync backend.** Replace snapshot share links with short trip IDs backed by a
   database (Supabase anonymous access or equivalent free tier). Claims on communal
   gear/pantry and packing progress should update live-ish across devices. Keep
   localStorage as the offline cache / source of resilience. Once sync exists, share links
   become `?trip=<shortId>`.
2. **Mobile polish.** The app is responsive and touch-target-sized, and on screens under
   640px item rows are already de-cluttered: they show only status chip + name, and tapping
   the item's name expands the row to reveal the quantity stepper and delete (quantities
   above 1 stay visible collapsed as a passive "×N" label; the one-line hint teaches the
   gesture and self-dismisses after first use, flag `annas-hint`). Remaining work:
   replace native `confirm()`/`prompt()` dialogs with the existing styled `<dialog>`;
   consider a floating action button for share/add-group on the trip page. Swipe gestures
   on rows were considered — evaluate real usage of tap-to-expand before building them, as
   they may now be unnecessary. Two deliberate judgement calls you may revisit with usage
   evidence: the "Save as pack" button stays visible (not in an overflow menu) to keep the
   pack library discoverable while it builds momentum, and the three tabs stay as primary
   navigation.
3. **PWA.** Manifest + service worker for Add-to-Home-Screen and offline launch at
   signal-free campsites; add `viewport-fit=cover` and safe-area insets for standalone mode.
4. **AI list generation** (needs a tiny serverless proxy to hold the LLM key — pairs
   naturally with the sync backend's infrastructure): free-text trip description → tailored
   pack merged with (never replacing) chosen packs; a "review my list" critique against
   forecast and party composition; meal plan → pantry/shopping expansion.
5. **Later / opportunistic:** per-household gear closet; post-trip retro that improves saved
   packs; print-friendly view (Anna would like this); meal planning UI.

## Your latitude

Simon expects you to bring your own judgment, not just execute this list. If you see a
better information architecture, a cleaner sync model, features we haven't thought of, or
implementations superior to what's in the file, propose them — the current code was built
iteratively in conversation and makes no claim to being optimal. Two rules for exercising
that latitude: (a) the constraints section above outrules cleverness — "no accounts" in
particular tends to be eroded by well-meaning refactors; (b) when a change would alter
something users can see or have stored (statuses, pack semantics, share links, local data),
present the idea and the migration plan before building, rather than after.

Refactoring the single file into a proper project structure is expected and welcome once
you take ownership — just preserve the deployed offline-first behaviour and the migrations.
If you convert to a framework, justify the dependency weight against the current
zero-dependency load time.

## Known imperfections (honest list)

- Share links are long and last-write-wins; simultaneous edits on two phones will clobber
  each other until sync lands (the group has been told to treat one phone as source of
  truth for claims).
- Pack removal can't restore items once removed (no undo anywhere in the app).
- The aurora blur may jank on old low-end phones; acceptable for now, reduce blur under a
  media query if reports come in.
- `progress()` counts items, not quantities — deliberate, revisit only if users ask.
- Weather strings/dates render in the browser locale except trip dates, which display as
  raw yyyy-mm-dd in a couple of places.
- No tests. The file has been syntax-checked and manually exercised only.

## Definition of done for the handover itself

Deploy the accompanying file as-is to the chosen domain (static hosting), confirm forecasts
work in production (they fail gracefully in sandboxed previews), then start roadmap item 1.
