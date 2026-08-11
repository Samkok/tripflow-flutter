# Multi-Modal Optimization — Test Cases

Device QA matrix for the Routes-API migration + multi-modal upgrade
(Phases 1–4, built 2026-08-10). Run on a real device — transit data and
compass behavior don't exist in simulators.

> **Prerequisite (owner, one-time):** enable **Routes API** on the Google
> Cloud project backing `GOOGLE_DIRECTIONS_API_KEY`, and add Routes API to
> the key's API restrictions. Every case below fails with an API error
> until this is done. The legacy Directions API can be disabled afterwards.

---

## P1 — Routes API migration (parity)

| # | Case | Steps | Expected |
|---|------|-------|----------|
| 1.1 | Drive parity | Trip with 5+ spread-out stops (e.g. your Hong Kong trip), Optimize | Route appears as before: legs, chips with km/min, timing sim runs, "time saved" banner unaffected |
| 1.2 | Single-stop route | Day with exactly 1 place, optimize from current location | One leg renders, no crash |
| 1.3 | All-days view | Toggle Entire trip in the map day picker | Every day's colored route still renders (this path also runs on Routes API now) |
| 1.4 | From→To preview | Location card → preview route between two stops | Single leg renders; other pins hidden as before |
| 1.5 | API not enabled (negative) | Run before enabling Routes API | Optimize fails gracefully: no route, no crash, error logged — then enable API and re-test |
| 1.6 | Offline | Airplane mode, Optimize | Graceful failure, old route (if any) retained, app responsive |

## P2 — Mode ladder + visuals

| # | Case | Steps | Expected |
|---|------|-------|----------|
| 2.1 | Walking-city auto-detect | Trip with all stops within ~3 km (old town), profile **Auto**, Optimize | Legs are dotted (walk); leg chips show the walking glyph |
| 2.2 | Road-trip auto-detect | Trip with stops >3 km apart, Auto, Optimize | Solid drive legs, car glyph — visually identical to pre-upgrade |
| 2.3 | Mixed trip | Compact cluster + one far stop, Auto | Short hops walk (dotted), long hop drive/transit; each chip's glyph matches its line style |
| 2.4 | Car-unreachable stop (the Venice bug) | Stop in a pedestrian-only zone, Auto or Road trip | Leg falls back to walk/transit instead of the route silently missing |
| 2.5 | No route in any mode | Stop on a small island with no ferry data | Faint dashed straight line + "No route found" in its rail/sheet — leg never disappears |
| 2.6 | Walk shadow | Inspect a dotted walking leg | No solid "phantom" line under the dots |
| 2.7 | Leg tap highlight | Tap a walking leg, then a drive leg | Highlight width/border appears; dotted stays dotted while highlighted |
| 2.8 | Re-optimize cost (cache) | Optimize, then re-optimize the same day twice | 2nd/3rd runs visibly faster (legs cached); same result |

## P3 — Transit

| # | Case | Steps | Expected |
|---|------|-------|----------|
| 3.1 | Transit leg chosen | Walking-city trip with two stops ~2–5 km apart in a transit metro (BTS Bangkok / MTR HK / vaporetto Venice) | Leg renders SOLID in the line's official color; chip shows vehicle glyph + colored line badge (e.g. boat + "2") |
| 3.2 | Transit leg sheet | Tap that leg's chip or rail | Sheet shows line badge in official color, "to ‹headsign›", board stop + scheduled time, alight stop + time, stop count |
| 3.3 | Scheduled-time chaining | Multi-stop day with 2+ transit legs | Later legs show later scheduled times (departures follow arrival + stay) |
| 3.4 | Vehicle glyphs | Test ferry / metro / bus legs where available | Boat, subway, bus icons respectively — not a generic bus for everything |
| 3.5 | No-transit city | Walking-city trip somewhere without transit data | Ladder falls back walk→drive; no error surfaced to the user |
| 3.6 | Sheet timeline rails | Optimize, open trip plan sheet, Selected Day tab | Between consecutive stop cards: rail rows — dotted+Walk for walking, colored bar+badge+Ride for transit, times right-aligned |
| 3.7 | Rails hide on search | Type in the plan-sheet search field | Rails disappear while filtering (adjacency broken), return when cleared |
| 3.8 | Rail tap | Tap any rail | Opens the same leg sheet as the map chip |

## P4 — Overrides + travel profile

| # | Case | Steps | Expected |
|---|------|-------|----------|
| 4.1 | Mode switcher | Leg sheet → "Travel this leg" → pick a different mode | Spinner on chip → sheet closes → toast → that leg's polyline, chip, rail and travel times all update; totals update |
| 4.2 | Override no-route | Force Transit on a leg with no transit | Warning toast, sheet stays open, route unchanged |
| 4.3 | Override persists | Override a leg → re-optimize the day | The overridden leg keeps the chosen mode |
| 4.4 | Override per trip | Override in trip A; optimize trip B with same-ish geography | Trip B unaffected |
| 4.5 | Travel style chips | Optimize → start-point sheet → Travel style: Walking city / Road trip / Auto | Selection persists per trip (reopen sheet shows it); next optimize anchors accordingly (walk = dotted everywhere it can) |
| 4.6 | Beta warnings (compliance) | Open leg sheet for a walking leg; a motorcycle override | Footnote: "Walking/Two-wheeled routes are in beta…" present |
| 4.7 | Attribution (compliance) | Any leg sheet | "Route data: Google Maps" footer visible |
| 4.8 | Mode deeplink | Leg sheet → Open in Google Maps, for walk / transit / drive legs | Google Maps opens in the matching travel mode |

## Cross-cutting (regressions + perf)

| # | Case | Expected |
|---|------|----------|
| X.1 | Timing warnings still fire on tight schedules; durations reflect chosen modes |
| X.2 | Arrival detection (10 m ring) unchanged |
| X.3 | Moving current-location pin + heading beam unchanged during and after optimize |
| X.4 | Cold-start first optimize shows route on the FIRST run (fingerprint guard regression check) |
| X.5 | Performance overlay (`flutter run --profile`, press P): optimize → no sustained raster/UI red bars; idle map stays idle |
| X.6 | Guest (anonymous) user optimize works (profile key falls back to `no_trip`) |
| X.7 | Optimize with start = specific stop AND start = current location: rails/chips count and labels correct in both mappings |
| X.8 | Kill app mid-optimize → reopen: no corrupt state, re-optimize works |
| X.9 | Long trip day (10+ stops): first optimize completes < ~30 s worst case (sequential transit legs), later runs fast (cache) |
| X.10 | Google Cloud console after a QA day: Routes calls in the expected order of magnitude (≈ stops × modest factor, not stops × 4) |
