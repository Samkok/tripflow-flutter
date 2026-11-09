# VoyZa UX simplification — complete plan

**Status:** approved by Sam on 8 November 2026; implementation not started. This document is the source of truth for the work (mirrored at `~/.claude/plans/flickering-noodling-teapot.md`). Companion: the audit it answers, `docs/ux-flow-audit-2026-11-08.html`.

## Implementation status (2026-11-09)

Every phase below is implemented in the working tree (uncommitted; one commit per phase when Sam asks). Suite 761 tests green (baseline 638); `flutter analyze --no-pub` 67 infos, 0 warnings (baseline 85). No schema, RPC or edge-function change; every prefs key kept, so older builds keep working.

| # | Phase | Status | Notes |
|---|---|---|---|
| 0 | Groundwork | done | `test/helpers/{fakes,pump,shots}.dart`, `test/widgets/ux_surfaces_render_test.dart` (`VOYZA_UX_SHOTS_OUT=build/qa_shots/ux` exports PNGs) |
| 1 | Retire Activate | done | `setMapTrip/openTripOnMap/ensureMapTrip`, Switch-trip sheet, write access treats fetch errors as unknown |
| 2 | One add-place sheet | done | `AddPlaceSheet` (Search · Nearby · Paste link), `LocationAddService.addPlace`, `PlacesGateway`; the map keyboard shift still needs a device check |
| 3 | One place card + sheet | done | `OptimizedLocationCard` params, `LocationDetailSheet` top row + Details/Photos/Hours expanders |
| 4 | One itinerary | done | `place_selection_actions.dart`, trip page owns bulk actions + Export menu, plan sheet is the day list |
| 5 | One planning verb | done | `PlanSheet` (This day · Whole trip), `DayPlanPanel` with folded start/end tiles, `AutoPlanPanel`, `tripNeedsPlanAttentionProvider` |
| 6 | One-screen trip creation | done | `CreateTripScreen` (No dates yet · N days default), `BuddyNudgeRow` on the trip page, wizard deleted |
| 7 | Map chrome | done | 3 FABs, `MapSettingsSheet` (zone distance + persisted place names), Clear route in both summaries whenever a route exists (summaries not eye-checked headless) |
| 8 | One subscription surface | done | `ProStatusRow` + `proStatusProvider` + `pro_status_copy.dart`, trial block on the subscription screen, `pro_feature_gate.dart` deleted; `purchases_ui_flutter` now unused in lib but still in pubspec |
| 9 | First-session sequence | done | `FirstRunCoordinator`, consent after the first trip, no sign-up wall, `SaveTripsAccountCard`, map tour/location prompt suppressed in a session that showed a prompt (no blue dot until My location is tapped), dead celebration + referral banner removed. Sam's device checklist is in the Phase 9 section |

## Context

The UX flow audit of 8 Nov 2026 (`docs/ux-flow-audit-2026-11-08.html`) found VoyZa asks a traveller to learn the same job in several places: two full itineraries (map plan sheet and trip page, each with its own card and menu), six doors to add a place, three controls to decide which trip the map shows, four planning verbs, three paid-plan surfaces, four entrances to an ended trip's leftovers, five map buttons, an eight-tap trip wizard, and up to seven first-session prompts. Sam asked for one complete plan that simplifies the whole flow while every working function stays reachable and the app's performance conventions hold.

Three read-only code surveys and three design passes (verified against the working tree at `c43a636`) are the base. They corrected several audit claims:

- The plan sheet has **no** Unscheduled section and **no** add-place button (only an "Unscheduled (N)" pill → trip page). Paste-a-link lives inside the search screen. "Put all on one day" and the reschedule prompt are on the trip page / trips list.
- The trip page builds its **own** card (`_buildLocationCard`) with no Options menu; `OptimizedLocationCard` is used only by the plan sheet. Bulk actions: plan sheet 6, trip page delete only.
- Two search sheets do one job: `LocationSearchScreen` (685 lines) and the trip page's private `_LocationSearchSheet` (~750 lines), each with its own paste-link dialog.
- The Trips tab shows the active trip twice. The map has **no** empty state when no trip is active (`map_screen.dart:2128` returns the bare column).
- Every `TripNotifier` mutation (`markLocationsAsDone`, `skipMultipleLocations`, `updateMultipleLocationsScheduledDate`, `copyMultipleLocationsToDate`, `removeLocation`…) gates on `_hasWriteAccess()` of the **map trip** and reads `state.pinnedLocations`. The trip page avoided this by calling the repository directly for its one bulk action. A shared card/menu on the trip page therefore needs the trip to be the map trip first (Phase 1's `ensureMapTrip`).
- Dead code: `lib/app.dart` (+ `trip_history_screen.dart`, its only dependant), `search_widget.dart`, most of `pro_feature_gate.dart`, `showRevenueCatPaywall`, `TripRepositoryWithEvents`/`TripSyncService`/`TripEventService`/`activeTripsProvider`, `places_provider.dart`, the commented first-optimize celebration, `ReferralHomeBanner`.
- No screen being changed has a widget test (638 tests cover helpers, providers, engines). `flutter analyze --no-pub` today: **85 infos, 0 warnings**.

### Decisions already taken
- **Sam (asked 8 Nov):** post-onboarding Sign-up screen → replaced by a dismissible "Save your trips with an account" card after the first trip (Phase 9). Thin plan sheet at **full scope**: Whole-trip tab, sort toggle, multi-select + 6 bulk actions, CSV and Not-visited section leave the map sheet; bulk actions and CSV move to the trip page (Phase 4).
- **Mine, flagged:** the map shows the trip you last *opened on the map or edited a place of*. Viewing a trip page never switches the map (peeking at next month's trip while travelling leaves the map alone); the first place action on that page does, via a lazy `ensureMapTrip()` (≈50–100 ms: Hive re-filter through `filteredLocationsForMapProvider`). Alternative if device testing prefers it: switch eagerly on page open.
- `localActiveTripIdProvider` keeps its name and prefs key (`local_active_trip_id`); its meaning becomes "the trip the map shows". `OptimizedLocationCard` keeps its file name (a `PlaceCard` typedef for new call sites). No file renames for history's sake.

### Non-negotiables in every phase
- **No capability lost.** Everything reachable today stays reachable; some things move (bulk actions → trip page, CSV → export menu, place names + clear-route → sheets, buddies → trip page).
- **Performance conventions:** narrow `select` watches (never a full `tripProvider` watch in a list item), `MarkerCacheService`, `TickerMode` per tab, `skipLoadingOnReload`, overlay/marker providers untouched, slivers/builders for long lists, no camera move on add/remove, `SharedPrefsCache.maybeInstance` in anything that can run before first frame, `routeClearerProvider` kept.
- **No DB migration.** `trips.is_active` stays; inserts keep writing `false`; only dead client code goes.
- **Every commit:** suite green, `flutter analyze --no-pub` ≤ 85 infos and 0 warnings, `dart format` only on edited files, `git status` clean of stray paths (`android/local.properties` restored if a build touched it; never stage `supabase/.temp/cli-latest` or `GeneratedPluginRegistrant.java`). Commit only when Sam asks; one short message per phase; no push without his go.
- **Eye-checks:** every phase registers its new surfaces in the headless render test (Phase 0) and I hand Sam the PNGs; device runs are his.

---

## Phase map (dependency order)

| # | Phase | Size | What the traveller stops seeing |
|---|---|---|---|
| 0 | Groundwork: shared fakes, render harness, dead-code sweep | S | — |
| 1 | Retire "Activate": the map shows the trip you opened/edited last | M | Activate, Deactivate, summary card, Active section/filter, "ACTIVE NOW" |
| 2 | One add-place sheet: Search · Nearby · Paste a link | M–L | 5 of 6 doors, 2 search screens, 2 paste dialogs, the date confirmation in the common case |
| 3 | One place card + a place sheet with a top and a rest | M | a second card, 2 menu items, a 16-row wall |
| 4 | One itinerary: trip page plans, plan sheet is a thin companion | L | Whole-trip tab, map-side multi-select, sort toggle, 2nd Not-visited section, header pill, CSV button |
| 5 | One planning verb: "Plan" with two scopes | M | Re-optimize vs Auto-plan pill vs bottom button |
| 6 | One-screen trip creation | S | 5 of 8 taps, the buddies step |
| 7 | Map chrome: 3 buttons + one Map settings sheet | S | 2 FABs |
| 8 | One subscription surface | S | Free Trial section, banner duplicate, a button that opened the wrong screen |
| 9 | First-session sequence (+ Sam's device run) | S | the prompt pile-up before the first trip |

Phases 4, 5 and 7 all edit `trip_bottom_sheet.dart`; do them back to back. Phase 6 is independent and can slot anywhere. Rough net effect: ≈ −6,500 lines removed, ≈ +2,800 added (new sheets, helpers, ~30 tests).

---

## Phase 0 — Groundwork

**Add (helpers have no `main()`, so `flutter test` ignores them)**
- `test/helpers/fakes.dart`: `FakeTripNotifier extends StateNotifier<TripState> implements TripNotifier` + `noSuchMethod` (from `test/providers/pins_and_stop_dots_test.dart:16-22`), `FakeThemeNotifier`, `FakeTripRepository extends Fake implements TripRepository` (in-memory trips; recorders subclass it), `FakeSubscriptionNotifier`, `FakeLocalActiveTripNotifier extends StateNotifier<String?> implements LocalActiveTripNotifier` (the real one asserts on `SharedPrefsCache.instance`). Existing tests keep their private fakes.
- `test/helpers/pump.dart`: memoised `loadAppFonts()` (Roboto Regular/Medium/Bold for 'Roboto', 'monospace', '.SF UI Text', '.SF UI Display' — union of `trip_qr_card_test.dart:15-24` and `measurement_consent_dialog_test.dart:113-119`); `pumpVoyza(tester, child, {overrides, theme, physicalSize = 1170×2532, dpr = 3})` → view size + tearDown reset, `SharedPreferences.setMockInitialValues({})`, `UncontrolledProviderScope` + `MaterialApp(home: Scaffold(body: child))`, returns the container.
- `test/helpers/shots.dart`: `exportShot(tester, boundaryKey, path)` (the `runAsync` + `RenderRepaintBoundary.toImage` + PNG write from `measurement_consent_dialog_test.dart:155-163`).
- `test/widgets/ux_surfaces_render_test.dart`: env var `VOYZA_UX_SHOTS_OUT` (dir, e.g. `build/qa_shots/ux`, git-ignored); a `surfaces` map (builder + overrides) × {light, dark}; always asserts the widget renders (smoke), exports PNGs only when the env var is set; never pumps `MapScreen`/`MapWidget`/`GoogleMap`. Each later phase registers its surfaces here.
- `SharedPrefsCache.debugSetInstance(SharedPreferences)` (`@visibleForTesting`, `main.dart:50-73`) for widgets that read prefs synchronously.

**Dead-code sweep (prove each with grep; expected hits = the file's own lines)**: delete `lib/app.dart` + `lib/screens/trip_history_screen.dart` (7 infos), then drop `go_router` from pubspec if `grep -rn go_router lib pubspec.yaml` is empty (`flutter pub get`); `lib/widgets/search_widget.dart` → move `searchQueryProvider` (L18) beside `paginatedSearchProvider` until Phase 2 deletes its last user; `lib/providers/places_provider.dart` (both providers unused); `PlacesService.getPlaceFromGoogleMapsUrl` (L947-996). The Activate-era, subscription and first-run dead code is listed in Phases 1, 8, 9.

**Analyzer effect**: ≈ −16 infos from deletions → ~69, provided new code adds none (`const` constructors, `withValues(alpha:)`, block bodies).

---

## Phase 1 — Retire "Activate"

**Behaviour.** "Open on map" (trip card button, trip page button) and a new Switch-trip sheet (tap the map banner, or the empty-state pill) are the explicit ways to change the map's trip; editing a place on a trip page switches it lazily. No Activate/Deactivate anywhere; the card currently on the map carries an "ON THE MAP" eyebrow. Checklist step 3 → "Open your trip on the map" (prefs key unchanged). Write access for the map trip treats fetch errors as unknown (last answer, else proven ownership) and retries on reconnect/resume.

**Code-verified facts.** `hasActiveTripWriteAccessProvider` has two error paths (`trip_collaborator_provider.dart:294` → false; L304 unguarded await; `.future` awaiters in `location_search_screen.dart:192,339` and `map_screen.dart:1132` are not in try/catch). `deriveFromTrips` reads server `t.isActive`, which nothing writes (inert). `_setActiveTrip` has a third caller: sample trip `trip_screen.dart:552`. `mapDayFocusRequestProvider` is consumed only by the plan sheet's tab reset (removed in Phase 4) and bumped by `open_trip_on_map.dart:25`; `test/utils/open_trip_on_map_test.dart` tests only `mapLandingDayFor`.

**Add**
- `lib/utils/open_trip_on_map.dart`: `Future<bool> setMapTrip(WidgetRef ref, Trip trip)` (no-op when already shown; else `tripProvider.notifier.clearTrip()` → `localActiveTripIdProvider.notifier.setActiveTrip(id)` → `checklistProvider.notifier.mark(ChecklistStep.activateTrip, silent: true)`); `Future<void> openTripOnMap(ref, trip)` = `setMapTrip` + existing `requestMapForTrip`; `Future<void> ensureMapTrip(ref, trip)` = `setMapTrip` and, if it switched, await `tripProvider.notifier.stream.firstWhere(pins contain this trip)` with a 2 s timeout (pins repopulate through `filteredLocationsForMapProvider`, which restarts on the id select). Keep `requestMapForTrip`/`mapLandingDayFor` as they are, minus the `mapDayFocusRequestProvider` bump once Phase 4 deletes that provider.
- `lib/widgets/switch_trip_sheet.dart`: `showSwitchTripSheet(context, ref)`; glass chrome as `move_to_trip_sheet.dart:60-90`; rows from `userTripsProvider` + `sharedTripsProvider` (drop null embeds like `trip_screen.dart:231-235`), sorted by start date, current row checked "On the map", shared rows "Shared · Can edit/View only"; tap → `openTripOnMap` + pop; no trips → "Create a trip first" → `mainTabRequestProvider = 0`. No `tripProvider` watch.

**Modify**
- `trip_collaborator_provider.dart:283-305`: try/catch around the `hasWriteAccessProvider(id).future` await → return the previous answer (`ref.state.valueOrNull`; fallback a file-private `_lastWriteAnswer` if `ref.state` does not compile on flutter_riverpod 2.4.9), else ownership from the `userTripsProvider` cache, else false; on catch, listen to `connectivityProvider` (reconnect → invalidate) plus a 15 s one-shot retry (`ref.onDispose` cleans up); L294 `hasError → false` becomes `→ previous ?? false`. Keep both `deactivateTrip()` calls (membership lost).
- `main.dart:392-405` resume: invalidate `hasWriteAccessProvider(mapTripId)` and `userTripPermissionProvider(mapTripId)` when signed in.
- `optimized_location_card.dart:466`: `asData?.value ?? false` → `valueOrNull ?? false`.
- `trip_details_screen.dart`: delete `_setActiveTrip` L433-455, `_deactivateTrip` L457-467, the Activate pill L1766-1807; `_openOnMap` L473-499 → `await openTripOnMap(ref, _trip); popUntil(isFirst)` (drop the toast); add `_ensureMapTrip() => ensureMapTrip(ref, _trip)` and call it before: opening a place's detail sheet, any card action, bulk selection actions (Phase 4), Plan/Auto-plan (Phase 5). Auto-plan ✨ L747-760 and Unscheduled Plan L2364-2383 → gate on `tripCardStatsProvider.select(count ≥ 2)` (attention dot only when this is the map trip), `onPressed: () async { await _ensureMapTrip(); showAutoPlanSheet(context); }`.
- `trip_screen.dart`: remove `_TripFilter.active` (L50-59; fix switches L837-861 and the empty-state switch L1460-1481, rewording the `noDate` copy to "pick 'No dates yet' when you create one"); delete `_cardActivateKey`/`_activeGoToMapKey` L87-89, `_setActiveTrip` L430-474, `_deactivateTrip` L2826-2840, the summary sliver L1060-1080 with `_buildEmptyActiveTrip` L1736-1777 and `_buildActiveTrip` L1779-1866, the "Active Trip" section L1288-1337; `_goToMapForTrip` → `openTripOnMap`; sample trip L552 → `setMapTrip`; L783 watch `localActiveTripIdProvider` (sync, narrow) instead of `localActiveTripProvider`; `_filterAndSortSharedTrips` loses the `activeTripId` exclusion; card action row L2642-2731 → one "Open on map" `FilledButton.icon` (keyed `_cardOpenOnMapKey` on the first card for the coach), delete the Deactivate square L2721-2729; eyebrow `'ACTIVE NOW'` → `'ON THE MAP'` (L2472-2481; shared card L1955-1959, L2098-2143 likewise). Guide listener L760-782: `activateTrip` case coaches the Open-on-map button ("Tap Open on map — the map draws this trip day by day, and that is where Plan lives"); delete the `goToMap` case.
- `map_screen.dart:2128`: no trip → frosted pill "Pick a trip to show" → `showSwitchTripSheet`; L2200 `'Active Trip'` → `'On the map'`, banner wrapped in InkWell → `showSwitchTripSheet` with a swap icon; `_topChromeHeight` fallback constants L3319-3322; reword comments L90-91, L2019-2031. The existing `localActiveTripIdProvider` listener (L2024, `_pendingTripCameraMove`) is exactly the camera hook the switch needs.
- `onboarding_checklist_provider.dart`: keep `ChecklistStep.activateTrip`; remove `ChecklistGuide.goToMap` (L15-21); `deriveFromTrips` L226-236 → `_ref.read(localActiveTripIdProvider) != null`. `onboarding_checklist.dart:35-39`: "Open your trip on the map" / "Your places become pins, ready to route".

**Delete**: `lib/repositories/trip_repository_with_events.dart`; `tripRepositoryWithEventsProvider`, `tripEventServiceProvider`, `activeTripsProvider` (`user_trip_provider.dart:13-28, 47-60`) + its invalidate `settings_screen.dart:361`; `trip_listener_provider.dart:12-62` (`TripSyncService`, `tripSyncServiceProvider`, `tripEventStreamProvider`; keep `realtimeActiveTripProvider`, `activeTripDateRange`); `lib/services/trip_event_service.dart`; `trip_repository.dart:265-370` `getActiveTrip/setActiveTrip/deactivateTrip` (keep `'is_active': false` on insert L123 and in the copy path; keep `Trip.isActive` parsing); `ActiveTripSkeleton` (`trip_skeleton.dart:179-223`).

**Tests**: `test/utils/set_map_trip_test.dart` (first call clears/sets/marks, second no-ops; `openTripOnMap` sets allDaysMode=false, selectedDate, tab 1; `ensureMapTrip` returns once pins hold the trip); `test/providers/has_active_trip_write_access_test.dart` (throw → owned fallback true; reconnect re-evaluates; non-owned → false then true); `test/providers/checklist_derive_test.dart`; `test/widgets/switch_trip_sheet_test.dart`; register `SwitchTripSheet` in the render test.

**Order**: 1a helpers + write-access fix + card/main tweaks + tests → 1b trip page → 1c switch sheet + map → 1d checklist relabel + trips list (one commit; they compile together) → 1e dead-code deletion.

**Risks**: `ref.state` compile check; ~400 lines leave `trip_screen.dart` in one commit (self-contained slivers; analyze at baseline); stale `local_active_trip_id` already self-heals (`local_active_trip_provider.dart:140-155`).

---

## Phase 2 — One add-place sheet

**Behaviour.** The six doors (map search bar, trip FAB, per-day "+", empty-day placeholder, map long-press, accommodation prompt "Add a different place") open one glass `AddPlaceSheet` with segments **Search · Nearby · Paste a link**, bound to one trip (or none on a trip-less map) and one pre-filled day shown in the header ("Adding to Tokyo · Day 3"). One service method runs the duplicate guard, paywall, country guard, date confirmation, tag sheet, repository write, hours backfill, goal toast and accommodation prompt exactly once, and clears the map route immediately only when the target is the map trip. The sheet stays open for chained adds. "Add to trip" on a loose place (`AddToTripSheet` → `attachLocationsToTrip`) stays.

**Code-verified facts (why one service path is safe).** `TripNotifier.addLocation` (`trip_provider.dart:374-455`) has one caller; beyond `LocationRepository.addLocation` it only gates on write access (silent return), defaults the day to `selectedDateProvider`, stamps the map trip id, fires `placeAdded`, and synchronously clears route state + `selectLeg(null)`. No optimistic pin (pins come from the stream), no camera move, no checklist mark; `_initSyncListener` already clears the route on content change. `stayDuration` defaults agree (30 min). `PlacesService` is fully static (no test seam). `_findTripById` (`location_add_service.dart:57-64`) searches owned trips only, so the country/date guards are skipped for shared trips today; passing the `Trip` closes that gap.

**Add**
- `lib/services/places_gateway.dart`: `abstract class PlacesGateway { searchPaginated, details, fromCoordinates, fromAddress, nearby, nearbyByText, fromMapsLink }`, `StaticPlacesGateway` → `PlacesService.*`, `placesGatewayProvider`. `PaginatedSearchNotifier` (`paginated_search_provider.dart:37`) takes the gateway; delete `tripDetailSearchProvider` (L123-126).
- `PlacesService.resolveGoogleMapsLink(text)`: the live decode moved verbatim from `trip_details_screen.dart:3920-3961` (`isValidGoogleMapsUrl` → coords → `getPlaceFromCoordinates`; else `expandShortUrl` → `q` → `getPlaceFromAddress`); typed `InvalidMapsLink`.
- `LocationAddService.addPlace(context, PlaceDetails, {required Trip? trip, required DateTime? day, String? tag, bool tagConfirmed = false, bool skipLimitCheck = false, int stayDurationSeconds = 1800})` replacing `beforeAddingLocation` (L326-426) and `addSavedLocation` (L461-540). Steps: write access via `hasWriteAccessProvider(trip.id).future` in try/catch → `placeToSavedLocation(...)` (fields as `trip_details_screen.dart:4106-4129`) → `_isSavedDuplicateOnDay` (keep L297-315; delete `_isDuplicateOnDay` L276-292) → paywall unless `skipLimitCheck` → `assertLocationInTripCountry` → `confirmScheduledDate(allowExtension: !ended)` → `newDays` from this trip's saved rows (`_daysWithoutLocations` gets a `tripId` param; drop the `pinnedLocations` read L147) → tag via `_withConfirmedSavedTag` unless confirmed → `locationRepository.addLocation` → `if (trip?.id == localActiveTripId) tripProvider.notifier.clearRouteForEdit()` → `placeAdded`, hours backfill, date extension, goal toast, accommodation prompt. Delete `_withConfirmedTag` (L431-442). Keep `attachLocationsToTrip`, `resolveCountryCodeForModel`, `countryMismatchForMove`.
- `TripNotifier.clearRouteForEdit()` = the clear block L443-452 + `selectLeg(null)`; then delete `TripNotifier.addLocation`.
- `nearby_places_picker_sheet.dart`: extract `NearbyPlacesPickerBody` (L406-858) with `initialPlaces` (null → lazy `onRequery` in initState), `radiusMeters`, `onRequery`, `onSearchText`, `occupantsOnDay`, `scrollController`, `onConfirm(picked)`, `onCancel`; the three `Navigator.pop` sites (L456, L828, L843) become callbacks. Delete `NearbyPlacesPickerSheet`/`showNearbyPlacesPicker` once the long-press is rewired.
- `lib/widgets/add_place_sheet.dart`: `showAddPlaceSheet(context, {required Trip? trip, required DateTime day, AddPlaceSegment initial = search, LatLng? nearbyCenter, int? nearbyRadiusMeters})`; chrome from `trip_details_screen.dart:3519-3553` (DraggableScrollableSheet 0.9/0.5/0.95, glass); header + `SegmentedButton<AddPlaceSegment>`; shared busy overlay (L3641-3686); the sheet's scroll controller goes to whichever segment list is visible.
  - **Search**: `_buildSearchResults` (L3729-3875) + infinite scroll (L3506-3511) + 300 ms debounce, country-biased to `trip?.countryCode`; link icon switches to Paste; tap → `_isAlreadyOnDay` pre-check (generalised L3461-3486) → `details` → `addPlace` → toast, reset + refocus.
  - **Nearby**: `NearbyPlacesPickerBody` around `nearbyCenter` ?? the day's first stop of this trip ?? `mapCameraTargetProvider` ?? `tripProvider.currentLocation` (else an explainer with a "Search" button); confirm = `map_screen._addNearbyPlaces` (L1220-1310) logic: one `canAddPlaces(n)`, `Future.wait(details)`, per pick `addPlace(tag: pick.tag, tagConfirmed: true, skipLimitCheck: true)`, `clearHighlights` only for the map trip.
  - **Paste a link**: inline field + clipboard button (`google_maps_url_dialog.dart:21-31`) → `fromMapsLink` → `addPlace`; delete `google_maps_url_dialog.dart`.

**Wire the doors**: `map_screen.dart:2335-2350` search bar → `showAddPlaceSheet(trip: realtimeActiveTrip.valueOrNull, day: selectedDate)`, keeping `key: _searchBarKey` on the same Container (tutorial anchor) and removing the `PageRouteBuilder`; `_onMapLongPress` L1129-1212 keeps the write check (per-trip, try/catch) then opens Nearby with `nearbyCenter`; delete `_addNearbyPlaces`. `trip_details_screen.dart:3360-3391` → `showAddPlaceSheet(trip: _trip, day: day ?? _defaultAddDay())` (`_effectiveScheduledDate` L3903-3918 moved up unchanged); delete `_LocationSearchSheet` L3393-4159 + unused imports. `accommodation_prompts.dart:117-125` → keep `selectedDate = firstNewDay`, open the sheet. Delete `lib/screens/location_search_screen.dart`, `search_widget.dart` (and `searchQueryProvider`).

**Tests**: `test/widgets/add_place_sheet_test.dart` (fake gateway, fake repository recording rows, `savedLocationsProvider` stream, fake map-trip notifier, `FakeTripNotifier` recording `clearRouteForEdit`, write access true, Pro true): search→tag→row with tripId+day, `place_added` once, route cleared once; duplicate → warning, no row; non-map trip → row, no clear; paste → row; nearby two picks → two rows with tags; country mismatch → dialog, no row; outside dates → cancel, no row. `test/services/location_add_service_add_place_test.dart` (step parity, short-circuits, `day: null` = Unscheduled). `test/services/resolve_maps_link_test.dart`. Register `AddPlaceSheet` ×3 segments in the render test.

**Order**: 2a gateway + notifier ctor → 2b `addPlace`, `placeToSavedLocation`, `clearRouteForEdit`, `resolveGoogleMapsLink` + tests (old methods still live) → 2c `NearbyPlacesPickerBody` extraction behind the old wrapper → 2d sheet + widget tests + rewire six doors + delete the old screens/dialog/providers/methods (one coupled commit).

**Risks**: the map keyboard shift that justified a pushed search screen — verify on device in the first 2d build; the targeted fix is `MediaQuery.removeViewInsets` around the GoogleMap, not a resurrected screen. Accommodation prompt still self-gates on the map trip (unchanged; follow-up). In-progress search text no longer survives close/reopen (note in commit).

---

## Phase 3 — One place card, one place sheet with a top and a rest

**Behaviour.** One `OptimizedLocationCard` serves the plan sheet (today's look) and every trip-page list (days, Unscheduled, Not visited), keeping the trip page's drag handle, drag feedback, inline gallery (expanded there by default) and "Added <date>" line. Action row `[Done ✓] [Options ⋮] [Map]`; Options holds exactly Skip/Un-skip, Move to another day, Copy to another day, Move to another trip, Remove from trip, Delete. Gating uses `hasWriteAccessProvider(tripId)` and the card's own day. Detail sheet: top row Done · Skip · Route · Schedule; a "Details" expander (Tag + transport, Accommodation, Multi-day stay, Floor, Stay duration — new here, via `showStayDurationDialog`); Photos and Hours collapsed by default (session memory); Remove from trip and Delete at the bottom. Handlers unchanged.

**Code-verified facts.** The card's biggest per-card cost is `ref.watch(tripProvider.select((s) => s.pinnedLocations))` + `indexOf` + a full `highlightedLocationIndexProvider` watch (L68-72) — every card rebuilds on every trip-state change. It also full-watches `realtimeActiveTripProvider` (L630) and `hasActiveTripWriteAccessProvider` twice (L466, L625). `LocationDetailSheet` is a stateless `ConsumerWidget` (L41); its Hours section reads `selectedDateProvider` for the weekday (L1609) as well as for gating; the Floor line persists a lookup post-frame (L872-876). Trip-page cards are `SavedLocation`-typed with `Draggable<SavedLocation>` (L3285) — `SavedLocation.toLocationModel` exists (`location_model.dart:296`). `'done'/'undone'` menu values have no consumer outside the card.

**Modify `optimized_location_card.dart`** (+ `typedef PlaceCard = OptimizedLocationCard`)
- New optional params: `tripId`, `day`, `labeler`, `selectable` (default true), `photosExpandedInitially`, `footnote`, `trailing` (drag handle), `siblings` (→ sheet's `locationsForDate`), `onMapPressed`, `beforeAction` (`Future<void> Function()?`, awaited before opening the sheet or running any action — the trip page passes `_ensureMapTrip`).
- L68-75 → `ref.watch(highlightedLocationIdProvider.select((id) => id == location.id))` (new `Provider<String?>` in `trip_provider.dart` beside L2676: index → id once for the app) + selection watches only when `selectable`.
- One `hasWriteAccess` select (`hasWriteAccessProvider(tripId)` when given, else `hasActiveTripWriteAccessProvider`), one `isPastDay` from `day ?? selectedDate` (bucket rows with `tripId` and no day → not past); thread into `_buildStayButton`, `_buildActions`, `_buildPopupMenu` (delete their watches L465-471, L625-631, L653-655).
- `_buildActions` L276-344: Photos/Hide button (L293-306) → a chevron at the end of the title row (copy `trip_details_screen.dart:3241-3257`); first slot = Done/Undo `FilledButton.icon` (bodies of L762-765); Map → `onMapPressed ?? today's L320-335`.
- Menu L624-744: delete done/undone items L678-694 and branches L762-765; `move_trip`/`remove_from_trip` conditions → `tripId != null && hasWriteAccess`. `_showMoveCopyDialog` L814-908: initial date = `day ?? selectedDate`; write `selectedDateProvider` (L906) only when `day == null || day == selectedDate` (plan sheet follows the move; trip page never yanks the map's day). `_showDeleteConfirmationDialog` L910-991: `day ?? selectedDate`. Header L228-270: `trailing` slot; footnote after the hours row; checkbox only when `selectable && isSelectionMode`.
- Plan-sheet call sites (`trip_bottom_sheet.dart:1970, 2157, 2240, 2277`): add `tripId: mapTripId, day: selectedDate` (one `realtimeActiveTripProvider.select(id)` in the parent; Not-visited cards pass `day: null`).

**Modify `trip_details_screen.dart`**: `_buildLocationCard` L3109-3358 → a ~35-line `OptimizedLocationCard(...)` call (`location: saved.toLocationModel()`, `number`, `showNumber: false`, `tripId`, `day`, `labeler: _labeler`, `photosExpandedInitially: true`, `footnote: 'Added …'` (L3221 format), `trailing: _buildDragHandle(saved)` (L3262-3330 extracted verbatim), `siblings`, `beforeAction: _ensureMapTrip`, `onMapPressed: () async { await _openOnMap(); selectedDate = day; mapZoomToLocationRequest = coords; }`); `_buildDragFeedback` L2912 and the `DragTarget<SavedLocation>` L2583 unchanged; delete `_photoCollapsedIds`.

**Modify `location_detail_sheet.dart`**
- `build` L71-82: compute once `hasWriteAccess` (tripId-aware) and `gateDay = tripId != null ? (location.scheduledDate ?? selectedDate) : selectedDate`; thread into every section; delete the per-section watches L214-218, L350-353, L691-693, L910-913, L1604-1607, L1840-1843; L1609 → `gateDay`.
- Header L705-856: title row stays; action row L711-768 → four `_LabeledAction`s: Done (L749-766), Skip (L728-747), Route → new `_showRouteActions` (a small sheet: `_RouteFromHereButton` when `locationsForDate == null`, From / To → `_pickAndPreviewRoute`, Open in Google Maps → `_openGoogleMaps`), Schedule → `_reschedule` (closure L976-1077 moved verbatim). Delete leaves the header.
- Body L908-1240: keep "Add to trip" (L926-960); remove the Schedule/Google Map row L964-1114, `_RouteFromHereButton` block L1122-1131, From/To builder L1139-1207 and Remove-from-trip L1214-1237 (moved as above / into `_buildDangerZone`).
- Scroll column L120-172: body → `_SectionExpander('Details', [tag, accommodation, multi-day, floor, new `_buildStayDurationRow`])` → `_SectionExpander('Photos')` → `_SectionExpander('Hours')` → travel info → added by → `_buildDangerZone` (Remove from trip, Delete full-width). `_SectionExpander` = plain conditional child (no `AnimatedSize` in this intrinsic column, per the card's comment L127-131). Expanded flags live in a new `lib/providers/detail_sheet_ui_provider.dart` (three `StateProvider<bool>`, session memory, overridable in tests).

**Tests**: `test/widgets/optimized_location_card_test.dart` (Options shows the six labels and no "Mark as Done"; Done disabled without write access; `day: today` with `selectedDateProvider` in the past → Skip/Move enabled); `test/widgets/location_detail_sheet_test.dart` (Done/Skip/Route/Schedule present, Tag hidden until Details, Delete once at the bottom; pump with `tripId` + `locationsForDate` so `_RouteFromHereButton` stays out). Register card (plan-sheet look, trip-page look) and sheet (collapsed, Details open) in the render test.

**Performance**: per card today 1 whole-list select + 1 full index + 3 full `AsyncValue` watches + `selectedDate` + 2 selection watches → after: 1 bool select (highlight) + 1 bool select (write) (+2 selection selects on the trip page only). Detail sheet: 6 write-access watches → 1; Floor/Hours lookups become lazy.

**Order**: 3a providers → 3b card params + action row + plan-sheet call sites + test → 3c detail sheet restructure + test → 3d trip page swaps to the shared card (with `selectable: false` until Phase 4 wires selection).

---

## Phase 4 — One itinerary (trip page plans, plan sheet is a thin companion)

**Behaviour.** Trip page: long-press → selection with the six bulk actions (Delete, Move to another day, Move to another trip, Skip, Mark as Done, Copy to another day) in the selection app bar; an Export menu (Itinerary PDF, Trip CSV) replaces the PDF icon; the Not visited section is the one home with cards + Review; per-day sort kept. Plan sheet: one list for the selected day in route order when a route exists, else added order (oldest first — new places append under the thumb, never reflow; From/To and CSV already read ascending); no selection, no CSV, no tabs, no sort toggle; a one-line "N places you didn't visit · Review" row when the trip ended (the Jump-sheet row and the banner remain the on/off doors for the map preview); search no-match offers cross-day jumps and "Open trip page".

**Code-verified facts.** Trip page bulk delete bypasses `TripNotifier` (`trip_details_screen.dart:261-264` repository call) because the trip may not be the map trip — `_ensureMapTrip` (Phase 1) makes the shared helper safe. `CsvService` uses `date` only for the file name (`csv_service.dart:61-65`); whole-trip CSV is one call with `date: null`. The Whole-trip tab groups unscheduled rows under `addedAt` (a quirk that goes with it).

**Add** `lib/widgets/place_selection_actions.dart` (~300 lines): `trip_bottom_sheet.dart:2922-3208` moved verbatim into top-level functions `(context, ref, {required BuildContext promptContext})`: `deleteSelectedPlaces({DateTime? day})` (null → `removeLocation` per id — the trip page's semantics; non-null → `removeLocationsFromDay`), `moveSelectedPlacesToDay`, `copySelectedPlacesToDay`, `moveSelectedPlacesToTrip`, `skipSelectedPlaces`, `markSelectedPlacesDone`, `clearPlaceSelection`, `buildPlaceSelectionMenu(...)` (= the `PopupMenuButton` L1229-1333). Drop the `selectedDateProvider` writes (L3076, L3146): the trip page does not follow the map's day. Selection providers stay in `map_ui_state_provider.dart:127-129` (comment updated: "trip page selection; read by the shared card when `selectable`").

**Modify `trip_details_screen.dart`**: delete `_selectionMode`/`_selectedIds`, `_enterSelectionMode` L213, `_exitSelectionMode` L220, `_toggleSelection` L227, `_deleteSelected` L238-266; read `isSelectionModeProvider`/`selectedLocationsProvider` in `build`; select-all tri-state L690-714 writes the provider from `_currentTripLocations`; the delete icon L705-709 → `buildPlaceSelectionMenu` (each action awaits `_ensureMapTrip` first); bottom bar L835-851 keeps "Delete N" → `deleteSelectedPlaces(day: null)`; reset both providers in `dispose` (L426). Export: L745-757 → `PopupMenuButton` 'Itinerary PDF' → `_exportItinerary`, 'Trip CSV' → `_exportCsv()` (`CsvService().generateAndShareTripCsv(rows.toLocationModel(), tripName, date: null, dayLabeler: _labeler)` with the `MissingPluginException` toasts from `trip_bottom_sheet.dart:2838-2860`). Cards now `selectable: true`.

**Modify `trip_bottom_sheet.dart`** — remove: `SingleTickerProviderStateMixin`, `_tabController` (L85-87, L154, L163), `_lastDayFocusReq` + the watch-and-compare L312-330, the `ListenableBuilder` wrapper L655-657/789 and every `onSelectedDateTab` branch (L666-667, L688-692, L709-710, L744-771 keep only the selected-day `Column`); selection: Consumer L496-502 → `_buildDefaultHeader`, delete `_buildSelectionModeHeader` L1127-1345 and handlers L2922-3208, cards `selectable: false`; `_buildLocationsTabBar` L2427-2458, `_buildAllLocationsGroupedByDate` + `_buildDateGroupHeader` L2460-2680, `_withoutEndedLeftovers` L1899-1903; `_buildCsvDownloadButton` L2820-2871 (+ now-unused imports); `_activeNewestFirst` L175 and the toggle L2112-2130 (keep the "Route order" label; L2016-2020 → sort by `addedAt` ascending); `_buildUnvisitedSection` L1909-1981 → `_buildUnvisitedRow` (~25 lines, watches `endedTripUnvisitedProvider.select(length)`); header Not visited pill L917-963. `_buildNoSearchMatches` L2376-2425: drop `dayScope`; show up to 8 cross-day hits (`pinnedLocations.where(_matchesQuery)`, only in this branch) with the day label; tap scheduled → `allDaysMode = false; selectedDate = that day` (query stays, `routeClearerProvider` clears the stale route as the old date-header tap did); unscheduled → push `TripDetailsScreen`; below, `OutlinedButton.icon('Open trip page')` (reuse L874-879). Delete `mapDayFocusRequestProvider` (`map_ui_state_provider.dart:138-143`) and its bump in `open_trip_on_map.dart:23-25`.

**What stays in the sheet**: `build`, `_buildDefaultHeader` (reworked in Phase 5), `_buildDatePicker`, `_buildHistoryBanner`, both summaries, `_buildEmptyDateState`, `_buildUnvisitedRow`, `_buildLocationsListWidgets` (cards + `LegRail` + Done/Skipped sections), plan search (`_buildPlanSearchField`, `_buildNoSearchMatches`, the memo/dedupe helpers), `_dragSheetBy`/`_snapSheet`, formatters, `_sheetStaticGlow`, `routeClearerProvider`, `viewHistoricalRouteProvider`, `ahaThreshold`, `collapsedSize`, `optimizeKey`, `onLocationTap`. Estimated: 4263 → ~2200 lines (incl. ~1030 moved out by Phase 5).

**Tests**: `test/widgets/place_selection_actions_test.dart` (a recording `TripNotifier` fake; `deleteSelectedPlaces(day: null)` after confirm records two `removeLocation` calls and clears selection; `markSelectedPlacesDone` records the set). `ended_trip_unvisited_test.dart` is provider-level and stays green. Register the trip-page selection bar in the render test (the sheet needs its DraggableScrollableSheet host; the no-match block is checked manually).

**Performance**: the sheet drops the Whole-trip tab (which built every card of the trip in one `Column`), the header pill's whole-list select, the `_tabController` body rebuilds; plan-sheet cards stop watching selection. Trip page: selection goes from `setState` on the whole page to two narrow selects per card + one app-bar watch; slivers unchanged.

**Order**: 4a helper file (copied, unwired) → 4b plan-sheet removals + search rows + `mapDayFocusRequestProvider` removal → 4c trip page (providers, menu, export, dispose reset, `selectable: true`) + helper test.

---

## Phase 5 — One planning verb: "Plan" with two scopes

**Behaviour.** One "Plan" CTA in the plan-sheet header (same `optimizeKey` for the coach, same glow; amber dot when the trip needs attention; "Add N more to optimize" below 2 stops; "View Route" on a past day with a route; spinner while optimizing). It opens `PlanSheet` with a segmented control **This day | Whole trip**. This day = today's start-point content (travel style, start/end, start time) with the primary button enabled immediately on the auto-picked start and the start/end tiles in an expander (collapsed on a first optimize, open on re-optimize). Whole trip = today's Auto-plan body with its Pro gate, spinner and Undo untouched. A status strip under the segments shows the in-flight state of either scope. Gone: the banner `_AutoPlanPill`, the sheet's bottom Optimize button, the first-ever silent skip. Trip page ✨ and the Unscheduled "Plan" open the sheet on Whole trip. "Put all on one day" stays on the Unscheduled header (scheduling, not routing); the reschedule-on-date-change prompt stays (a required decision).

**Code-verified facts.** `_StartPointSheet` + helpers span `trip_bottom_sheet.dart:3233-4263` (~1030 lines; its `build` full-watches `tripProvider` — modal-only, tolerable). `AutoPlanSheet` owns its own `DraggableScrollableSheet` + header (`auto_plan_sheet.dart:80-140`), so embedding needs a body/chrome split. The amber-dot logic is duplicated verbatim in `map_screen.dart:3680-3691` and `trip_details_screen.dart:789-802`.

**Add**
- `lib/widgets/day_plan_panel.dart` (~1000 lines, verbatim move of L3256-4263): `DayPlanPanel({required ScrollController scrollController, required bool isReoptimizing})`; strip the modal chrome from `build`; start/end tiles in an expander (`_startEndOpen = isReoptimizing`); confirm body L3898-3918 unchanged (pops the enclosing modal). Imports follow (`leg_mode_prefs`, `places_service`, `geo_utils`, `trip_simulation_provider`; the `review_prompt_service` import leaves the sheet).
- `auto_plan_sheet.dart`: split into `AutoPlanPanel({scrollController, onBusyChanged})` (state L47-78, `_buildForPlan` L142, `_setTripDates` L177, `_buildProposal` L200, `_apply` L418 unchanged) and the existing `AutoPlanSheet` wrapper keeping L80-140 chrome — every finder in `auto_plan_sheet_trip_times_test.dart` stays identical.
- `lib/widgets/plan_sheet.dart` (~250 lines): `enum PlanScope { day, trip }`, `showPlanSheet(context, {initial})`, `PlanSheet` (DraggableScrollableSheet .75/.4/.95; header; `SegmentedButton<PlanScope>`; `_PlanStatusStrip` watching `isGeneratingRouteProvider` and the panel's `onBusyChanged`; day body guarded by `allDaysModeProvider` ("Pick a day on the map first") and `locationsForSelectedDateProvider.select(length) == 0` ("Add places to this day first")).
- `tripNeedsPlanAttentionProvider` (`Provider<bool>` in `day_distribution_provider.dart`): `unscheduledCount > 0 || any day > 12 stops` — one copy of the duplicated logic.

**Modify**: `trip_bottom_sheet.dart` header Consumer L955-1102 → states in order: past day with route → "View Route" (body from L2748-2770); `0 < count < ahaThreshold` without route → the nudge pill (L1009-1038); generating → spinner; else → "Plan" (dot from the new provider, `onTap: showPlanSheet(initial: allDaysMode ? trip : day)`, `canTap = (hasLocations || allDaysMode) && !isGenerating`, `key: optimizeKey`); delete `_buildOptimizeButton` L2681-2819, `_onOptimizePressed` L2879-2910, `_showChooseStartPointDialog` L2912-2920. `map_screen.dart`: delete `_AutoPlanPill` L3673-3756 and its placement L2273-2278. `trip_details_screen.dart`: ✨ L781-831 and Unscheduled Plan L2373 → `await _ensureMapTrip(); showPlanSheet(context, initial: PlanScope.trip)`, dot from the shared provider.

**Tests**: keep `auto_plan_sheet_trip_times_test.dart` green (wrapper kept); add `test/widgets/plan_sheet_test.dart` (same fixture: 9 places, trip without `countryCode`, `currentLocation == null`; `initial: trip` → 'Whole trip' selected and 'Arrival and departure' found; tap 'This day' → 'Optimize' confirm + 'Travel style' found). Register `PlanSheet` ×2 segments in the render test.

**Risks**: `DayPlanPanel` must scroll with the PlanSheet controller (hand it the controller instead of nesting a scroll view — verify L3448-3944 during the move); dropping the first-ever silent skip adds one tap to the first aha (mitigated by the pre-enabled primary button and collapsed tiles).

**Order**: 5a `AutoPlanPanel` split → 5b `DayPlanPanel` move (old `_showChooseStartPointDialog` wraps it temporarily) → 5c `PlanSheet` + provider + header CTA + deletions + trip-page rewiring + test → 5d unused-import sweep in `trip_bottom_sheet.dart` and `map_screen.dart`.

---

## Phase 6 — One-screen trip creation

**Behaviour.** "New Trip" opens `CreateTripScreen`: name (required, autofocus), country chip ("Add a country · optional", prefilled from `tripFormPrefillProvider`, `kClearCountry` clears), dates row defaulting to "No dates yet · 3 days" with a −/+ stepper (1–60) or "Pick dates" → range picker (flips the row; "No dates yet" flips back), one "Create trip" button, footnote "You can invite travel buddies from the trip page." Identical for guests and signed-in users. After create: `pushReplacement(TripDetailsScreen(trip, celebrateFirstTrip))` as today. The trip page shows a dismissible "Planning with someone? Invite a travel buddy" row for signed-in owners with no collaborators or pending invites.

**Add** `lib/screens/create_trip_screen.dart` (`initialCountryCode`; test seams `onCreated`, `pickDateRange`): `_create()` = wizard `_confirm` (`create_trip_wizard.dart:204-267`) minus the buddy block — same userId resolution (`currentUserIdProvider ?? AnonymousUserService.id`), `createTrip(startDate: _dates?.start ?? tripDatesTbdAnchor, endDate: _dates?.end ?? shiftTripDay(anchor, _days-1), datesTbd: _dates == null, countryCode)`, `userTripsProvider` invalidate, `tripCreated`, checklist `mark(createTrip)` + `ChecklistGuide.addLocations` pre-arm (L249-258). Reuse `_pickerTile` (L516-565) and the stepper row (L664-693). `_BuddyNudgeRow` in `trip_details_screen.dart` after the info card: signed in ∧ owner ∧ `tripCollaboratorsProvider` empty ∧ `pendingInvitesProvider` empty ∧ prefs `buddy_nudge_dismissed_<tripId>` unset; tap → `_showCollaboratorsSheet()` (L907-917); ✕ → set pref.

**Modify** `trip_screen.dart:38, 424, 739` → `CreateTripScreen`; reword L1477-1479 and comment L727-728. **Delete** `lib/screens/create_trip_wizard.dart` (798 lines; referenced only from trip_screen; no tests).

**Tests**: `test/screens/create_trip_screen_test.dart` (modelled on `copy_trip_wizard_test.dart`): undated default → anchor dates, `datesTbd: true`, `onCreated(wasFirstTrip: true)`; stepper → 5 days; `pickDateRange` seam → dated; `'jp'` → `'JP'`, `''` → none; repository throws → toast, button re-enabled; exactly one `trip_created`. `test/widgets/buddy_nudge_row_test.dart`. Register `CreateTripScreen` ×2 states in the render test.

**Out of scope, flagged**: onboarding sends guests to the Map tab instead of the create form (`onboarding_screen.dart:199-205`); with creation identical for guests it could prefill the form for them too (Phase 9 already stops the Map-tab request).

**Order**: 6a screen + tests (wizard still live) → 6b switch trips list, delete wizard → 6c nudge row + test.

---

## Phase 7 — Map chrome: three buttons + one Map settings sheet

**Behaviour.** FAB column keeps My location, Fit (when the day has pins), Share (glow, when a route exists). The sheet-header tune icon ("Map settings") opens one sheet: Zone distance slider + tappable value chip (manual dialog unchanged) → divider → "Show place names" switch, now persisted (`map_show_place_names`). "Clear route" moves into the route summary beside the share icon (full) and as a small ✕ in the compact strip; shown when a route exists, not generating, not a past day. The share FAB and the summary share icon never coexist on screen (the full summary needs ≥360 px of sheet, where the FAB column is faded and pointer-ignored), so both stay.

**Code-verified facts.** `showPlaceNamesProvider` (`map_ui_state_provider.dart:111`) is an unpersisted `StateProvider`. The compact summary (`trip_bottom_sheet.dart:1474-1558`) has no share icon. `clearOptimizedRoute` (`trip_provider.dart:2347-2359`) is a pure in-memory `copyWith`; routes are never persisted per day. Comment at `trip_bottom_sheet.dart:2814` ("Clear is available from the map's FAB column") must change.

**Add** `lib/widgets/map_settings_sheet.dart`: `showMapSettingsSheet(context)` + public `MapSettingsSheetBody` (ConsumerWidget, pumpable): chrome from `map_screen.dart:1394-1412` (`withValues(alpha:)`), slider block L1470-1506 verbatim (preview via `updatePreviewValue`, commit via `setValueImmediately`), `SwitchListTile.adaptive('Show place names')` bound to `showPlaceNamesProvider`, Done; `showManualZoneDistanceDialog(context, ref)` moved from `map_screen.dart:1530-~1600` (check `_formatDistance` callers before moving it).

**Modify**: `map_ui_state_provider.dart:111` → reads `SharedPrefsCache.maybeInstance?.getBool('map_show_place_names') ?? true`, persists via `listenSelf` (stays a `StateProvider` so `pins_and_stop_dots_test.dart:138` compiles). `map_screen.dart`: delete the clear FAB L2629-2646, the place-names FAB + stale comment L2647-2664, the `showPlaceNames` local L2585-2586 (keep `hasSelectedDayRoute`), `_showProximitySliderBottomSheet` L1385-1528 and the manual dialog; pass `onShowMapSettings: () => showMapSettingsSheet(context)` at L2700 (restyle listener L2060-2066 and `_onMapCreated` L1120 untouched). `trip_bottom_sheet.dart`: rename `onShowZoneSettings` → `onShowMapSettings` (L46, L57, L149, L1116), tooltip "Map settings"; `_buildTripSummary` L1670-1708 adds a tonal "Clear route" `IconButton` after share (disabled while `isGeneratingRouteProvider`, shown when `hasRoute && !hideEta`); `_buildCompactTripSummary` L1502-1556 adds a 22 px ✕ under the same condition (≈ +6 px against the 0.25 collapsed size — eye-check in the render test at 1170×2532 and 750×1334; drop the compact ✕ if it overflows); update comment L2814.

**Tests**: keep "the names switch leaves the pin markers untouched" green; add `test/widgets/map_settings_sheet_test.dart` (switch flips the provider; slider changes the preview provider). Register `MapSettingsSheetBody` and both summaries in the render test.

**Order**: 7a provider persistence → 7b sheet file + header rename + delete the two map methods → 7c Clear in both summaries → 7d delete the two FABs.

---

## Phase 8 — One subscription surface

**Behaviour.** Settings' first item is one state-aware row: not Pro → gradient card "VoyZa Pro — Unlock unlimited places" with an "Upgrade" pill (sells like today's banner); trial → "VoyZa Pro trial — Ends in N days"; Pro → "VoyZa Pro — Renews d MMM yyyy" / "Expires …" / "Lifetime". Tap always opens `SubscriptionManagementScreen` (refresh on return), whose status card gains a trial block: time left, a progress bar sized from the real trial span (no 3-day constant), and one sentence on what happens when the trial ends, built from `SubscriptionLimitService.freePlaceAllowance` (the number the Terms state in words). Gone: the Free Trial section, `ProUpgradeBanner`, `_buildSubscriptionTile`, `_TrialStatusTile` (whose "Manage subscription" opened the paywall). `TrialCountdownBanner` stays app-wide (the only trial reminder outside Settings) but taps open the management screen. `PromoDaysCard` untouched. `showPaywall(trigger)` remains the single paywall entry.

**Code-verified facts.** `showPaywall(` direct callers: copy_trip_wizard L227, settings L1454, subscription_management L383, trial_countdown_banner L104, auto_plan_sheet L426, pro_feature_gate; place-limit gates go through `SubscriptionLimitService`. `_TrialStatusTile`'s 3-day assumption only drives its progress bar; `TrialCountdownBanner._format` duplicates its countdown. `pro_feature_gate.dart` is imported only by settings. No caller passes `preferNative`.

**Add**: `lib/utils/pro_status_copy.dart` (pure Dart: `ProTier`, `ProStatus`, `describeProRow(status, {now, formatDate})`, `formatRemaining(Duration)`, `trialEndsSentence(status, {freePlaces, now, formatDate})`, `planNameFor(productId)`; trial subtitle: `<24 h` → "Ends in N hours", `≤36 h` → "Ends tomorrow", else "Ends in N days"; pro: willRenew true/false/null → Renews/Expires/Active; `expiresAt == null` → Lifetime); `proStatusProvider` (sync `Provider<ProStatus>` beside `isInTrialProvider`, `subscription_provider.dart:80`, from the active entitlement with DB-first fallbacks so a RevenueCat cold start never flashes "Unlock"); `lib/widgets/pro_status_row.dart` (`ProStatusRow`: free tier reuses the gradient from `pro_feature_gate.dart:264-283, 345-359`; other tiers reuse settings L428-481; tap → `navigateToSubscriptionManagement` then `refresh()`).

**Modify**: `settings_screen.dart` L73-77 → `const ProStatusRow()`; delete L95-101, L103-106, `_buildSubscriptionTile` L425-482, `_TrialStatusTile` L1320-1473, the `subscriptionState` watch L48, imports `dart:async`, `paywall_screen.dart`, `pro_feature_gate.dart`. `subscription_management_screen.dart` `_buildStatusCard` L83-173: trial block (title "VoyZa Pro trial", `formatRemaining`, progress only when `trialStartedAt` known, `trialEndsSentence`), 1-minute `Timer.periodic`. `trial_countdown_banner.dart`: `_format` L74-88 → `formatRemaining`; tap L102-105 → push `SubscriptionManagementScreen` via `navigatorKey`. `paywall_screen.dart`: delete `showRevenueCatPaywall` L1477-1493 and the `preferNative` branch (L1522-1539 → `showCustomPaywall`); drop the `purchases_ui_flutter` import (pubspec removal in a separate commit if then unused). **Delete** `lib/widgets/pro_feature_gate.dart`.

**Tests**: `test/utils/pro_status_copy_test.dart` (every tier/branch; both `trialEndsSentence` branches mention "10 saved places" for `freePlaces: 10`); `test/widgets/pro_status_row_test.dart` (`proStatusProvider.overrideWithValue` ×4; tap pushes, via `NavigatorObserver` or `FakeSubscriptionNotifier`); `trial_offer_test.dart`, `plan_pricing_test.dart` unchanged. Register `ProStatusRow` ×4 in the render test.

**Order**: 8a util + test → 8b provider → 8c row + test → 8d settings swap + deletions → 8e management trial block → 8f banner retarget → 8g delete `pro_feature_gate.dart`, `showRevenueCatPaywall`.

---

## Phase 9 — First-session sequence (Sam's device run closes it)

**Behaviour (fresh install, guest).** Splash → Trips tab → onboarding first, nothing before it → Trips tab with the checklist (no forced Sign-up screen) → user creates the first trip → ~0.6 s after the trip list turns non-empty, the measurement consent (EEA/UK/CH) or the one-time notice (elsewhere) appears once → guests then see a dismissible "Save your trips with an account" card on the Trips tab → first-place toast → paywall at place 11. No map tutorial, no automatic location prompt, no ATT in that session (an explicit My-location tap still prompts). Next launch with a trip: ATT (iOS, ads allowed) at startup; Map tab: tutorial on an empty board, then the location prompt. Existing installs: unchanged.

**Why deferring consent is legal (verified).** `decideMeasurement` (`measurement_decision.dart:92-119`) yields analytics=false, ads=false in consent regions until a choice; Firebase collection is declared off natively (`main.dart:208-210`) with Consent Mode denied; Meta's SDK starts only from `MetaAdsSink.setEnabled(true)`, which `_reapply` (`measurement_consent_service.dart:352-380`) issues only after consent/notice. Moving the prompt later starts nothing earlier.

**Gate order**
```
STARTUP (main_screen.dart initState post-frame, after sync ≤3 s)
  S0 tab publish, trip-link mounted, rollover toast, sync        (unchanged L50-78)
  S1 if !linkSeen && needsOnboarding → Onboarding                 session.onboardingShown
  S2 if hasTrip → consent/notice (session.consentShown) else arm FIRST_TRIP
  S3 if adsMeasurement && hasTrip && !session.consentShown → ATT
  S4 bump mapTutorialRecheckProvider                               (unchanged)
FIRST_TRIP (main_screen build: ref.listen(userTripsProvider) — MainScreen is always on stage)
  empty/loading → non-empty, once per session: post-frame + 600 ms → consent/notice
MAP (map_screen): _maybeStartMapTutorial L317 and _openLocationGate L411 return early
  when FirstRunCoordinator.instance.anyPromptShown (onboarding || consent)
```

**Add** `lib/services/first_run_coordinator.dart` (~80 lines): singleton with the session booleans + pure `startupSteps({linkSeen, needsOnboarding, hasTrip, adsMeasurement, consentShownThisSession})` and `shouldAskConsentOnTrips({wasEmpty, isNonEmpty, alreadyAsked})`; `test/services/first_run_coordinator_test.dart` (fresh guest; via trip link; returning user; consent pending; ads vs legacy build). `lib/widgets/save_trips_account_card.dart`: guest-only, shown once trips exist, dismissible (`save_trips_card_dismissed_v1`), copy "Save your trips with an account — they stay on this phone until you do", CTAs Create account / Sign in; slot: `trip_screen.dart` after the `PromoDaysCard` sliver (L1149, the reserved async slot). Truthful: `syncLocalTripsToAccount` (`location_provider.dart:203`) merges local trips at sign-in.

**Modify**: `main_screen.dart:79-110` reorder per `startupSteps`, consent wrapped in `if (hasTrip)`, FIRST_TRIP listener beside L174; `measurement_consent_dialog.dart:27-53` `maybeShowMeasurementPrompts` and `analytics_consent_dialog.dart:8` return `Future<bool>`; `onboarding_screen.dart`: `maybeShowOnboarding` returns `Future<bool>`, delete the SignupScreen push L46-53, stop sending guests to the Map tab L198-201 (it fought signup's tab-0 request), drop the stale "guests can't create trips" comment L34-36; `map_screen.dart` two early returns; `signup_screen.dart:285` tab-0 write stays harmless.

**Also**: remove dead prompts — first-optimize celebration (`map_screen.dart:1826-~1870` commented listener, `trip_provider.dart:2241-2250`, `firstOptimizeCelebrationTrigger` L2693, `showFirstOptimizeCelebration` + `_FirstOptimizeDialog` `celebration_dialogs.dart:102-318`, commented import `map_screen.dart:70`; keep `OnboardingMilestone.firstOptimize`), `ReferralHomeBanner` (`trip_screen.dart:1048-1057` + L42, `referral_prompt.dart:93-~160`, `referralBannerDismissedProvider` `referral_provider.dart:54`). Optional: `PaywallTrigger.trialExpired` (never passed).

**Trade-off to flag**: session-wide suppression of the location latch means no blue dot in session 1 unless My location is tapped; the alternative is a 10 s cool-down after a prompt.

**Sam's device checklist (iOS + Android, EEA and non-EEA)**: fresh install → no dialog before onboarding → straight to Trips with the checklist → Map tab and back: no tour, no location prompt, no ATT; My-location tap prompts → New Trip (one screen) → within ~1 s consent/notice once → "Save your trips" card below New Trip, ✕ sticks across relaunch → first place via the new sheet → toast only → kill/relaunch: no onboarding/consent; iOS ATT once; Map tab tour only on an empty trip, then location → Settings shows one Pro row and the measurement switches reflect the answer → trip-link cold start: onboarding skipped, consent after the copied trip lands.

---

## How the work will run

- **One phase at a time, in the order of the phase map.** Each phase is implemented in its listed sub-steps (1a, 1b, …), so the suite is green and the analyzer at or under baseline after every sub-step.
- **After each phase:** `flutter analyze`, `flutter test`, the render test's PNGs of the new surfaces handed to Sam, `dart format` on the edited files only, `git status` checked for stray paths. Then Sam's device pass.
- **Commits only on Sam's word**, one per phase, with one short message naming the traveller-visible change. Phases are independent commits, so any one can be reverted on its own. Nothing is pushed or tagged without an explicit go.
- **No DB changes anywhere in this plan**, so no "run this SQL" step; if one ever becomes necessary it goes first and is verified via SQL before any build.
- **Decisions reserved for Sam during execution:** whether Phase 1's lazy map-trip switching should become eager after the first device run; whether Phase 7's compact-strip ✕ survives the height check; whether Phase 9's location-prompt suppression should be per-session or a 10-second cool-down; the version number and release note at the end.

---

## Verification (every phase)

1. `flutter analyze --no-pub` → "N issues found", N ≤ 85, zero `warning`/`error` lines (unused imports after deletions are warnings — fix them).
2. `flutter test` → "All tests passed!"; count = previous + the tests added in that phase (baseline 638 call sites, 70 files).
3. `VOYZA_UX_SHOTS_OUT=build/qa_shots/ux flutter test test/widgets/ux_surfaces_render_test.dart` → PNGs of the phase's surfaces (light + dark) handed to Sam.
4. `dart format <edited files only>` → `git status --porcelain` shows only intended paths (leave `supabase/.temp/cli-latest` and the untracked `docs/ux-flow-audit-2026-11-08.html` alone; `git checkout -- android/local.properties` if a build touched it).
5. Sam's device pass per phase (he tests on device; I say what was not eye-checked). Phase 2's first device build also checks the map keyboard shift; Phase 7's checks the compact-summary height; Phase 9's runs the checklist above.
6. Release: after the last phase, Sam decides the version (pubspec is 1.11.1+1, last tag v1.10.0; this is a 1.12.0 or 2.0.0 call) and the release note (short: one lead line + 5–8 bullets).

## Open items that stay out of this plan
- Accommodation prompt reads the map trip's accommodations (`accommodation_prompts.dart:37-38`); making it per-trip is a follow-up.
- The three `setMapStyle` deprecation infos in `map_screen.dart` (GoogleMap.style) and the `curly_braces` infos in Settings' tiles are untouched.
- Onboarding prefilling the create form for guests (Phase 6 note).
