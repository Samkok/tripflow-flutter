import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/transit_fare.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_day_labeler_provider.dart';
import 'package:voyza/widgets/trip_day_picker.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../utils/date_picker_utils.dart';
import '../screens/trip_details_screen.dart';
import 'plan_sheet.dart';
import '../providers/day_distribution_provider.dart';
import 'timing_warnings_sheet.dart';
import '../core/theme.dart';
import 'leg_rail.dart';
import 'unvisited_places_sheet.dart';
import 'optimized_location_card.dart';
import 'static_glow.dart';
import '../utils/search_text.dart';

class TripBottomSheet extends ConsumerStatefulWidget {
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;
  final VoidCallback? onShowMapSettings;
  final int? highlightedLocationIndex;

  /// Anchor for the map spotlight tour's "Optimize" step. Attached to the
  /// header optimize BUTTON only (never the 1–2-place nudge pill).
  final GlobalKey? optimizeKey;

  const TripBottomSheet({
    super.key,
    this.sheetController,
    this.onLocationTap,
    this.onShowMapSettings,
    this.highlightedLocationIndex,
    this.optimizeKey,
  });

  /// Places needed before route optimization is worth offering (the "aha").
  /// Single source of truth for the goal-gradient nudges below — the
  /// onboarding checklist's "add places" step mirrors this number by hand
  /// (onboarding_checklist_provider / onboarding_checklist), keep them in
  /// step. Distinct from [SubscriptionLimitService.freePlaceAllowance] (the
  /// paywall cap of 10) — 2 unlocks Optimize, 10 hits the wall.
  /// Lowered from 3 → 2 (owner call, 2026-08-15): even a two-stop day has a
  /// real best order + travel times worth showing.
  static const int ahaThreshold = 2;

  /// Collapsed-state height as a fraction of the screen. PUBLIC because the
  /// map's zoom-to-fit window must know exactly where the sheet's top edge
  /// sits — hardcoding a stale copy there put fitted stops behind the sheet.
  static const double collapsedSize = 0.25;

  // A simple provider to signal when the "View Route" button is tapped for a historical trip.
  static final viewHistoricalRouteProvider =
      StateProvider<bool>((ref) => false);

  @override
  ConsumerState<TripBottomSheet> createState() => _TripBottomSheetState();
}

class _TripBottomSheetState extends ConsumerState<TripBottomSheet> {
  /// The map trip's id, one narrow select for every card on the sheet.
  String? get _mapTripId =>
      ref.watch(realtimeActiveTripProvider.select((a) => a.valueOrNull?.id));

  /// Flips to true when the inner list is scrolled past the top, and back
  /// to false when it's at the top again. Used to swap the Route Summary
  /// between its full and compact layouts via [AnimatedCrossFade]. A
  /// notifier (rather than setState) keeps the rebuild scope tight — only
  /// the summary block rebuilds on each scroll-state flip, not the whole
  /// sheet.
  final ValueNotifier<bool> _summaryCompact = ValueNotifier<bool>(false);

  /// Private scroll controller for the inner ListView. NOT the one that
  /// [DraggableScrollableSheet.builder] hands us — that one couples list
  /// scroll to sheet drag, which means scrolling the list down to its
  /// top would continue into collapsing the sheet. With this private
  /// controller, the list is fully independent: scrolling stops at the
  /// boundaries and the sheet is only moved by gestures on the drag
  /// handle or the sticky region (header + route summary).
  final ScrollController _listScrollController = ScrollController();

  /// Plan search: filters the location cards by name/address.
  ///
  /// Two notifiers on purpose. [_searchQuery] follows every keystroke and
  /// drives only the field itself (its clear button). [_listQuery] is what
  /// the list bodies listen to: it changes after a short typing pause, and
  /// only when the set of matching stops actually changed. Every card in
  /// the trip is built under that listener, so with a few dozen stops a
  /// rebuild per keystroke is what made typing lag.
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  final ValueNotifier<String> _listQuery = ValueNotifier<String>('');
  Timer? _searchSettleTimer;
  Set<String>? _lastListMatchIds;
  static const _searchSettle = Duration(milliseconds: 150);

  /// Keeps the field's element (focus, IME session) when the body switches
  /// between its list and its centred empty/no-match layout mid-typing —
  /// without it the keyboard closed the moment a query matched nothing.
  final GlobalKey _searchFieldKey = GlobalKey();

  // normalizeSearchText once per query and once per stop, not once per
  // (stop × keystroke).
  String? _memoQuery;
  String _memoNormalizedQuery = '';
  final Map<String, ({String name, String address, String folded})>
      _foldedHaystacks = {};

  // Provider to clear the optimized route when the date changes.
  // This prevents showing an old route on a new day's location list.
  final routeClearerProvider = Provider<void>((ref) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      // When the date changes, clear the old route from the state.
      ref.read(tripProvider.notifier).clearOptimizedRoute();
    });
  });

  DraggableScrollableController? get sheetController => widget.sheetController;

  Function(LatLng)? get onLocationTap => widget.onLocationTap;
  VoidCallback? get onShowMapSettings => widget.onShowMapSettings;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _summaryCompact.dispose();
    _listScrollController.dispose();
    _searchSettleTimer?.cancel();
    _searchController.dispose();
    _searchQuery.dispose();
    _listQuery.dispose();
    super.dispose();
  }

  /// Forgiving match over the fields a traveller would search by: case-
  /// and diacritic-insensitive, any word order (see [matchesSearchQuery]),
  /// so "ben thanh" finds "Chợ Bến Thành".
  bool _matchesQuery(LocationModel loc, String query) {
    final q = _normalizedQuery(query);
    if (q.isEmpty) return true;
    return matchesNormalizedQuery(_foldedHaystack(loc), q);
  }

  String _normalizedQuery(String query) {
    if (query != _memoQuery) {
      _memoQuery = query;
      _memoNormalizedQuery = normalizeSearchText(query);
    }
    return _memoNormalizedQuery;
  }

  String _foldedHaystack(LocationModel loc) {
    final hit = _foldedHaystacks[loc.id];
    if (hit != null && hit.name == loc.name && hit.address == loc.address) {
      return hit.folded;
    }
    final folded = normalizeSearchText('${loc.name} ${loc.address}');
    _foldedHaystacks[loc.id] =
        (name: loc.name, address: loc.address, folded: folded);
    return folded;
  }

  /// Field input: the field updates at once; the list bodies after a pause
  /// (clearing is immediate).
  void _onSearchChanged(String value) {
    _searchQuery.value = value;
    _searchSettleTimer?.cancel();
    if (value.trim().isEmpty) {
      _pushListQuery(value);
      return;
    }
    _searchSettleTimer = Timer(_searchSettle, () => _pushListQuery(value));
  }

  /// Hands [value] to the list bodies unless they would rebuild into the
  /// very same cards: same matching stops, still searching. An empty match
  /// set always goes through — the no-match body prints the query.
  void _pushListQuery(String value) {
    if (!mounted) return;
    final ids = <String>{
      for (final l in ref.read(tripProvider).pinnedLocations)
        if (_matchesQuery(l, value)) l.id,
    };
    final wasSearching = _listQuery.value.trim().isNotEmpty;
    final searching = value.trim().isNotEmpty;
    if (ids.isNotEmpty &&
        searching == wasSearching &&
        setEquals(ids, _lastListMatchIds)) {
      return;
    }
    _lastListMatchIds = ids;
    _listQuery.value = value;
  }

  /// Snap targets shared between the drag-handle tap and the sticky-region
  /// drag forwarder below. Mirrors the [DraggableScrollableSheet.snapSizes]
  /// passed to the sheet's builder.
  // 0.25 (not 0.23): once a route exists the pinned header carries the
  // compact summary strip too, and 0.23 left the fixed content ~7px taller
  // than the collapsed sheet on some screens (bottom overflow). The extra
  // ~2% gives the summary room without a perceptible change to the resting
  // collapsed height.
  static const double _snapCollapsed = TripBottomSheet.collapsedSize;
  static const double _snapExpanded = 0.85;

  /// Below this many logical pixels of sheet height, the fixed sticky header
  /// (drag handle + title + full Route Summary card) no longer fits above the
  /// scroll region, squeezing the Expanded list to a negative height and
  /// throwing a transient layout/constraint error during a collapse (most
  /// visible at tablet proportions). At/under this height we fold the summary
  /// into its single-row compact form, which always fits the collapsed sheet.
  /// Chosen with headroom for the full card (~260px) plus a sliver of list.
  static const double _fullSummaryMinHeight = 360.0;

  /// Forwards a vertical drag delta from the sticky region / drag handle
  /// / drag overlay into the sheet controller. Without this, dragging on
  /// those areas wouldn't expand or collapse the sheet — they bypass the
  /// inner ListView that DraggableScrollableSheet otherwise listens to.
  ///
  /// Guards against the controller being unattached: `ctrl.size` asserts
  /// `isAttached`, and accessing it before the sheet has fully mounted
  /// would silently throw (caught by the framework) — making the whole
  /// drag chain appear unresponsive. The isAttached check makes that
  /// failure mode safe.
  void _dragSheetBy(double dy) {
    final ctrl = sheetController;
    if (ctrl == null || !ctrl.isAttached) return;
    final screenH = MediaQuery.of(context).size.height;
    if (screenH <= 0) return;
    // Drag up (negative dy) → sheet grows; drag down → sheet shrinks.
    final newSize =
        (ctrl.size - dy / screenH).clamp(_snapCollapsed, _snapExpanded);
    ctrl.jumpTo(newSize);
  }

  /// Snaps the sheet to the nearest snap point on drag end. Uses fling
  /// velocity to bias toward the direction the user was moving, so a
  /// quick upward flick from near-collapsed still snaps open.
  void _snapSheet(double velocityPxPerSec) {
    final ctrl = sheetController;
    if (ctrl == null || !ctrl.isAttached) return;
    final cur = ctrl.size;
    double target;
    if (velocityPxPerSec.abs() > 300) {
      target = velocityPxPerSec < 0 ? _snapExpanded : _snapCollapsed;
    } else {
      target = (cur - _snapCollapsed).abs() < (cur - _snapExpanded).abs()
          ? _snapCollapsed
          : _snapExpanded;
    }
    ctrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Activates the date-change → clear-stale-route listener. It rode the
    // (now removed) day-chip strip; the sheet's root build is the one spot
    // guaranteed alive for every day-switch source (map day picker, Whole
    // trip date headers, external focus requests).
    ref.watch(routeClearerProvider);
    // Narrow: only flips when the board goes from empty to not (and back).
    final hasPinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.isNotEmpty));
    // NOTE (owner request 2026-08-11): the warnings sheet no longer
    // auto-pops after optimize — the route was already committed, so the
    // modal was a verdict without a verb (dismissing changed nothing).
    // Timing issues now surface as the amber chip in the Route Summary
    // ("N timing issues — tap to review"), which opens the same sheet ON
    // DEMAND — now with per-kind practical fixes inside.

    return DraggableScrollableSheet(
      controller: sheetController,
      // Define snap points for a magnetic feel
      snap: true,
      // Must match _snapCollapsed/_snapExpanded and stay within
      // [minChildSize, maxChildSize] or DraggableScrollableSheet asserts.
      snapSizes: const [_snapCollapsed, _snapExpanded],
      initialChildSize:
          0.25, // Start in the collapsed state (see _snapCollapsed)
      minChildSize: 0.25, // Collapsed state shows the header + route summary
      maxChildSize: 0.85, // Expanded state leaves search bar visible
      builder: (context, frameworkScrollController) {
        // Use a private controller for the visible ListView so list
        // scroll is fully independent from sheet drag (scrolling to
        // the top of the list no longer collapses the sheet).
        //
        // BUT we still have to "consume" the framework's scrollController
        // somewhere: DraggableScrollableController.jumpTo/animateTo —
        // which our drag handle and sticky-region forwarders call —
        // internally do `_attachedController.position.context...`,
        // and `position` ASSERTS the controller has a scroll position.
        // If no scrollable uses the controller, every drag silently
        // throws "No element" (caught by the gesture binding) and the
        // sheet appears frozen. The hidden 0×0 SingleChildScrollView
        // below gives the framework's controller a position to point
        // at without participating in layout or gestures.
        final scrollController = _listScrollController;
        // Glass sheet — same blur/fill as the Search for Location and
        // Collaborators sheets (AppTheme.sheet* is the one source of truth).
        // The old "buttons ghosting through the glass" confusion is solved
        // at the SOURCE: map_screen fades its FAB column out as this sheet
        // expands over it, so nothing interactive-looking sits behind the
        // blur (the globe experiment is reverted — it was composed for full
        // screens and cropped badly in a sheet).
        // NOTE (thermal, 2026-08-10): an extent-based glass→solid swap was
        // tried here and REVERTED — changing the wrapper's widget type at
        // the 55–60% mark re-inflated the whole sheet subtree mid-drag, a
        // visible hitch in both directions. If the blur's map-redraw cost
        // needs killing again, the structure-stable variant (GlobalKey'd
        // content reparented across a persistent wrapper) is the way.
        // SOLID since 2026-10-12 (owner call: "no transparency"). The glass
        // version blurred the map behind the sheet on every frame, which
        // was also the thermal hot path; the other sheets keep their glass
        // (AppTheme.sheet*). The ClipRRect/BackdropFilter pair is replaced
        // by a plain clipped container — same shape, same border, same
        // shadow — so nothing else in the sheet changes.
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border.all(
                color: AppTheme.sheetBorderColor(context),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Column(
              children: [
                // Hidden, 0-sized scrollable that consumes the framework's
                // scrollController so DraggableScrollableController's
                // jumpTo/animateTo (called by _dragSheetBy / _snapSheet)
                // can resolve `controller.position` without throwing.
                // NeverScrollableScrollPhysics keeps it from intercepting
                // any gestures; SizedBox.shrink keeps it from taking
                // layout space.
                SizedBox(
                  height: 0,
                  width: 0,
                  child: SingleChildScrollView(
                    controller: frameworkScrollController,
                    physics: const NeverScrollableScrollPhysics(),
                    child: const SizedBox.shrink(),
                  ),
                ),
                // Drag handle — taps toggle between snap points; vertical
                // drags forward to the sheet controller (via the same
                // helpers the sticky region uses) so users can drag the
                // handle itself, not just tap it. Wrapped in a wider
                // transparent hit area because the visible pill is only
                // 4 × 50 px — too small to catch a drag reliably.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (sheetController != null) {
                      final currentSize = sheetController!.size;
                      final targetSize =
                          currentSize < 0.5 ? _snapExpanded : _snapCollapsed;
                      sheetController!.animateTo(
                        targetSize,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                      // When expanding, scroll to the top.
                      scrollController.animateTo(
                        0,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                  onVerticalDragUpdate: (details) =>
                      _dragSheetBy(details.primaryDelta ?? 0),
                  onVerticalDragEnd: (details) =>
                      _snapSheet(details.velocity.pixelsPerSecond.dy),
                  child: SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 4),
                        height: 4,
                        width: 50,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),

                // Fixed sticky region — header, history banner (when on a
                // past date) and route/trip summary stay pinned at the top
                // of the sheet while everything below scrolls. Outside the
                // Expanded(ListView) below, so the scrollController only
                // governs the rest of the content (date picker, day chips,
                // tabs, list, optimize buttons).
                //
                // The wrapping GestureDetector forwards vertical drag deltas
                // to the sheet controller — without it, dragging on the
                // sticky region wouldn't expand/collapse the sheet (since
                // those gestures bypass the inner ListView that
                // DraggableScrollableSheet normally coordinates with). Tap
                // gestures on buttons inside the sticky region still win
                // the arena (taps don't accumulate the movement needed for
                // a drag recognizer to claim).
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragUpdate: (details) =>
                      _dragSheetBy(details.primaryDelta ?? 0),
                  onVerticalDragEnd: (details) =>
                      _snapSheet(details.velocity.pixelsPerSecond.dy),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildDefaultHeader(context, ref),
                        Consumer(builder: (context, ref, _) {
                          final selectedDate = ref.watch(selectedDateProvider);
                          final now = DateTime.now();
                          final today = DateTime(now.year, now.month, now.day);
                          final isPastDate = selectedDate.isBefore(today);
                          if (!isPastDate) return const SizedBox.shrink();
                          // The banner lives in the FIXED sticky region. At
                          // collapsed sheet heights it pushes the column past
                          // the sheet's height (RenderFlex overflow on small
                          // screens) — same guard as the route summary below:
                          // hide it until the sheet is tall enough.
                          return ListenableBuilder(
                            listenable: Listenable.merge([sheetController]),
                            builder: (context, _) {
                              final ctrl = sheetController;
                              final sheetTooShort = ctrl == null
                                  ? true
                                  : (!ctrl.isAttached ||
                                      ctrl.pixels < _fullSummaryMinHeight);
                              if (sheetTooShort) return const SizedBox.shrink();
                              return _buildHistoryBanner(context);
                            },
                          );
                        }),
                        if (hasPinnedLocations)
                          Consumer(builder: (context, ref, _) {
                            final locationsForDate =
                                ref.watch(locationsForSelectedDateProvider);
                            final totalTravelTime = ref.watch(
                                tripProvider.select((s) => s.totalTravelTime));
                            final totalDistance = ref.watch(
                                tripProvider.select((s) => s.totalDistance));
                            // Data integrity: with no optimized route the
                            // distance/time are zeros and an ETA is just the
                            // wall clock — show stops only. On past days an
                            // ETA computed from "now" is meaningless — hide it
                            // (real route facts stay).
                            final hasRoute = ref.watch(tripProvider
                                .select((s) => s.optimizedRoute.isNotEmpty));
                            final summarySelectedDate =
                                ref.watch(selectedDateProvider);
                            final summaryNow = DateTime.now();
                            final summaryToday = DateTime(summaryNow.year,
                                summaryNow.month, summaryNow.day);
                            final hideEta =
                                summarySelectedDate.isBefore(summaryToday);
                            // Cross-fade between the full and compact route
                            // summary. Goes compact when EITHER the list is
                            // scrolled past the top (_summaryCompact, flipped by
                            // the scroll notification listener below) OR the
                            // sheet is too short to fit the full card — the
                            // latter prevents the fixed sticky header from
                            // overflowing the collapsed sheet. We listen to the
                            // sheet controller so the fold tracks the collapse
                            // animation, not just scrolls.
                            return ListenableBuilder(
                              listenable: Listenable.merge(
                                  [_summaryCompact, sheetController]),
                              builder: (context, _) {
                                final ctrl = sheetController;
                                // Until the controller attaches (first frame) the
                                // sheet sits at its collapsed initialChildSize,
                                // so assume short until it reports real pixels.
                                final sheetTooShort = ctrl == null
                                    ? false
                                    : (!ctrl.isAttached ||
                                        ctrl.pixels < _fullSummaryMinHeight);
                                final compact =
                                    _summaryCompact.value || sheetTooShort;
                                return AnimatedCrossFade(
                                  duration: const Duration(milliseconds: 200),
                                  sizeCurve: Curves.easeOut,
                                  firstCurve: Curves.easeOut,
                                  secondCurve: Curves.easeOut,
                                  crossFadeState: compact
                                      ? CrossFadeState.showSecond
                                      : CrossFadeState.showFirst,
                                  firstChild: _buildTripSummary(
                                      context,
                                      totalTravelTime,
                                      totalDistance,
                                      locationsForDate.length,
                                      hasRoute: hasRoute,
                                      hideEta: hideEta),
                                  secondChild: _buildCompactTripSummary(
                                      context,
                                      totalTravelTime,
                                      totalDistance,
                                      locationsForDate.length,
                                      hasRoute: hasRoute,
                                      hideEta: hideEta),
                                );
                              },
                            );
                          }),
                        // "Search places in this trip" stays put above the
                        // list (owner call 2026-10-12: easier to find than
                        // scrolling back up for it). Hidden while the sheet
                        // is too short to hold it, like the banner above;
                        // tapping it expands the sheet anyway.
                        if (hasPinnedLocations)
                          ListenableBuilder(
                            listenable: Listenable.merge([sheetController]),
                            builder: (context, _) {
                              final ctrl = sheetController;
                              final sheetTooShort = ctrl == null
                                  ? true
                                  : (!ctrl.isAttached ||
                                      ctrl.pixels < _fullSummaryMinHeight);
                              if (sheetTooShort) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: _buildPlanSearchField(context),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),

                // Scrollable region below the fixed sticky header.
                //
                // NotificationListener watches the inner list's scroll
                // position to flip the route summary between its full and
                // compact layouts. A small threshold (8px) keeps a tiny
                // over-scroll bounce from toggling the state mid-flick.
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      // ONLY this list's own VERTICAL scrolling may compact the
                      // summary. Notifications bubble up from nested
                      // scrollables too — rolling the horizontal day-chip strip
                      // was reporting its horizontal offset here and collapsing
                      // the Route Summary card mid-swipe.
                      if (notification.metrics.axis != Axis.vertical) {
                        return false;
                      }
                      if (notification.depth != 0) return false;
                      final pixels = notification.metrics.pixels;
                      final compact = pixels > 8;
                      if (_summaryCompact.value != compact) {
                        _summaryCompact.value = compact;
                      }
                      return false;
                    },
                    // Framework's scrollController is attached to the
                    // ListView — drags on the list area expand/collapse
                    // the sheet via the built-in DraggableScrollableSheet
                    // coordination.
                    child: ValueListenableBuilder<String>(
                      valueListenable: _listQuery,
                      builder: (context, query, _) {
                        // Query is resolved OUTSIDE the Consumer so every
                        // ref.watch below runs in the Consumer's own build.
                        return Consumer(builder: (context, ref, _) {
                          final searching = query.trim().isNotEmpty;
                          // .select keeps the common path rebuilding only
                          // when emptiness actually flips. An ended trip's
                          // leftovers row still renders on an emptied day.
                          final selectedDateEmpty = ref.watch(
                                  locationsForSelectedDateProvider
                                      .select((l) => l.isEmpty)) &&
                              ref.watch(endedTripUnvisitedProvider
                                  .select((l) => l.isEmpty));
                          var noMatches = false;
                          if (searching && !selectedDateEmpty) {
                            final scope =
                                ref.watch(locationsForSelectedDateProvider);
                            noMatches = scope.isNotEmpty &&
                                !scope.any((l) => _matchesQuery(l, query));
                          }

                          if (selectedDateEmpty || noMatches) {
                            return CustomScrollView(
                              controller: scrollController,
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                SliverPadding(
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 8, 20, 0),
                                  sliver: SliverList(
                                    delegate: SliverChildListDelegate([
                                      _buildDatePicker(context, ref),
                                    ]),
                                  ),
                                ),
                                // Fills the space under the day row so the
                                // message lands in the middle of it.
                                SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        32, 8, 32, 32),
                                    child: Center(
                                      child: searching
                                          ? _buildNoSearchMatches(
                                              context, ref, query)
                                          : _buildEmptyDateState(context),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }
                          return ListView(
                            controller: scrollController,
                            shrinkWrap: false,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                            children: [
                              _buildDatePicker(context, ref),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: _buildLocationsListWidgets(
                                    context,
                                    ref,
                                    ref.watch(locationsForSelectedDateProvider),
                                    scrollController,
                                    query: query),
                              ),
                              const SizedBox(height: 130),
                            ],
                          );
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDefaultHeader(BuildContext context, WidgetRef ref) {
    // OPTIMIZATION: Read values only when needed, not watched in parent
    final hasOptimizedRoute =
        ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));

    // Inline stat line under the title — the route's vitals at a glance
    // (replaces scanning down to the summary card for the basics).
    final allDaysStats = ref.watch(allDaysModeProvider);
    final axisDays = ref.watch(activeTripDayAxisProvider).length;
    final placesAll =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.length));
    final dayStops = ref.watch(locationsForSelectedDateProvider).length;
    final distanceKm =
        ref.watch(tripProvider.select((s) => s.totalDistance)) / 1000.0;
    final travelTime = ref.watch(tripProvider.select((s) => s.totalTravelTime));
    final String statLine;
    if (allDaysStats) {
      statLine = '$axisDays ${axisDays == 1 ? 'day' : 'days'} · '
          '$placesAll ${placesAll == 1 ? 'place' : 'places'}';
    } else if (hasOptimizedRoute) {
      statLine = '$dayStops ${dayStops == 1 ? 'stop' : 'stops'}'
          ' · ${distanceKm.toStringAsFixed(1)} km'
          '${travelTime > Duration.zero ? ' · ${_formatDuration(travelTime)}' : ''}';
    } else if (dayStops > 0) {
      statLine = '$dayStops ${dayStops == 1 ? 'stop' : 'stops'} · not '
          'optimized yet';
    } else {
      statLine = 'Add places to plan this day';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Flexible: with Clear + Re-optimize both visible the action cluster
        // can outgrow narrow screens — the title yields (ellipsis) instead of
        // overflowing the row.
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Trip plan',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                statLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              // Bucket pill: places in the trip but on NO day. The map is
              // day-scoped so they can't appear on it — this is their one
              // map-surface trace, leading to trip details to schedule.
              Consumer(builder: (context, ref, _) {
                final n = ref.watch(unscheduledCountProvider);
                if (n == 0) return const SizedBox.shrink();
                const amber = Color(0xFFFFB300);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      final trip =
                          ref.read(realtimeActiveTripProvider).valueOrNull;
                      if (trip == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => TripDetailsScreen(trip: trip)));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inventory_2_outlined,
                              size: 13, color: amber),
                          const SizedBox(width: 5),
                          Text(
                            'Unscheduled ($n)',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color: amber, fontWeight: FontWeight.w700),
                          ),
                          const Icon(Icons.chevron_right_rounded,
                              size: 14, color: amber),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        Row(
          children: [
            // Consumer(
            //   builder: (context, ref, child) {
            //     final showNames = ref.watch(showMarkerNamesProvider);
            //     return IconButton(
            //       icon: Icon(showNames ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            //       onPressed: () => ref.read(showMarkerNamesProvider.notifier).state = !showNames,
            //       color: Theme.of(context).textTheme.bodyMedium?.color,
            //       tooltip: showNames ? 'Hide place names' : 'Show place names',
            //     );
            //   },
            // ),
            // Clear route lives in the route summary, beside Share.
            // The one planning verb — ALWAYS rendered (disabled at 0 places)
            // so brand-new users see the goal from the start and the
            // first-run spotlight tour has an anchor. Opens the Plan sheet
            // on this day (or the whole trip while All days is on).
            Consumer(builder: (context, ref, _) {
              final isGenerating = ref.watch(isGeneratingRouteProvider);
              final count = ref.watch(
                  locationsForSelectedDateProvider.select((l) => l.length));
              final hasLocations = count > 0;
              final allDaysMode = ref.watch(allDaysModeProvider);
              final needsAttention = ref.watch(tripNeedsPlanAttentionProvider);
              final primaryColor = Theme.of(context).colorScheme.primary;
              final nudgeDate = ref.watch(selectedDateProvider);
              final nudgeNow = DateTime.now();
              final isPastDate = nudgeDate.isBefore(
                  DateTime(nudgeNow.year, nudgeNow.month, nudgeNow.day));

              // A past day with a route: seeing it again is the only verb.
              if (isPastDate && hasOptimizedRoute && !allDaysMode) {
                return _viewRouteButton(context, ref, primaryColor);
              }

              // Goal-gradient nudge: below [ahaThreshold] stops we coach
              // toward the "aha" instead of offering a trivial optimize.
              const ahaThreshold = TripBottomSheet.ahaThreshold;
              if (!isPastDate &&
                  !allDaysMode &&
                  count > 0 &&
                  count < ahaThreshold &&
                  !hasOptimizedRoute &&
                  !isGenerating) {
                final remaining = ahaThreshold - count;
                return Container(
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: primaryColor.withValues(alpha: 0.30)),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_location_alt_rounded,
                          color: primaryColor, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Add $remaining more to optimize',
                        style: TextStyle(
                          color: primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                );
              }

              final canTap =
                  (hasLocations || allDaysMode) && !isGenerating && !isPastDate;
              final button = Container(
                key: widget.optimizeKey,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: canTap
                        ? [
                            primaryColor,
                            primaryColor.withValues(alpha: 0.8),
                          ]
                        : [
                            primaryColor.withValues(alpha: 0.35),
                            primaryColor.withValues(alpha: 0.25),
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: canTap
                        ? () => showPlanSheet(context,
                            initial:
                                allDaysMode ? PlanScope.trip : PlanScope.day)
                        : null,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 11),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // In flight: an actual spinner + "Optimizing…" —
                          // a swapped icon with the same label read as
                          // "nothing is happening".
                          if (isGenerating)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          else
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.route_rounded,
                                    color: Colors.white, size: 20),
                                // The trip plainly needs planning (bucket
                                // rows, an overloaded day).
                                if (needsAttention)
                                  Positioned(
                                    right: -3,
                                    top: -3,
                                    child: Container(
                                      width: 9,
                                      height: 9,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFFFB300),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          const SizedBox(width: 8),
                          Text(
                            isGenerating ? 'Optimizing…' : 'Plan',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );

              if (!canTap) return button;
              return _sheetStaticGlow(glowColor: primaryColor, child: button);
            }),
            const SizedBox(width: 8),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.6)),
              ),
              child: IconButton(
                icon: const Icon(Icons.tune, size: 20),
                padding: EdgeInsets.zero,
                onPressed: onShowMapSettings,
                color: Theme.of(context).textTheme.bodyMedium?.color,
                tooltip: 'Map settings',
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The ◀ Today ▶ calendar row — the sheet's day control now that the
  /// day-chip strip is gone. Restored verbatim (owner request 2026-08-10)
  /// after being removed in the same cleanup; the only difference is that
  /// routeClearerProvider is activated in the root build, not here.
  Widget _buildDatePicker(BuildContext context, WidgetRef ref) {
    return Consumer(builder: (context, ref, _) {
      final selectedDate = ref.watch(selectedDateProvider);
      final isToday = selectedDate.isAtSameMomentAs(DateTime(
          DateTime.now().year, DateTime.now().month, DateTime.now().day));

      final highlightedDates = ref.read(datesWithLocationsProvider);
      final earliestDate = highlightedDates.isNotEmpty
          ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
          : DateTime.now();

      // The first selectable date is the earliest date with a location.
      final firstDate = earliestDate;
      final isAtFirstDate = selectedDate.isAtSameMomentAs(firstDate);

      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Previous Day Button
          IconButton(
            icon: const Icon(Icons.arrow_left),
            onPressed: isAtFirstDate
                ? null
                : () {
                    ref.read(selectedDateProvider.notifier).state =
                        selectedDate.subtract(const Duration(days: 1));
                  },
            tooltip: 'Previous Day',
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: () async {
                // BUGFIX: Ensure initialDate is never before firstDate
                final initialDateForPicker =
                    selectedDate.isBefore(firstDate) ? firstDate : selectedDate;

                final labeler = ref.read(activeTripDayLabelerProvider);
                final DateTime? newDate;
                if (labeler.tbd) {
                  newDate = await showTripDayPicker(
                    context,
                    days: ref.read(activeTripDayAxisProvider),
                    labeler: labeler,
                    selected: selectedDate,
                    marked: highlightedDates,
                  );
                } else {
                  newDate = await DatePickerUtils.showCustomDatePicker(
                    context: context,
                    initialDate: initialDateForPicker,
                    firstDate: firstDate,
                    lastDate: DateTime.now()
                        .add(const Duration(days: 365 * 5)), // 5 years ahead
                    highlightedDates: highlightedDates,
                    highlightRange: activeTripDateRange(ref),
                  );
                }

                if (newDate != null) {
                  ref.read(selectedDateProvider.notifier).state = newDate;
                }
              },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(
                ref.watch(activeTripDayLabelerProvider).tbd
                    ? ref.watch(activeTripDayLabelerProvider)(selectedDate)
                    : isToday
                        ? 'Today'
                        : DateFormat.yMMMd().format(selectedDate),
                textAlign: TextAlign.center,
              ),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ),
          // Next Day Button
          IconButton(
            icon: const Icon(Icons.arrow_right),
            onPressed: () {
              ref.read(selectedDateProvider.notifier).state =
                  selectedDate.add(const Duration(days: 1));
            },
            tooltip: 'Next Day',
          ),
        ],
      );
    });
  }

  Widget _buildHistoryBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history_toggle_off,
            color: Theme.of(context).colorScheme.secondary,
            size: 20,
          ),
          const SizedBox(width: 10),
          Text(
            'Viewing Past Trip (Read-Only)',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
                fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// Slimmed-down route summary shown when the list is scrolled. Keeps
  /// the same brand chrome (border, primary tint, route icon) so it reads
  /// as the same component, but folds Stops / Distance / Travel time /
  /// ETA into a single inline strip. Falls back to a clipped ellipsis on
  /// very narrow screens — the full summary is one tap (scroll-to-top)
  /// away.
  Widget _buildCompactTripSummary(
    BuildContext context,
    Duration totalTravelTime,
    double totalDistance,
    int totalStopsForDate, {
    required bool hasRoute,
    required bool hideEta,
  }) {
    final theme = Theme.of(context);
    final estimatedArrival = DateTime.now().add(totalTravelTime);
    final etaLabel = DateFormat('h:mm a').format(estimatedArrival);
    // What the day's rides cost, when Google prices them ("HK$24"; a
    // trailing "+" when some ride is unpriced).
    final fareLabel = ref.watch(
        tripProvider.select((s) => TransitFare.totalLabel(s.legDetails)));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        // Translucent to match the glass sheet it sits in.
        color: AppTheme.planSheetCardColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.route, color: theme.colorScheme.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodyMedium?.color,
                  fontWeight: FontWeight.w600,
                ),
                children: [
                  TextSpan(
                    text:
                        '$totalStopsForDate stop${totalStopsForDate == 1 ? '' : 's'}',
                  ),
                  if (hasRoute) ...[
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: theme.dividerColor),
                    ),
                    TextSpan(text: _formatDistance(totalDistance)),
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: theme.dividerColor),
                    ),
                    TextSpan(text: _formatDuration(totalTravelTime)),
                    if (fareLabel != null) ...[
                      TextSpan(
                        text: '  ·  ',
                        style: TextStyle(color: theme.dividerColor),
                      ),
                      TextSpan(text: fareLabel),
                    ],
                    if (!hideEta) ...[
                      TextSpan(
                        text: '  ·  ',
                        style: TextStyle(color: theme.dividerColor),
                      ),
                      TextSpan(
                        text: 'ETA $etaLabel',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // The same Clear as the full card, small enough not to grow the
          // strip. Whenever a route exists (as the old map button did).
          if (hasRoute)
            Consumer(builder: (context, ref, _) {
              final generating = ref.watch(isGeneratingRouteProvider);
              return Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer
                        .withValues(alpha: generating ? 0.3 : 0.7),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    key: const Key('compact-clear-route'),
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Clear route',
                    onPressed: generating
                        ? null
                        : () => ref
                            .read(tripProvider.notifier)
                            .clearOptimizedRoute(),
                    icon: Icon(Icons.close_rounded,
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildTripSummary(BuildContext context, Duration totalTravelTime,
      double totalDistance, int totalStopsForDate,
      {required bool hasRoute, required bool hideEta}) {
    final estimatedArrival = DateTime.now().add(totalTravelTime);
    // What the day's rides cost, when Google prices them ("HK$24"; a
    // trailing "+" when some ride is unpriced).
    final fareLabel = ref.watch(
        tripProvider.select((s) => TransitFare.totalLabel(s.legDetails)));

    // Pre-optimize there is exactly ONE fact (stops planned), so the card
    // is a single quiet row — the old layout kept the full box's height
    // with empty stat slots. The optimize spinner takes the fact's place
    // while the first route is being generated.
    if (!hasRoute) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        margin: const EdgeInsets.only(top: 16),
        decoration: BoxDecoration(
          color: AppTheme.planSheetCardColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.route,
              color: Theme.of(context).colorScheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Route Summary',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: AppTheme.primaryColor),
            ),
            const Spacer(),
            Consumer(builder: (context, ref, _) {
              final isGenerating = ref.watch(isGeneratingRouteProvider);
              if (isGenerating) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('Optimizing…',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                );
              }
              return Text(
                '$totalStopsForDate ${totalStopsForDate == 1 ? 'stop' : 'stops'}',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              );
            }),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        // Translucent to match the glass sheet it sits in.
        color: AppTheme.planSheetCardColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.route, // Uses theme colors
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Route Summary', // Uses theme colors
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.primaryColor,
                        ),
                  ),
                ],
              ),
              // Google Maps navigation button with distance - only show if there are 2+ locations
              if (totalStopsForDate >= 2)
                Consumer(
                  builder: (context, ref, _) {
                    // Horizontal action pair — a vertical stack here made the
                    // header row tall, floating the title in dead space. The
                    // old distance chip is gone: it duplicated the "Distance"
                    // stat two rows below.
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Share the before/after route card — every
                        // optimized route is a shareable artifact, not just
                        // the first one. (Only once a route exists — the
                        // card is the before/after reveal.)
                        if (hasRoute)
                          IconButton.filledTonal(
                            // Route the share through map_screen so it captures
                            // the live map (realistic route image), not the
                            // silhouette. map_screen falls back to the silhouette
                            // card if the snapshot is unavailable.
                            onPressed: () => ref
                                .read(shareRouteMapTrigger.notifier)
                                .update((v) => v + 1),
                            icon: const Icon(Icons.ios_share_rounded, size: 20),
                            tooltip: 'Share route',
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.15),
                              foregroundColor:
                                  Theme.of(context).colorScheme.primary,
                              padding: const EdgeInsets.all(8),
                            ),
                          ),
                        // Clear the day's route, whenever one exists (as
                        // the old map button did). Disabled while optimizing.
                        if (hasRoute) ...[
                          const SizedBox(width: 8),
                          Consumer(builder: (context, ref, _) {
                            final generating =
                                ref.watch(isGeneratingRouteProvider);
                            return IconButton.filledTonal(
                              key: const Key('summary-clear-route'),
                              onPressed: generating
                                  ? null
                                  : () => ref
                                      .read(tripProvider.notifier)
                                      .clearOptimizedRoute(),
                              icon: const Icon(Icons.close_rounded, size: 20),
                              tooltip: 'Clear route',
                              style: IconButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .errorContainer
                                    .withValues(alpha: 0.6),
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                                padding: const EdgeInsets.all(8),
                              ),
                            );
                          }),
                        ],
                      ],
                    );
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _summaryItem(
                context,
                'Total Stops',
                '$totalStopsForDate',
              ),
              if (hasRoute) ...[
                _summaryItem(
                  context,
                  'Travel Time',
                  _formatDuration(totalTravelTime),
                ),
                _summaryItem(
                  context,
                  'Distance',
                  _formatDistance(totalDistance),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (hasRoute && !hideEta)
                _summaryItem(
                  context,
                  'ETA',
                  DateFormat('h:mm a').format(estimatedArrival),
                ),
              if (hasRoute && fareLabel != null)
                _summaryItem(context, 'Fares', fareLabel),
              // The story kernel: travel time saved vs the user's original
              // order. Only rendered when the delta is defensible (≥5 min).
              Consumer(builder: (context, ref, _) {
                final timeSaved =
                    ref.watch(tripProvider.select((s) => s.timeSaved));
                if (timeSaved < const Duration(minutes: 5)) {
                  return const SizedBox.shrink();
                }
                return _summaryItem(
                  context,
                  'Time Saved',
                  '~${_formatDuration(timeSaved)}',
                );
              }),
            ],
          ),
          // Timing issues live HERE now (not an auto-popup): an amber chip
          // that opens the warnings sheet on demand. Respects "Go anyway"
          // acknowledgements so accepted issues stop counting.
          Consumer(builder: (context, ref, _) {
            final sim = ref.watch(tripSimulationProvider);
            final acked = ref.watch(acknowledgedTimingWarningsProvider);
            final issueCount = sim == null
                ? 0
                : sim.stops
                    .where((s) =>
                        s.warnings.isNotEmpty && !acked.contains(s.locationId))
                    .length;
            if (issueCount == 0) return const SizedBox.shrink();
            const amber = Color(0xFFF5A623);
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => TimingWarningsSheet.show(context),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: amber.withValues(alpha: 0.5)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 16, color: amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$issueCount timing '
                        '${issueCount == 1 ? 'issue' : 'issues'} — tap to review',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: amber, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        size: 16, color: amber),
                  ]),
                ),
              ),
            );
          }),
          const SizedBox(height: 10),
          // Honesty note — schedules drift with traffic and dwell time.
          Text(
            'Estimates only — actual times vary with traffic and how long '
            'you stay at each stop.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.8),
                  fontStyle: FontStyle.italic,
                ),
          ),
          Consumer(builder: (context, ref, _) {
            final isGenerating = ref.watch(isGeneratingRouteProvider);
            if (!isGenerating) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Row(
                children: [
                  SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Optimizing route...', // Uses theme colors
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.primaryColor,
                        ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _summaryItem(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      ],
    );
  }

  /// PERFORMANCE: Build location widgets as a flat list to enable lazy loading
  /// Returns List<Widget> instead of nested ListViews for better performance
  /// Empty-state shown when the selected date has no locations. Sized with
  /// [MainAxisSize.min] so a [Center]/[SliverFillRemaining] can position it in
  /// the middle of the remaining viewport (notably on tall iPad sheets).
  Widget _buildEmptyDateState(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.map_outlined,
          size: 64,
          color: Theme.of(context).textTheme.bodyMedium?.color,
        ),
        const SizedBox(height: 16),
        Text(
          'No locations for this date',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Select another date or add new locations.',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// The ended trip's leftovers, as one line: how many never got a visit
  /// and the way to the review sheet (delete or move). The cards live on
  /// the trip page; the map preview is the Jump sheet's row. Empty while
  /// the trip runs or when nothing is left over.
  List<Widget> _buildUnvisitedRow(BuildContext context, WidgetRef ref) {
    final count = ref.watch(endedTripUnvisitedProvider.select((l) => l.length));
    if (count == 0) return const [];
    final theme = Theme.of(context);
    const red = Color(0xFFFF5252);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        child: Row(
          children: [
            const Icon(Icons.flag_outlined, size: 18, color: red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                count == 1
                    ? '1 place you didn\'t visit'
                    : '$count places you didn\'t visit',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: red, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: () {
                final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
                if (trip == null) return;
                showUnvisitedPlacesSheet(context,
                    trip: trip, places: ref.read(endedTripUnvisitedProvider));
              },
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('Review'),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildLocationsListWidgets(BuildContext context, WidgetRef ref,
      List<LocationModel> locations, ScrollController scrollController,
      {String query = ''}) {
    final leftovers = _buildUnvisitedRow(context, ref);
    if (locations.isEmpty) {
      // The ended trip's leftovers still render on a day they emptied;
      // otherwise this is a defensive fallback (the selected-date tab routes
      // empty dates through the centered SliverFillRemaining body in build()).
      return [
        ...leftovers,
        if (leftovers.isEmpty)
          Padding(
            padding:
                const EdgeInsets.only(left: 32, right: 32, bottom: 32, top: 16),
            child: _buildEmptyDateState(context),
          ),
      ];
    }

    final allNormal =
        locations.where((l) => !l.isSkipped && !l.isDone).toList();

    // Route facts consumed by BOTH the numbering and the timeline rails.
    // Narrow selects: they only change on (re-)optimize, never on GPS ticks.
    final railLegDetails = ref.watch(tripProvider.select((s) => s.legDetails));
    final railRouteActive =
        ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
    final railStartId =
        ref.watch(tripProvider.select((s) => s.startLocationId));
    final railStartIsCurrent = railStartId == 'current_location';

    // Unoptimized day: the active list is in the order the places were
    // ADDED, oldest first, so a new place appends at the bottom and the
    // list never reflows under the thumb. Once a route exists the list
    // follows the route order — sorting would break the map ↔ list
    // numbering.
    if (!railRouteActive) {
      allNormal.sort((a, b) => a.addedAt.compareTo(b.addedAt));
    }

    // When the route starts AT a stop, that stop is the anchor, not stop #1
    // — the map numbers the remaining stops 1…n-1 and flags the start. The
    // list must match: start card gets number 0 (rendered as the start
    // flag), the rest shift down so map "1" == list "1".
    final startStopLeadsList = railRouteActive &&
        !railStartIsCurrent &&
        allNormal.isNotEmpty &&
        allNormal.first.id == railStartId;

    // Number BEFORE filtering: a card surfaced by a search must still show
    // its real stop number, not its position within the results.
    final numberedNormal = <(LocationModel, int)>[
      for (var i = 0; i < allNormal.length; i++)
        (allNormal[i], startStopLeadsList ? i : i + 1),
    ];

    final normalLocations = numberedNormal
        .where((entry) => _matchesQuery(entry.$1, query))
        .toList();
    final skippedLocations =
        locations.where((l) => l.isSkipped && _matchesQuery(l, query)).toList();
    final doneLocations =
        locations.where((l) => l.isDone && _matchesQuery(l, query)).toList();

    // No "no matches" branch here: build() detects an empty result set for
    // the active scope and renders the centered empty body instead, so this
    // builder is only reached when something matches.

    final widgets = <Widget>[...leftovers];

    // ── Multi-modal timeline rails ─────────────────────────────────────
    // Between consecutive stop cards, the travel segment that connects
    // them (walk dashes / transit bar in the line's color / drive). Rails
    // render only when the leg list actually aligns with the visible cards
    // — searching or a stale route hides them rather than mislabel.
    final expectedLegs =
        railStartIsCurrent ? allNormal.length : allNormal.length - 1;
    // One extra leg beyond the stop count = the loop-home return to the
    // accommodation the day started from.
    final hasReturnLeg = railLegDetails.length == expectedLegs + 1;
    final railsOn = railRouteActive &&
        query.isEmpty &&
        railLegDetails.isNotEmpty &&
        (railLegDetails.length == expectedLegs || hasReturnLeg);

    LocationModel railOrigin() => LocationModel(
          id: 'current_location',
          name: 'Current location',
          address: '',
          coordinates: ref.read(tripProvider).currentLocation ??
              allNormal.first.coordinates,
          addedAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

    // ── Active stops header: count, and the sort toggle while the day is
    // unoptimized (route order takes over once optimized).
    if (normalLocations.isNotEmpty) {
      final theme = Theme.of(context);
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6, left: 4, right: 4),
        child: Row(
          children: [
            Icon(Icons.place_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Active stops',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 6),
            Text(
              '${allNormal.length}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            if (railRouteActive)
              Text(
                'Route order',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              )
            else
              Text(
                'Added order',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ));
    }

    // Normal (upcoming) locations - directly add to list. Rails key off the
    // POSITION in the unfiltered list (numbering shifts when the start stop
    // leads it, so `number` no longer equals position).
    for (var idx = 0; idx < normalLocations.length; idx++) {
      final (location, number) = normalLocations[idx];
      if (railsOn) {
        final legIndex = railStartIsCurrent ? idx : idx - 1;
        if (legIndex >= 0 && legIndex < railLegDetails.length) {
          final from = idx == 0
              ? (railStartIsCurrent ? railOrigin() : null)
              : allNormal[idx - 1];
          if (from != null) {
            widgets.add(LegRail(
              key: ValueKey('rail_${from.id}_${location.id}'),
              legIndex: legIndex,
              legData: railLegDetails[legIndex],
              from: from,
              to: location,
            ));
          }
        }
      }
      widgets.add(
        OptimizedLocationCard(
          key: ValueKey(location.id),
          location: location,
          number: number,
          // A visit order only exists once the day is optimized.
          showNumber: railRouteActive,
          scrollController: scrollController,
          sheetController: sheetController,
          onLocationTap: onLocationTap,
          tripId: _mapTripId,
          day: ref.watch(selectedDateProvider),
        ),
      );
    }

    // The loop-home rail + a quiet terminal row: the day ends where it
    // began. The accommodation is the day's first card (it's the start),
    // so it resolves locally by the leg's toId.
    if (railsOn && hasReturnLeg && allNormal.isNotEmpty) {
      final returnData = railLegDetails.last;
      final returnToId = returnData['toId'] as String?;
      LocationModel? home;
      for (final l in locations) {
        if (l.id == returnToId) {
          home = l;
          break;
        }
      }
      if (home != null) {
        widgets.add(LegRail(
          key: ValueKey('rail_return_${home.id}'),
          legIndex: railLegDetails.length - 1,
          legData: returnData,
          from: allNormal.last,
          to: home,
        ));
        widgets.add(Padding(
          // Generous bottom clearance — this terminal row sat too close
          // to the Re-optimize button below the list.
          padding: const EdgeInsets.fromLTRB(42, 2, 0, 20),
          child: Row(children: [
            Icon(Icons.hotel_outlined,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Back at ${home.name}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ));
      }
    }

    // Done locations section
    if (doneLocations.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 4.0),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text(
                'Done',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.green),
              ),
            ],
          ),
        ),
      );

      for (final location in doneLocations) {
        widgets.add(
          OptimizedLocationCard(
            key: ValueKey('done_${location.id}'),
            location: location,
            number: -2,
            scrollController: scrollController,
            sheetController: sheetController,
            onLocationTap: onLocationTap,
            tripId: _mapTripId,
            day: ref.watch(selectedDateProvider),
          ),
        );
      }
    }

    // Skipped locations section
    if (skippedLocations.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 4.0),
          child: Row(
            children: [
              Icon(Icons.remove_circle_outline,
                  color: Colors.grey[600], size: 20),
              const SizedBox(width: 8),
              Text(
                'Skipped Locations',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      );

      // Add skipped location cards
      for (final location in skippedLocations) {
        widgets.add(
          OptimizedLocationCard(
            key: ValueKey('skipped_${location.id}'),
            location: location,
            number: -1,
            scrollController: scrollController,
            sheetController: sheetController,
            onLocationTap: onLocationTap,
            tripId: _mapTripId,
            day: ref.watch(selectedDateProvider),
          ),
        );
      }
    }

    return widgets;
  }

  /// Filter field for the plan list. Scope follows the active tab: the
  /// selected day's stops, or every stop in the trip.
  Widget _buildPlanSearchField(BuildContext context) {
    final theme = Theme.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
      ),
    );

    return Padding(
      key: _searchFieldKey,
      padding: const EdgeInsets.only(top: 10),
      child: ValueListenableBuilder<String>(
        valueListenable: _searchQuery,
        builder: (context, query, _) {
          return TextField(
            cursorOpacityAnimates: false,
            controller: _searchController,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            onTap: () {
              // Expand the sheet first — otherwise the keyboard buries the
              // very results the user is typing to find.
              final ctrl = sheetController;
              if (ctrl != null &&
                  ctrl.isAttached &&
                  ctrl.size < _snapExpanded - 0.01) {
                ctrl.animateTo(
                  _snapExpanded,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                );
              }
            },
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search places in this trip',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color:
                    theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.45),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                        FocusScope.of(context).unfocus();
                      },
                    ),
              filled: true,
              fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.04),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              border: border,
              enabledBorder: border,
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: theme.colorScheme.primary, width: 1.2),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Shown when a search returns nothing in the current scope. On the
  /// selected-day tab it also reports matches sitting on OTHER days —
  /// otherwise searching a 10-day trip from one day looks broken.
  /// Nothing on this day matches the query: the matches on other days,
  /// each a tap away (the day switches and the query stays), and the trip
  /// page for everything else.
  Widget _buildNoSearchMatches(
    BuildContext context,
    WidgetRef ref,
    String query,
  ) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7);
    // Only in this branch: the whole-trip select is paid for by a search
    // that found nothing on the day, never by the common path.
    final all = ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final hits = all.where((l) => _matchesQuery(l, query)).take(8).toList();
    final labeler = ref.read(activeTripDayLabelerProvider);
    final trip = ref.read(realtimeActiveTripProvider).valueOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Column(
        // Without this the Column expands to the full height its parent
        // offers, so the enclosing Center has nothing to center and the
        // message sticks to the top.
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 44, color: muted),
          const SizedBox(height: 12),
          Text(
            'No places match "${query.trim()}" on this day',
            style: theme.textTheme.titleSmall,
            textAlign: TextAlign.center,
          ),
          if (hits.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final l in hits)
              ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined),
                title:
                    Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(l.scheduledDate == null
                    ? 'Unscheduled'
                    : labeler(l.scheduledDate!)),
                onTap: () {
                  final day = l.scheduledDate;
                  if (day == null) {
                    if (trip != null) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => TripDetailsScreen(trip: trip)),
                      );
                    }
                    return;
                  }
                  ref.read(allDaysModeProvider.notifier).state = false;
                  ref.read(selectedDateProvider.notifier).state =
                      DateTime(day.year, day.month, day.day);
                },
              ),
          ],
          if (trip != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => TripDetailsScreen(trip: trip)),
              ),
              icon: const Icon(Icons.list_alt_rounded, size: 18),
              label: const Text('Open trip page'),
            ),
          ],
        ],
      ),
    );
  }

  /// A past day's route, seen again: collapses the sheet onto the map and
  /// draws the day as it was optimized.
  Widget _viewRouteButton(BuildContext context, WidgetRef ref, Color primary) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [primary, primary.withValues(alpha: 0.8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            ref
                .read(TripBottomSheet.viewHistoricalRouteProvider.notifier)
                .state = true;
            final collapse = sheetController?.animateTo(
              0.12,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
            // Reset the list to the top after the sheet finishes
            // collapsing; animating during collapse fights the shrinking
            // viewport.
            void resetScroll() {
              if (_listScrollController.hasClients) {
                _listScrollController.jumpTo(0);
              }
            }

            if (collapse != null) {
              collapse.then((_) => resetScroll());
            } else {
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => resetScroll());
            }
          },
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 11),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.visibility_outlined, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text(
                  'View Route',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    } else {
      final kilometers = distanceInMeters / 1000;
      return '${kilometers.toStringAsFixed(1)}km';
    }
  }
}

/// Sheet-button glow in this sheet's visual language, via the shared
/// [StaticGlow] (no animation — see that widget for the measurements).
Widget _sheetStaticGlow({required Color glowColor, required Widget child}) {
  return StaticGlow(
    glowColor: glowColor,
    shape: BoxShape.rectangle,
    borderRadius: BorderRadius.circular(12),
    minBlur: 6,
    maxBlur: 24,
    maxSpread: 3,
    minAlpha: 0.25,
    maxAlpha: 0.70,
    child: child,
  );
}
