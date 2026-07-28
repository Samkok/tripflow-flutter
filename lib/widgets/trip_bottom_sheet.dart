import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../utils/date_picker_utils.dart';
import '../utils/geo_utils.dart';
import '../services/review_prompt_service.dart';
import 'timing_warnings_sheet.dart';
import '../utils/external_app_links.dart';
import '../utils/trip_date_validator.dart';
import '../utils/trip_dates.dart';
import '../core/theme.dart';
import 'accommodation_prompts.dart';
import 'app_toast.dart';
import 'optimized_location_card.dart';
import '../services/csv_service.dart';
import '../services/places_service.dart';

class TripBottomSheet extends ConsumerStatefulWidget {
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;
  final VoidCallback? onShowZoneSettings;
  final int? highlightedLocationIndex;

  /// Anchor for the map spotlight tour's "Optimize" step. Attached to the
  /// header optimize BUTTON only (never the 1–2-place nudge pill).
  final GlobalKey? optimizeKey;

  const TripBottomSheet({
    super.key,
    this.sheetController,
    this.onLocationTap,
    this.onShowZoneSettings,
    this.highlightedLocationIndex,
    this.optimizeKey,
  });

  /// Places needed before route optimization is worth offering (the "aha").
  /// Single source of truth for the goal-gradient nudges below. Distinct from
  /// [SubscriptionLimitService.freePlaceAllowance] (the paywall cap of 5) — 3
  /// unlocks Optimize, 5 hits the wall.
  static const int ahaThreshold = 3;

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

class _TripBottomSheetState extends ConsumerState<TripBottomSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

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

  // Provider to clear the optimized route when the date changes.
  // This prevents showing an old route on a new day's location list.
  final routeClearerProvider = Provider<void>((ref) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      // When the date changes, clear the old route from the state.
      ref.read(tripProvider.notifier).clearOptimizedRoute();
    });
  });

  DraggableScrollableController? get sheetController => widget.sheetController;

  /// Collapses the trip-plan sheet so the map (the thing a day/All chip just
  /// changed) is actually visible. No-op when the sheet is already at or
  /// below the collapsed size.
  void _collapseSheetForMapView() {
    final ctrl = sheetController;
    if (ctrl == null || !ctrl.isAttached) return;
    if (ctrl.size <= 0.13) return;
    ctrl.animateTo(
      0.12,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Function(LatLng)? get onLocationTap => widget.onLocationTap;
  VoidCallback? get onShowZoneSettings => widget.onShowZoneSettings;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _summaryCompact.dispose();
    _listScrollController.dispose();
    super.dispose();
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
    // OPTIMIZATION: Watch only specific fields to prevent rebuilds during drag
    // Don't watch entire tripState here since it rebuilds on every state change
    final hasPinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.isNotEmpty));

    // Auto-open the warnings sheet whenever an optimization run lands with
    // simulation warnings. zoomToFitRouteTrigger increments at the end of
    // _performRouteOptimization (and previewRouteBetween — both are user-
    // initiated route renders, both should surface timing problems). We
    // schedule on the next frame so the modal doesn't try to push during
    // build, and re-read the simulation provider then so we see the result
    // computed from the just-landed route.
    ref.listen<int>(zoomToFitRouteTrigger, (prev, next) {
      if (prev == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final sim = ref.read(tripSimulationProvider);
        if (sim == null || sim.fullyFeasible) return;
        // Filter out warnings the user has already accepted via
        // "Go anyway" in a previous run of the sheet — otherwise the
        // re-optimize that the sheet's _confirm fires would land with
        // the same warnings still present and the sheet would re-open
        // immediately, recursively. We only re-open when at least one
        // UNACKNOWLEDGED warning is on the new route.
        final acked = ref.read(acknowledgedTimingWarningsProvider);
        final hasUnacked = sim.stops
            .any((s) => s.warnings.isNotEmpty && !acked.contains(s.locationId));
        if (hasUnacked) {
          TimingWarningsSheet.show(context);
        }
      });
    });

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
        return Container(
          decoration: BoxDecoration(
            // Uses theme colors
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
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
                      Consumer(builder: (context, ref, _) {
                        final isSelectionMode =
                            ref.watch(isSelectionModeProvider);
                        return isSelectionMode
                            ? _buildSelectionModeHeader(context, ref)
                            : _buildDefaultHeader(context, ref);
                      }),
                      Consumer(builder: (context, ref, _) {
                        final selectedDate = ref.watch(selectedDateProvider);
                        final now = DateTime.now();
                        final today = DateTime(now.year, now.month, now.day);
                        final isPastDate = selectedDate.isBefore(today);
                        if (isPastDate) {
                          return _buildHistoryBanner(context);
                        }
                        return const SizedBox.shrink();
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
                  child: ListenableBuilder(
                    listenable: _tabController,
                    builder: (context, _) {
                      return Consumer(builder: (context, ref, _) {
                        // On the selected-date tab with no locations for that
                        // date, render a scroll body whose empty-state fills
                        // and centers in the remaining viewport. A plain list
                        // item would otherwise hug the top of the sheet,
                        // leaving the message stranded high up on tall screens
                        // (e.g. iPad) instead of centered. .select keeps this
                        // rebuilding only when emptiness actually flips.
                        final onSelectedDateTab =
                            !hasPinnedLocations || _tabController.index == 0;
                        final selectedDateEmpty = onSelectedDateTab &&
                            ref.watch(locationsForSelectedDateProvider
                                .select((l) => l.isEmpty));
                        if (selectedDateEmpty) {
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
                                    _buildTripDayChips(context, ref),
                                    if (hasPinnedLocations)
                                      _buildLocationsTabBar(context),
                                  ]),
                                ),
                              ),
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(32, 8, 32, 32),
                                  child: Center(
                                      child: _buildEmptyDateState(context)),
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
                            _buildTripDayChips(context, ref),
                            if (hasPinnedLocations)
                              _buildLocationsTabBar(context),
                            ListenableBuilder(
                              listenable: _tabController,
                              builder: (context, _) {
                                if (!hasPinnedLocations ||
                                    _tabController.index == 0) {
                                  return Consumer(builder: (context, ref, _) {
                                    final locationsForDate = ref.watch(
                                        locationsForSelectedDateProvider);
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: _buildLocationsListWidgets(
                                          context,
                                          ref,
                                          locationsForDate,
                                          scrollController),
                                    );
                                  });
                                }
                                return Consumer(builder: (context, ref, _) {
                                  final all = ref.watch(tripProvider
                                      .select((s) => s.pinnedLocations));
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: _buildAllLocationsGroupedByDate(
                                        context, ref, all, scrollController),
                                  );
                                });
                              },
                            ),
                            ListenableBuilder(
                              listenable: _tabController,
                              builder: (context, _) {
                                if (hasPinnedLocations &&
                                    _tabController.index != 0) {
                                  return const SizedBox.shrink();
                                }
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildOptimizeButton(
                                        context, ref, scrollController),
                                    const SizedBox(height: 12),
                                    _buildCsvDownloadButton(context, ref),
                                  ],
                                );
                              },
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
        );
      },
    );
  }

  Widget _buildDefaultHeader(BuildContext context, WidgetRef ref) {
    // OPTIMIZATION: Read values only when needed, not watched in parent
    final hasOptimizedRoute =
        ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Flexible: with Clear + Re-optimize both visible the action cluster
        // can outgrow narrow screens — the title yields (ellipsis) instead of
        // overflowing the row.
        Flexible(
          child: Text(
            'Trip Plan',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.tune),
              onPressed: onShowZoneSettings,
              color: Theme.of(context).textTheme.bodyMedium?.color,
              tooltip: 'Zone settings',
            ),
            const SizedBox(width: 4),
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
            // Clear is available from the map's FAB column — no duplicate in
            // the header.
            // Optimize affordance — ALWAYS rendered (disabled at 0 places)
            // so brand-new users see the goal from the start and the
            // first-run spotlight tour has an anchor. Formerly inside the
            // hasPinnedLocations gate, which removed it for empty states.
            Consumer(builder: (context, ref, _) {
              final isGenerating = ref.watch(isGeneratingRouteProvider);
              final locationsForDate =
                  ref.watch(locationsForSelectedDateProvider);
              final count = locationsForDate.length;
              final hasLocations = count > 0;
              // Optimization is a per-day operation — disabled while the
              // All-days overview owns the map (pick a day first).
              final allDaysMode = ref.watch(allDaysModeProvider);
              final canTap = hasLocations && !isGenerating && !allDaysMode;
              final primaryColor = Theme.of(context).colorScheme.primary;
              // Past days are read-only (the history banner says so) — never
              // coach adding places there.
              final nudgeDate = ref.watch(selectedDateProvider);
              final nudgeNow = DateTime.now();
              final isPastDate = nudgeDate.isBefore(
                  DateTime(nudgeNow.year, nudgeNow.month, nudgeNow.day));

              // Goal-gradient nudge: route optimization only pays off at 3+
              // stops, so below that we coach toward the "aha" instead of
              // offering a trivial optimize. Re-optimize stays available once
              // a route already exists.
              const ahaThreshold = TripBottomSheet.ahaThreshold;
              if (!isPastDate &&
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
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: canTap
                        ? () => _onOptimizePressed(context, ref,
                            isReoptimizing: hasOptimizedRoute)
                        : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isGenerating
                                ? Icons.hourglass_empty
                                : Icons.route_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            hasOptimizedRoute
                                ? 'Re-optimize'
                                : 'Optimize Route',
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
              return _PulsingGlow(glowColor: primaryColor, child: button);
            }),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionModeHeader(BuildContext context, WidgetRef ref) {
    final selectedCount =
        ref.watch(selectedLocationsProvider.select((s) => s.length));

    // Determine if we are on a past date to disable editing actions.
    final selectedDate = ref.watch(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPastDate = selectedDate.isBefore(today);

    // Check if user has write access to the active trip
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.asData?.value ?? false;

    // Can edit only if not past date AND has write access
    final canEdit = !isPastDate && hasWriteAccess;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                ref.read(isSelectionModeProvider.notifier).state = false;
                ref.read(selectedLocationsProvider.notifier).state = {};
              },
              color: Theme.of(context).textTheme.bodyMedium?.color,
              tooltip: 'Cancel selection',
            ),
            const SizedBox(width: 8),
            Text(
              '$selectedCount selected',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
        Row(
          children: [
            // Select All / Deselect All — scope depends on the active tab:
            //   • Selected Date tab (index 0) → only that date's locations.
            //   • All tab (index ≠ 0) → every pinned location across all
            //     dates. The list of IDs and the all-selected check both
            //     come from the same source so the checkbox tracks the
            //     visible list, not a snapshot from another tab.
            ListenableBuilder(
              listenable: _tabController,
              builder: (context, _) {
                final isAllTab = _tabController.index != 0;
                final scopedLocations = isAllTab
                    ? ref.watch(tripProvider.select((s) => s.pinnedLocations))
                    : ref.watch(locationsForSelectedDateProvider);
                final total = scopedLocations.length;
                if (total == 0) return const SizedBox.shrink();

                // "All selected" means every scoped id is present in the
                // selection set (extra ids selected from another tab don't
                // break this — they're just preserved).
                final selection = ref.watch(selectedLocationsProvider);
                final allSelected =
                    scopedLocations.every((l) => selection.contains(l.id));

                return Row(
                  children: [
                    Text(
                      allSelected
                          ? (isAllTab ? 'Deselect All' : 'Deselect All')
                          : (isAllTab ? 'Select All' : 'Select All'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Checkbox(
                      value: allSelected,
                      onChanged: (bool? value) {
                        final notifier =
                            ref.read(selectedLocationsProvider.notifier);
                        if (value == true) {
                          // Add scoped ids to the existing selection so
                          // the user doesn't lose picks made on another
                          // tab. On the Selected Date tab this still
                          // selects only that date.
                          notifier.state = {
                            ...notifier.state,
                            for (final l in scopedLocations) l.id,
                          };
                        } else {
                          // Deselect just the scoped ids — preserves
                          // selections made elsewhere.
                          final scopedIds =
                              scopedLocations.map((l) => l.id).toSet();
                          notifier.state = notifier.state
                              .where((id) => !scopedIds.contains(id))
                              .toSet();
                        }
                      },
                    ),
                  ],
                );
              },
            ),
            if (selectedCount > 0) ...[
              PopupMenuButton<String>(
                onSelected: (value) {
                  // Check write access for all write operations
                  if (!hasWriteAccess && value != 'copy') {
                    AppToast.warning(
                      context,
                      'You don\'t have permission to modify locations in this trip.',
                    );
                    return;
                  }

                  if (value == 'delete') {
                    _showMultiDeleteConfirmationDialog(context, ref);
                  } else if (value == 'move') {
                    _showMoveLocationsDialog(context, ref);
                  } else if (value == 'copy') {
                    _showCopyLocationsDialog(context, ref);
                  } else if (value == 'skip' && canEdit) {
                    _showSkipConfirmationDialog(context, ref);
                  } else if (value == 'done' && hasWriteAccess) {
                    _markSelectedAsDone(context, ref);
                  }
                },
                icon: Icon(Icons.more_vert,
                    color: Theme.of(context).textTheme.bodyMedium?.color),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'delete',
                    enabled: hasWriteAccess,
                    child: ListTile(
                      leading: Icon(
                        Icons.delete_outline,
                        color: hasWriteAccess
                            ? Theme.of(context).colorScheme.error
                            : Colors.grey,
                      ),
                      title: Text(
                        'Delete',
                        style: TextStyle(
                            color: hasWriteAccess
                                ? Theme.of(context).colorScheme.error
                                : Colors.grey),
                      ),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'move',
                    enabled: canEdit,
                    child: ListTile(
                      leading: Icon(Icons.calendar_today_outlined,
                          color: canEdit ? null : Colors.grey),
                      title: Text('Move to...',
                          style:
                              TextStyle(color: canEdit ? null : Colors.grey)),
                    ),
                  ),
                  PopupMenuItem<String>(
                    // Uses theme colors
                    value: 'skip',
                    enabled:
                        canEdit, // Disable skipping for past dates or read-only
                    child: ListTile(
                      leading: Icon(
                        Icons.remove_circle_outline,
                        color: canEdit
                            ? Theme.of(context).textTheme.bodyMedium?.color
                            : Colors.grey,
                      ),
                      title: Text('Skip',
                          style:
                              TextStyle(color: canEdit ? null : Colors.grey)),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'done',
                    enabled: hasWriteAccess,
                    child: ListTile(
                      leading: Icon(Icons.check_circle_outline,
                          color: hasWriteAccess ? Colors.green : Colors.grey),
                      title: Text('Mark as Done',
                          style: TextStyle(
                              color:
                                  hasWriteAccess ? Colors.green : Colors.grey)),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'copy',
                    child: ListTile(
                        leading: Icon(Icons.copy), title: Text('Copy to...')),
                  ),
                ],
              ),
            ]
            // Add other multi-select actions here (e.g., share, group)
          ],
        ),
      ],
    );
  }

  Widget _buildDatePicker(BuildContext context, WidgetRef ref) {
    return Consumer(builder: (context, ref, _) {
      // Watch the routeClearerProvider to activate the listener.
      ref.watch(routeClearerProvider);

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

                final newDate = await DatePickerUtils.showCustomDatePicker(
                  context: context,
                  initialDate: initialDateForPicker,
                  firstDate: firstDate,
                  lastDate: DateTime.now().add(
                      const Duration(days: 365 * 5)), // 5 years in the future
                  highlightedDates: highlightedDates,
                );

                if (newDate != null) {
                  ref.read(selectedDateProvider.notifier).state = newDate;
                }
              },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(
                isToday ? 'Today' : DateFormat.yMMMd().format(selectedDate),
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

  /// Horizontal strip of per-day quick-jump chips covering every day the
  /// trip spans. Each chip shows "N · MMM d" (N is 1-based day index) and
  /// sets [selectedDateProvider] when tapped. The day axis is the full,
  /// gap-free span of the trip — its declared start..end range unioned with
  /// every scheduled location, with in-between days filled — so a trip with
  /// no explicit date range still gets one chip per planned day, and an
  /// empty interstitial day (e.g. Jan 2 between stops on Jan 1 and Jan 3)
  /// still gets a chip. Returns an empty widget only when the trip touches
  /// no dates at all.
  Widget _buildTripDayChips(BuildContext context, WidgetRef ref) {
    final activeTripAsync = ref.watch(realtimeActiveTripProvider);
    final trip = activeTripAsync.asData?.value;
    final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));

    final days = contiguousTripDates([
      trip?.startDate,
      trip?.endDate,
      for (final loc in locations) ...[
        loc.scheduledDate ?? loc.addedAt,
        loc.scheduledEndDate ?? loc.scheduledDate ?? loc.addedAt,
      ],
    ]);
    if (days.isEmpty) return const SizedBox.shrink();

    final selectedRaw = ref.watch(selectedDateProvider);
    final selected =
        DateTime(selectedRaw.year, selectedRaw.month, selectedRaw.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final theme = Theme.of(context);
    // Accent reserved for "this chip is today's date" so it stays visually
    // distinct from the primary-color "selected" treatment. Green reads as
    // "live/current" and doesn't collide with the brand primary.
    final todayAccent = Colors.green.shade600;

    final allDaysMode = ref.watch(allDaysModeProvider);
    final dayColors = ref.watch(tripDayColorsProvider);

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        // Index 0 is the "All" chip; day chips follow, shifted by one.
        itemCount: days.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final primary = theme.colorScheme.primary;

          // ── "All" chip — every day's route at once, each in its color. ──
          // Deliberately styled apart from the date chips (solid fill +
          // layers icon vs their outline look) so it reads as a MODE, not
          // another date.
          if (index == 0) {
            final fg = allDaysMode ? theme.colorScheme.onPrimary : primary;
            return TextButton(
              onPressed: () {
                ref.read(allDaysModeProvider.notifier).state = true;
                _collapseSheetForMapView();
              },
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: fg,
                backgroundColor:
                    allDaysMode ? primary : primary.withValues(alpha: 0.14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color:
                        allDaysMode ? primary : primary.withValues(alpha: 0.55),
                    width: allDaysMode ? 1.6 : 1,
                  ),
                ),
                textStyle: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_rounded, size: 14, color: fg),
                  const SizedBox(width: 5),
                  const Text('All'),
                ],
              ),
            );
          }

          final day = days[index - 1];
          // While All-days mode is on, the mode owns the selection — no
          // individual day renders as selected.
          final isSelected = !allDaysMode && day.isAtSameMomentAs(selected);
          final isToday = day.isAtSameMomentAs(today);

          // Color resolution: "selected" wins on the fill/border (primary
          // tint), "today (unselected)" gets its own accent treatment, and
          // a plain chip is the default. The "TODAY" pill below makes the
          // current day stand out even when it's also the selected one.
          final Color fg;
          final Color bg;
          final Color borderColor;
          if (isSelected) {
            fg = primary;
            bg = primary.withValues(alpha: 0.12);
            borderColor = primary.withValues(alpha: 0.6);
          } else if (isToday) {
            fg = todayAccent;
            bg = todayAccent.withValues(alpha: 0.10);
            borderColor = todayAccent.withValues(alpha: 0.55);
          } else {
            fg = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.75) ??
                theme.colorScheme.onSurface;
            bg = Colors.transparent;
            borderColor = theme.dividerColor.withValues(alpha: 0.4);
          }

          final dateLabel = isToday ? 'Today' : DateFormat('MMM d').format(day);

          // Each day's route color, shown as a leading dot — doubles as the
          // legend for All-days mode and stays consistent because the same
          // provider colors the map polylines.
          final routeColor = dayColors[day];

          return TextButton(
            onPressed: () {
              // Picking a specific day always leaves All-days mode.
              ref.read(allDaysModeProvider.notifier).state = false;
              ref.read(selectedDateProvider.notifier).state = day;
              _collapseSheetForMapView();
            },
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: fg,
              backgroundColor: bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: borderColor),
              ),
              textStyle: theme.textTheme.labelMedium?.copyWith(
                fontWeight:
                    (isSelected || isToday) ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (routeColor != null) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: routeColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Text('$index · $dateLabel'),
                if (isToday) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: todayAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.cardColor,
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
          if (totalStopsForDate >= 2) ...[
            const SizedBox(width: 8),
            Consumer(builder: (context, ref, _) {
              return SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  onPressed: () => _openGoogleMaps(context, ref),
                  icon: const Icon(Icons.directions, size: 18),
                  tooltip: 'Open in Google Maps',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor:
                        theme.colorScheme.primary.withValues(alpha: 0.15),
                    foregroundColor: theme.colorScheme.primary,
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildTripSummary(BuildContext context, Duration totalTravelTime,
      double totalDistance, int totalStopsForDate,
      {required bool hasRoute, required bool hideEta}) {
    final estimatedArrival = DateTime.now().add(totalTravelTime);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
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
                        if (hasRoute) const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: () => _openGoogleMaps(context, ref),
                          icon: const Icon(Icons.directions, size: 20),
                          tooltip: 'Open in Google Maps',
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

  // Opens Google Maps with directions from the first to last location with
  // waypoints. Hands off via [openDirectionsInGoogleMaps] so each stop's
  // place_id is preferred over its lat/lng — that way renamed entries
  // still resolve to the exact Google place on the receiving end.
  Future<void> _openGoogleMaps(BuildContext context, WidgetRef ref) async {
    try {
      final locations = ref.read(locationsForSelectedDateProvider);

      if (locations.length < 2) {
        if (context.mounted) {
          AppToast.warning(
            context,
            'Need at least 2 locations to open directions',
          );
        }
        return;
      }

      await openDirectionsInGoogleMaps(
        origin: locations.first,
        destination: locations.last,
        waypoints: locations.length > 2
            ? locations.sublist(1, locations.length - 1)
            : const [],
      );
    } catch (e) {
      debugPrint('Error opening Google Maps: $e');
      if (context.mounted) {
        AppToast.error(context, 'Failed to open Google Maps: $e');
      }
    }
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

  List<Widget> _buildLocationsListWidgets(BuildContext context, WidgetRef ref,
      List<LocationModel> locations, ScrollController scrollController) {
    if (locations.isEmpty) {
      // Defensive fallback. The selected-date tab routes empty dates through
      // the centered SliverFillRemaining body in build(), so this path is only
      // reached if a caller passes an empty list directly.
      return [
        Padding(
          padding:
              const EdgeInsets.only(left: 32, right: 32, bottom: 32, top: 16),
          child: _buildEmptyDateState(context),
        ),
      ];
    }

    final normalLocations =
        locations.where((l) => !l.isSkipped && !l.isDone).toList();
    final skippedLocations = locations.where((l) => l.isSkipped).toList();
    final doneLocations = locations.where((l) => l.isDone).toList();

    final widgets = <Widget>[];

    // Normal (upcoming) locations - directly add to list
    for (int i = 0; i < normalLocations.length; i++) {
      final location = normalLocations[i];
      widgets.add(
        OptimizedLocationCard(
          key: ValueKey(location.id),
          location: location,
          number: i + 1,
          scrollController: scrollController,
          sheetController: sheetController,
          onLocationTap: onLocationTap,
        ),
      );
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
          ),
        );
      }
    }

    return widgets;
  }

  /// Tab bar that switches between the locations for the selected date
  /// and a grouped-by-date view of every location in the trip.
  Widget _buildLocationsTabBar(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: TabBar(
          controller: _tabController,
          labelColor: Colors.black,
          unselectedLabelColor: theme.textTheme.bodyMedium?.color,
          indicator: BoxDecoration(
            color: primary,
            borderRadius: BorderRadius.circular(12),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'This day'),
            Tab(text: 'Whole trip'),
          ],
        ),
      ),
    );
  }

  /// Builds the "All" tab — every location in the trip, grouped by their
  /// scheduledDate. Tapping a date header makes that date the selected date
  /// and switches the user back to the "Selected Date" tab.
  List<Widget> _buildAllLocationsGroupedByDate(
    BuildContext context,
    WidgetRef ref,
    List<LocationModel> all,
    ScrollController scrollController,
  ) {
    if (all.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            children: [
              Icon(Icons.event_note_outlined,
                  size: 64,
                  color: Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(height: 16),
              Text('No locations yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Add locations to see them grouped by date here.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ];
    }

    // Group by date-only key. Locations without a scheduledDate fall back to
    // their addedAt date — matches the behavior of locationsForSelectedDateProvider.
    final Map<DateTime, List<LocationModel>> grouped = {};
    for (final loc in all) {
      final raw = loc.scheduledDate ?? loc.addedAt;
      final key = DateTime(raw.year, raw.month, raw.day);
      grouped.putIfAbsent(key, () => []).add(loc);
    }

    // Show every day the trip spans — including empty in-between days — not
    // only days that already host a location. Union the contiguous trip span
    // (declared range + scheduled locations, gaps filled) with the group keys
    // so nothing is orphaned. Same helper as the day-chip strip and the trip
    // detail page, so all three surfaces show identical days.
    final trip = ref.watch(realtimeActiveTripProvider).asData?.value;
    final span = contiguousTripDates([
      trip?.startDate,
      trip?.endDate,
      for (final loc in all) ...[
        loc.scheduledDate ?? loc.addedAt,
        loc.scheduledEndDate ?? loc.scheduledDate ?? loc.addedAt,
      ],
    ]);
    final sortedDates = (<DateTime>{...span, ...grouped.keys}.toList())..sort();

    final selectedDate = ref.watch(selectedDateProvider);
    final today =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final widgets = <Widget>[];
    for (final date in sortedDates) {
      final locs = grouped[date] ?? const <LocationModel>[];
      final isSelected = date == selectedDate;
      widgets.add(_buildDateGroupHeader(context, date, today, locs.length,
          isSelected: isSelected, onTap: () {
        ref.read(selectedDateProvider.notifier).state = date;
        _tabController.animateTo(0);
      }));

      // Sort within a date: upcoming first, then done, then skipped.
      final normal = locs.where((l) => !l.isSkipped && !l.isDone).toList();
      final done = locs.where((l) => l.isDone).toList();
      final skipped = locs.where((l) => l.isSkipped).toList();
      final ordered = [...normal, ...done, ...skipped];

      // Empty in-between day: keep the header (so the day is visible and
      // tappable to plan it) with a muted placeholder instead of cards.
      if (ordered.isEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 4),
          child: Text(
            'No places scheduled yet',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.5),
                  fontStyle: FontStyle.italic,
                ),
          ),
        ));
        continue;
      }

      for (int i = 0; i < ordered.length; i++) {
        final loc = ordered[i];
        widgets.add(OptimizedLocationCard(
          key: ValueKey('all_${date.toIso8601String()}_${loc.id}'),
          location: loc,
          number: loc.isDone ? -2 : (loc.isSkipped ? -1 : i + 1),
          scrollController: scrollController,
          sheetController: sheetController,
          onLocationTap: onLocationTap,
        ));
      }
    }
    return widgets;
  }

  Widget _buildDateGroupHeader(
    BuildContext context,
    DateTime date,
    DateTime today,
    int count, {
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isToday = date == today;
    final isPast = date.isBefore(today);

    String label;
    if (isToday) {
      label = 'Today · ${DateFormat.MMMd().format(date)}';
    } else if (date == today.add(const Duration(days: 1))) {
      label = 'Tomorrow · ${DateFormat.MMMd().format(date)}';
    } else {
      label = DateFormat('EEE, MMM d, y').format(date);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? primary.withValues(alpha: 0.18)
                  : primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? primary : primary.withValues(alpha: 0.2),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isPast ? Icons.history : Icons.calendar_today_outlined,
                  size: 18,
                  color: primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: isSelected ? primary : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: theme.textTheme.bodyMedium?.color
                        ?.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build optimize and CSV buttons as separate widgets
  Widget _buildOptimizeButton(
      BuildContext context, WidgetRef ref, ScrollController scrollController) {
    return Consumer(builder: (context, ref, _) {
      final isGenerating = ref.watch(isGeneratingRouteProvider);
      final hasRoute =
          ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
      final selectedDate = ref.watch(selectedDateProvider);
      final locationsForDate = ref.watch(locationsForSelectedDateProvider);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isPastDate = selectedDate.isBefore(today);

      final isViewingHistory = isPastDate && hasRoute;
      final hasLocations = locationsForDate.isNotEmpty;

      // Same goal-gradient rule as the header button: optimization only
      // pays off at 3+ stops, so below that we coach toward the "aha"
      // instead of offering a trivial optimize. Re-optimize stays
      // available once a route already exists.
      const ahaThreshold = TripBottomSheet.ahaThreshold;
      final stopCount = locationsForDate.length;
      if (stopCount > 0 &&
          stopCount < ahaThreshold &&
          !hasRoute &&
          !isGenerating &&
          // Any past date is read-only — never nudge there (isViewingHistory
          // alone misses past days that have no route yet).
          !isPastDate) {
        final remaining = ahaThreshold - stopCount;
        final primaryColor = Theme.of(context).colorScheme.primary;
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: primaryColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: primaryColor.withValues(alpha: 0.30)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_location_alt_rounded,
                  color: primaryColor, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Add $remaining more place${remaining == 1 ? '' : 's'} to optimize',
                  style: TextStyle(
                    color: primaryColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      String buttonText;
      VoidCallback? onPressedAction;

      final allDaysMode = ref.watch(allDaysModeProvider);
      if (allDaysMode) {
        // Optimization is a per-day operation — disabled while the All-days
        // overview owns the map. Tapping a day chip re-enables it.
        buttonText = 'Optimize Route';
        onPressedAction = null;
      } else if (isGenerating) {
        buttonText = 'Optimizing...';
        onPressedAction = null;
      } else if (isViewingHistory) {
        buttonText = 'View Route';
        onPressedAction = () {
          ref.read(TripBottomSheet.viewHistoricalRouteProvider.notifier).state =
              true;
          final collapse = sheetController?.animateTo(
            0.12,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
          // Reset the list to the top after the sheet finishes collapsing.
          // Animating during collapse fights the shrinking viewport (the
          // DraggableScrollableSheet's scroll controller treats edge-pulls
          // as drags), and the list is hidden anyway by the time it lands —
          // so a post-collapse jumpTo is both reliable and invisible.
          void resetScroll() {
            if (scrollController.hasClients) scrollController.jumpTo(0);
          }

          if (collapse != null) {
            collapse.then((_) => resetScroll());
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) => resetScroll());
          }
        };
      } else if (!hasLocations) {
        buttonText = 'Optimize Route';
        onPressedAction = null; // disabled — no locations for this date
      } else {
        buttonText = hasRoute ? 'Re-optimize Route' : 'Optimize Route';
        onPressedAction =
            () => _onOptimizePressed(context, ref, isReoptimizing: hasRoute);
      }

      final canGlow = onPressedAction != null && !isGenerating;
      final primaryColor = Theme.of(context).colorScheme.primary;

      final button = SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onPressedAction,
          icon: isGenerating
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : Icon(
                  isViewingHistory ? Icons.visibility_outlined : Icons.route),
          label: Text(buttonText),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      );

      final primary = canGlow
          ? _PulsingGlow(glowColor: primaryColor, child: button)
          : button;

      // Clear is available from the map's FAB column — no duplicate in the
      // sheet's action area.
      return primary;
    });
  }

  Widget _buildCsvDownloadButton(BuildContext context, WidgetRef ref) {
    return Consumer(builder: (context, ref, _) {
      final locations = ref.watch(locationsForSelectedDateProvider);
      final isGenerating = ref.watch(isGeneratingRouteProvider);

      if (locations.isEmpty) return const SizedBox.shrink();

      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: isGenerating
              ? null
              : () async {
                  try {
                    final csvService = CsvService();
                    await csvService.generateAndShareTripCsv(locations);
                  } on MissingPluginException {
                    if (context.mounted) {
                      AppToast.warning(
                        context,
                        'Please restart the app to enable CSV download.',
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      AppToast.error(
                        context,
                        'Failed to download CSV. Please restart the app.',
                      );
                    }
                  }
                },
          icon: const Icon(Icons.download),
          label: const Text('Download Trip CSV'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            side: BorderSide(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
    });
  }

  /// The very first optimize on this install skips the start-point chooser and
  /// delivers the reward immediately — the reveal IS the product, and gating it
  /// behind a decision dilutes the aha (Fogg: reduce ability cost before adding
  /// motivation). The provider's fallback picks a safe start (current location
  /// only when it's plausibly near the stops — see geo_utils; else the first
  /// stop). Start-point choice stays discoverable on every re-optimize.
  Future<void> _onOptimizePressed(BuildContext context, WidgetRef ref,
      {required bool isReoptimizing}) async {
    // Defense-in-depth: both optimize buttons are disabled in All-days mode,
    // but any future caller lands here too. Optimization is per-day — the
    // user picks a day first.
    if (ref.read(allDaysModeProvider)) {
      AppToast.info(context, 'Pick a day first — optimization works per day.');
      return;
    }
    if (!isReoptimizing) {
      final lifetimeOptimizes =
          await ReviewPromptService.instance.getSuccessfulOptimizeCount();
      if (lifetimeOptimizes == 0) {
        final selectedDate = ref.read(selectedDateProvider);
        await ref
            .read(tripProvider.notifier)
            .generateOptimizedRoute(selectedDate: selectedDate);
        return;
      }
    }
    if (!context.mounted) return;
    _showChooseStartPointDialog(context, ref, isReoptimizing: isReoptimizing);
  }

  void _showChooseStartPointDialog(BuildContext context, WidgetRef ref,
      {required bool isReoptimizing}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StartPointSheet(isReoptimizing: isReoptimizing),
    );
  }

  void _showMultiDeleteConfirmationDialog(BuildContext context, WidgetRef ref) {
    final selectedCount = ref.read(selectedLocationsProvider).length;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor, // Uses theme colors
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Delete $selectedCount Locations?'),
          content: const Text(
              'Are you sure you want to permanently delete the selected locations? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final selectedIds = ref.read(selectedLocationsProvider);
                // Day-aware: a multi-day row (e.g. a spanning accommodation)
                // caught in the selection only loses the day being viewed —
                // its other days survive. Single-day rows delete outright.
                ref.read(tripProvider.notifier).removeLocationsFromDay(
                    selectedIds, ref.read(selectedDateProvider));
                // Exit selection mode after action
                ref.read(isSelectionModeProvider.notifier).state = false;
                ref.read(selectedLocationsProvider.notifier).state = {};
                Navigator.of(dialogContext).pop(); // Close the dialog
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _showCopyLocationsDialog(BuildContext context, WidgetRef ref) async {
    final highlightedDates = ref.read(datesWithLocationsProvider);
    final earliestDate = highlightedDates.isNotEmpty
        ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
        : DateTime.now();

    final newDate = await DatePickerUtils.showCustomDatePicker(
      context: context,
      initialDate: ref.read(selectedDateProvider),
      firstDate: earliestDate,
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      highlightedDates: highlightedDates,
    );

    if (newDate != null) {
      final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
      if (!context.mounted) return;
      final allowed = await ensureScheduledDateAllowed(
        context,
        activeTrip,
        newDate,
        actionLabel: 'Copy anyway',
      );
      if (!allowed) return;

      final selectedIds = ref.read(selectedLocationsProvider);
      // Captured before the write: copying onto a previously-empty day
      // materializes a new trip day → ask about accommodation after.
      final dayKey = DateTime(newDate.year, newDate.month, newDate.day);
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      await ref
          .read(tripProvider.notifier)
          .copyMultipleLocationsToDate(selectedIds, newDate);

      // Exit selection mode and clear selections
      ref.read(isSelectionModeProvider.notifier).state = false;
      ref.read(selectedLocationsProvider.notifier).state = {};

      // Switch the view to the new date to show the copied items
      ref.read(selectedDateProvider.notifier).state = newDate;

      // NOTE: use the STATE's context/ref, not the parameters — the caller's
      // context belongs to the selection action bar, which unmounts when
      // selection mode exits above, silently skipping the prompt.
      if (dayWasEmpty && activeTrip != null && mounted) {
        await maybePromptAccommodationForNewDays(
          this.context,
          this.ref,
          trip: activeTrip,
          newDays: [dayKey],
        );
      }
    }
  }

  void _showMoveLocationsDialog(BuildContext context, WidgetRef ref) async {
    final highlightedDates = ref.read(datesWithLocationsProvider);
    final earliestDate = highlightedDates.isNotEmpty
        ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
        : DateTime.now();

    final newDate = await DatePickerUtils.showCustomDatePicker(
      context: context,
      initialDate: ref.read(selectedDateProvider),
      firstDate: earliestDate,
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      highlightedDates: highlightedDates,
    );

    if (newDate != null) {
      final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
      if (!context.mounted) return;
      final allowed = await ensureScheduledDateAllowed(
        context,
        activeTrip,
        newDate,
        actionLabel: 'Move anyway',
      );
      if (!allowed) return;

      final selectedIds = ref.read(selectedLocationsProvider);
      // Captured before the write: moving onto a previously-empty day
      // materializes a new trip day → ask about accommodation after.
      final dayKey = DateTime(newDate.year, newDate.month, newDate.day);
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      await ref
          .read(tripProvider.notifier)
          .updateMultipleLocationsScheduledDate(selectedIds, newDate);

      // Exit selection mode and clear selections
      ref.read(isSelectionModeProvider.notifier).state = false;
      ref.read(selectedLocationsProvider.notifier).state = {};

      // Optionally, switch the view to the new date
      ref.read(selectedDateProvider.notifier).state = newDate;

      // NOTE: use the STATE's context/ref, not the parameters — the caller's
      // context belongs to the selection action bar, which unmounts when
      // selection mode exits above, silently skipping the prompt.
      if (dayWasEmpty && activeTrip != null && mounted) {
        await maybePromptAccommodationForNewDays(
          this.context,
          this.ref,
          trip: activeTrip,
          newDays: [dayKey],
        );
      }
    }
  }

  void _markSelectedAsDone(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.read(selectedLocationsProvider);
    ref.read(tripProvider.notifier).markLocationsAsDone(selectedIds);
    ref.read(isSelectionModeProvider.notifier).state = false;
    ref.read(selectedLocationsProvider.notifier).state = {};
  }

  void _showSkipConfirmationDialog(BuildContext context, WidgetRef ref) {
    final selectedCount = ref.read(selectedLocationsProvider).length;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Skip $selectedCount Locations?'),
          content: const Text(
              'Are you sure you want to skip the selected locations? They will be excluded from the route but remain on the map.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final selectedIds = ref.read(selectedLocationsProvider);
                ref
                    .read(tripProvider.notifier)
                    .skipMultipleLocations(selectedIds);
                ref.read(isSelectionModeProvider.notifier).state = false;
                ref.read(selectedLocationsProvider.notifier).state = {};
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Skip'),
            ),
          ],
        );
      },
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

// Lightweight pulsing glow — no external dependencies.
// Wraps its child with an animated box-shadow that pulses in and out.
class _PulsingGlow extends StatefulWidget {
  final Widget child;
  final Color glowColor;

  const _PulsingGlow({
    required this.child,
    required this.glowColor,
  });

  @override
  State<_PulsingGlow> createState() => _PulsingGlowState();
}

class _PulsingGlowState extends State<_PulsingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color:
                  widget.glowColor.withValues(alpha: 0.25 + _glow.value * 0.45),
              blurRadius: 6 + _glow.value * 18,
              spreadRadius: _glow.value * 3,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Bottom-sheet "Choose starting point" UI. Replaces the previous cramped
/// AlertDialog. Lays out:
///   - A prominent "Start at" card sourced from [effectiveTripStartTimeProvider].
///   - "My Location" (when device location is known).
///   - "Active stops" — the day's stops eligible for optimization.
///   - "Skipped & done" — usable as a route anchor but excluded from the
///     optimizer. Lets users start the next leg from a place they already
///     visited (or one they decided to skip) without re-adding it to the
///     plan.
class _StartPointSheet extends ConsumerStatefulWidget {
  final bool isReoptimizing;
  const _StartPointSheet({required this.isReoptimizing});

  @override
  ConsumerState<_StartPointSheet> createState() => _StartPointSheetState();
}

class _StartPointSheetState extends ConsumerState<_StartPointSheet> {
  String? _selectedStartId;
  bool _initialized = false;

  // Country-mismatch gate for the "My current location" anchor.
  //
  // Trip has a tagged country and the device is sitting in a different one
  // (e.g. user planning a Tokyo trip from home in NYC). Anchoring the
  // optimizer to the device GPS would silently route a leg across the
  // ocean. We disable the option in that case and tell the user to pick a
  // stop inside the trip's country.
  //
  // Resolution is a single reverse-geocode kicked off the first time the
  // sheet builds with the data it needs; cached in [_currentCountryCode]
  // afterward.
  bool _countryCheckStarted = false;
  bool _countryCheckInFlight = false;
  String? _currentCountryCode; // ISO-2 of the device GPS, once resolved.

  Future<void> _resolveCurrentCountry(LatLng coords) async {
    if (_countryCheckStarted) return;
    _countryCheckStarted = true;
    setState(() => _countryCheckInFlight = true);
    try {
      final details = await PlacesService.getPlaceFromCoordinates(coords);
      if (!mounted) return;
      setState(() {
        _currentCountryCode = details?.countryCode?.toUpperCase();
        _countryCheckInFlight = false;
      });
    } catch (_) {
      if (!mounted) return;
      // On failure, leave _currentCountryCode null so we don't block the
      // option — the strict country guard at add time still has the user's
      // back if the chosen anchor is actually wrong.
      setState(() => _countryCheckInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tripState = ref.watch(tripProvider);
    final selectedDate = ref.watch(selectedDateProvider);
    final activeTrip = ref.watch(realtimeActiveTripProvider).asData?.value;
    final tripCountry = activeTrip?.countryCode?.toUpperCase();

    // Day's stops — including skipped/done, since those can serve as
    // anchors even though they won't be visited by the optimizer.
    final dayStops = tripState.pinnedLocations
        .where((loc) => loc.isActiveOnDate(selectedDate))
        .toList();
    // The day's accommodation gets its own section (and is the default
    // anchor — days naturally start from where you slept).
    final dayAccommodations = dayStops.where((l) => l.isAccommodation).toList();
    final activeStops = dayStops
        .where((l) => !l.isSkipped && !l.isDone && !l.isAccommodation)
        .toList();
    final inactiveStops = dayStops
        .where((l) => (l.isSkipped || l.isDone) && !l.isAccommodation)
        .toList();
    final hasCurrentLocation = tripState.currentLocation != null;

    // Kick off a one-shot reverse geocode the moment we know the trip has
    // a tagged country and the device has a fix. Cheap to call repeatedly
    // — _resolveCurrentCountry guards itself via [_countryCheckStarted].
    if (tripCountry != null && tripState.currentLocation != null) {
      _resolveCurrentCountry(tripState.currentLocation!);
    }

    // True only once we've confirmed the device is in a DIFFERENT country
    // than the trip. Null country code (lookup pending or failed) is not
    // a mismatch — we don't want a flaky geocode to lock out the option.
    final bool currentLocationMismatch;
    if (tripCountry != null) {
      currentLocationMismatch =
          _currentCountryCode != null && _currentCountryCode != tripCountry;
    } else {
      // No trip country (anonymous session / country-less trip): fall back to
      // proximity — if the device is far from every stop, anchoring the route
      // to its GPS would route a leg across the world (e.g. optimizing the
      // Lisbon sample from a phone in Cambodia).
      currentLocationMismatch = hasCurrentLocation &&
          dayStops.isNotEmpty &&
          minMetersToAny(tripState.currentLocation!,
                  dayStops.map((s) => s.coordinates)) >
              kForeignFallbackMeters;
    }
    final currentLocationDisabled =
        hasCurrentLocation && currentLocationMismatch;

    // Default selection on first build — runs once. The day's accommodation
    // wins (routes naturally start from where you're staying); then the
    // device GPS unless it's known to be in the wrong country; then stops.
    if (!_initialized) {
      _initialized = true;
      final canPreselectCurrent =
          hasCurrentLocation && !currentLocationDisabled;
      _selectedStartId = dayAccommodations.isNotEmpty
          ? dayAccommodations.first.id
          : canPreselectCurrent
              ? 'current_location'
              : (activeStops.isNotEmpty
                  ? activeStops.first.id
                  : (inactiveStops.isNotEmpty ? inactiveStops.first.id : null));
    } else if (currentLocationDisabled &&
        _selectedStartId == 'current_location') {
      // The country lookup landed AFTER the first build and invalidated
      // the device-GPS preselection — swap to the accommodation / first
      // usable stop so the Optimize button doesn't fire with a
      // now-disabled anchor.
      _selectedStartId = dayAccommodations.isNotEmpty
          ? dayAccommodations.first.id
          : activeStops.isNotEmpty
              ? activeStops.first.id
              : (inactiveStops.isNotEmpty ? inactiveStops.first.id : null);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.isReoptimizing
                                ? 'Re-optimize from'
                                : 'Choose starting point',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Pick where today\'s route should begin.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Cancel',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  children: [
                    _buildStartAtCard(context),
                    const SizedBox(height: 16),
                    if (dayAccommodations.isNotEmpty) ...[
                      _sectionLabel(context, 'Accommodation'),
                      ...dayAccommodations.map((loc) => _StartPointTile(
                            leading: Icon(Icons.hotel_outlined,
                                color: theme.colorScheme.primary),
                            title: loc.name,
                            subtitle: 'Your stay — start the day from here',
                            value: loc.id,
                            groupValue: _selectedStartId,
                            onChanged: (v) =>
                                setState(() => _selectedStartId = v),
                          )),
                      const SizedBox(height: 16),
                    ],
                    if (hasCurrentLocation) ...[
                      _sectionLabel(context, 'My location'),
                      _StartPointTile(
                        leading: Icon(Icons.my_location,
                            color: currentLocationDisabled
                                ? theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5)
                                : theme.colorScheme.primary),
                        title: 'My current location',
                        subtitle: currentLocationDisabled
                            ? (tripCountry != null
                                ? 'You\'re outside this trip\'s country — pick a stop within ${activeTrip?.countryCode ?? 'the trip\'s region'} to start from instead.'
                                : 'You\'re far from these stops — pick a stop to start from instead.')
                            : (_countryCheckInFlight && tripCountry != null
                                ? 'Checking whether you\'re in the trip\'s country…'
                                : 'Use device GPS as the start anchor'),
                        value: 'current_location',
                        groupValue: _selectedStartId,
                        onChanged: (v) => setState(() => _selectedStartId = v),
                        disabled: currentLocationDisabled,
                      ),
                      const SizedBox(height: 16),
                    ],
                    _sectionLabel(
                      context,
                      'Active stops',
                      trailing:
                          activeStops.isEmpty ? null : '${activeStops.length}',
                    ),
                    if (activeStops.isEmpty)
                      _emptyHint(
                          context, 'No active stops on this day to start from.')
                    else
                      ...activeStops.map((loc) => _StartPointTile(
                            leading: Icon(Icons.place_outlined,
                                color: theme.colorScheme.primary),
                            title: loc.name,
                            subtitle:
                                loc.address.isNotEmpty ? loc.address : null,
                            value: loc.id,
                            groupValue: _selectedStartId,
                            onChanged: (v) =>
                                setState(() => _selectedStartId = v),
                          )),
                    if (inactiveStops.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _sectionLabel(
                        context,
                        'Skipped & done',
                        trailing: '${inactiveStops.length}',
                      ),
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8, left: 4, right: 4),
                        child: Text(
                          'Selectable as anchor only — these aren\'t '
                          'included in the optimized route.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      ...inactiveStops.map((loc) => _StartPointTile(
                            leading: Icon(
                              loc.isDone
                                  ? Icons.check_circle_outline
                                  : Icons.remove_circle_outline,
                              color: loc.isDone
                                  ? Colors.green.shade600
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            title: loc.name,
                            subtitle:
                                loc.address.isNotEmpty ? loc.address : null,
                            value: loc.id,
                            groupValue: _selectedStartId,
                            onChanged: (v) =>
                                setState(() => _selectedStartId = v),
                            statusChip: _StatusChip(
                              label: loc.isDone ? 'Done' : 'Skipped',
                              color: loc.isDone
                                  ? Colors.green.shade600
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            mutedTitle: true,
                          )),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: _selectedStartId == null
                              ? null
                              : () {
                                  final id = _selectedStartId!;
                                  Navigator.of(context).pop();
                                  // Fresh user-initiated optimize:
                                  // clear any "Go anyway" acknowledgements
                                  // from a previous planning attempt so
                                  // warnings re-surface from scratch.
                                  ref
                                      .read(acknowledgedTimingWarningsProvider
                                          .notifier)
                                      .state = const {};
                                  ref
                                      .read(tripProvider.notifier)
                                      .generateOptimizedRoute(
                                          startLocationId: id,
                                          selectedDate: selectedDate);
                                },
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(
                            widget.isReoptimizing ? 'Re-optimize' : 'Optimize',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStartAtCard(BuildContext context) {
    final theme = Theme.of(context);
    final start = ref.watch(effectiveTripStartTimeProvider);
    final timeLabel =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: start.hour, minute: start.minute),
          helpText: 'Start at',
        );
        if (picked == null) return;
        ref.read(tripStartTimeOverrideProvider.notifier).state = picked;
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.schedule_rounded,
                  color: theme.colorScheme.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Start at',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    timeLabel,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.edit_outlined,
                size: 18,
                color: theme.colorScheme.primary.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text, {String? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                trailing,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Card-style "radio" row used inside [_StartPointSheet]. Larger tap target
/// than RadioListTile and shows an optional status chip for skipped/done
/// stops.
class _StartPointTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final String value;
  final String? groupValue;
  final ValueChanged<String?> onChanged;
  final Widget? statusChip;
  final bool mutedTitle;
  final bool disabled;

  const _StartPointTile({
    required this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.statusChip,
    this.mutedTitle = false,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = !disabled && value == groupValue;
    final fadedTitleColor =
        theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.45);
    final fadedSubtitleColor =
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
    final borderColor = disabled
        ? theme.dividerColor.withValues(alpha: 0.25)
        : (isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.6)
            : theme.dividerColor.withValues(alpha: 0.3));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: disabled ? 0.6 : 1.0,
        child: Material(
          color: disabled
              ? theme.cardColor.withValues(alpha: 0.6)
              : (isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.08)
                  : theme.cardColor),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: disabled ? null : () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: borderColor,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: disabled
                                      ? fadedTitleColor
                                      : (mutedTitle
                                          ? theme.textTheme.bodyMedium?.color
                                              ?.withValues(alpha: 0.75)
                                          : null),
                                  decoration: mutedTitle
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (statusChip != null) ...[
                              const SizedBox(width: 8),
                              statusChip!,
                            ],
                          ],
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: disabled
                                  ? fadedSubtitleColor
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    disabled
                        ? Icons.block
                        : (isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off),
                    size: 22,
                    color: disabled
                        ? theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.5)
                        : (isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small pill rendered next to a start-point title to indicate skipped/done.
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
