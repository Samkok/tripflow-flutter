import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:voyza/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_url_extractor/google_maps_url_extractor.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/paginated_search_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/collaborators_sheet.dart';
import 'package:voyza/widgets/sign_up_required_sheet.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';
import 'package:voyza/widgets/google_maps_url_dialog.dart';
import 'package:voyza/services/location_add_service.dart';
import 'package:voyza/services/onboarding_service.dart';
import 'package:voyza/services/subscription_limit_service.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/widgets/celebration_dialogs.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/auto_plan_sheet.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/providers/place_photo_refresh_provider.dart';
import 'package:voyza/services/place_photo_refresh_service.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/widgets/accommodation_prompts.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/search_text.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/widgets/trip_day_picker.dart';
import 'package:voyza/services/trip_dates_service.dart';
import 'package:voyza/services/itinerary_pdf_service.dart';
import 'package:voyza/services/trip_day_service.dart';
import 'package:voyza/services/trip_rollover_service.dart';
import 'package:voyza/widgets/static_glow.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

class TripDetailsScreen extends ConsumerStatefulWidget {
  final Trip trip;

  /// True only when pushed right after the user created their very first
  /// trip (see trip_screen._createTrip). Shows the one-time congrats modal
  /// on arrival — celebrating here, where the next action (adding places)
  /// lives, instead of on the screen being left behind.
  final bool celebrateFirstTrip;

  /// When set (notification tap: "X added a place"), the screen opens that
  /// location's detail sheet as soon as its data has loaded.
  final String? initialLocationId;

  const TripDetailsScreen({
    super.key,
    required this.trip,
    this.celebrateFirstTrip = false,
    this.initialLocationId,
  });

  @override
  ConsumerState<TripDetailsScreen> createState() => _TripDetailsScreenState();
}

class _TripDetailsScreenState extends ConsumerState<TripDetailsScreen> {
  /// widget.trip frozen at push time, overridden after in-screen changes to
  /// the trip's date range (the add-day tile) so the day slots refresh
  /// without reopening the screen.
  Trip? _tripOverride;
  Trip get _trip => _tripOverride ?? widget.trip;

  /// Itinerary PDF export: busy flag for the app-bar button, and its key so
  /// the share sheet can anchor to it on iPad.
  bool _exportingItinerary = false;
  final GlobalKey _exportButtonKey = GlobalKey();

  /// Builds the whole trip's itinerary (every day, where you stay, each
  /// place with its tag, planned time and hours) as a PDF and opens the
  /// share sheet. Always the full plan — a search filter on this page
  /// doesn't narrow it.
  Future<void> _exportItinerary() async {
    final all = ref.read(savedLocationsProvider).valueOrNull;
    if (all == null) {
      AppToast.info(context, 'Still loading your places — try again.');
      return;
    }
    final places = all.where((l) => l.tripId == widget.trip.id).toList();
    if (places.isEmpty) {
      AppToast.info(context, 'Add a few places first — then export the plan.');
      return;
    }
    final box =
        _exportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _exportingItinerary = true);
    try {
      await ItineraryPdfService.exportAndShare(
        trip: _trip,
        locations: places,
        shareOrigin: origin,
      );
    } catch (e) {
      debugPrint('_exportItinerary: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t create the itinerary — try again.');
      }
    } finally {
      if (mounted) setState(() => _exportingItinerary = false);
    }
  }

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  // Stream created once so rebuilds (e.g. typing in search) don't recreate it,
  // which would cause StreamBuilder to briefly flash ConnectionState.waiting.
  late final Stream<List<SavedLocation>> _locationsStream;

  final _addLocationFabKey = GlobalKey();

  // ─── Multi-select state ────────────────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
  List<SavedLocation> _currentTripLocations = [];

  /// Last count handed to the checklist from the stream builder — so a
  /// rebuild that changes nothing doesn't schedule another provider write.
  int? _lastReportedChecklistCount;

  /// Content equality for the cached trip list: same ids in the same order.
  /// The stream builder produces a NEW list object on every build, so an
  /// identity check (`!=`) was always true.
  static bool _sameLocationIds(List<SavedLocation> a, List<SavedLocation> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  // Per-location COLLAPSE state for the photo dropdown. Tracks the
  // ids of cards the user has explicitly collapsed; everything else is
  // expanded by default. (Previously this tracked expanded ids, so the
  // default was collapsed — flipping the polarity here is the whole
  // change needed to show photos out of the box.)
  final Set<String> _photoCollapsedIds = {};

  /// Per-day sort state for the header's sort toggle, keyed by the day's
  /// normalized midnight. Absent = the list's natural (drag) order;
  /// `true` = oldest added first; `false` = newest added first.
  /// Session-only view state, deliberately not persisted — like the photo
  /// collapse set — and it never writes to the locations themselves.
  final Map<DateTime, bool> _sortByAddedDays = {};

  /// Per-day fold state the user set by tapping a header (true = folded).
  /// Days without an entry use the default: folded when the day is already
  /// behind the traveller on an ONGOING trip, open otherwise (see
  /// [_buildDateSection]). Lives for this screen's lifetime only.
  final Map<DateTime, bool> _dayFoldOverrides = {};

  /// Ongoing-trip landing: the day list opens scrolled to today, once per
  /// screen life. The sliver builds lazily, so the scroll pages down until
  /// today's section exists, then aligns it just under the header.
  final GlobalKey _todayDayKey = GlobalKey();
  bool _didAutoScrollToToday = false;

  /// Today's header colour on the day list — a different hue from every
  /// other day, so the eye lands on "now" first.
  static const Color _todayGreen = Color(0xFF34C759);

  /// Collapse state of the Unscheduled-bucket section (session-scoped).
  bool _unscheduledCollapsed = false;

  void _enterSelectionMode(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete locations?'),
        content: Text(
            'Delete $count location${count == 1 ? '' : 's'}? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final repo = ref.read(locationRepositoryProvider);
    for (final id in _selectedIds.toList()) {
      await repo.deleteLocation(id);
    }
    _exitSelectionMode();
  }

  void _showLocationDetail(
    SavedLocation location,
    int indexInList,
    List<SavedLocation> dateGroup,
  ) {
    String coordAddress(SavedLocation l) =>
        '${l.lat.toStringAsFixed(5)}, ${l.lng.toStringAsFixed(5)}';

    final locationModel =
        location.toLocationModel(address: coordAddress(location));
    final dateGroupModels = dateGroup
        .map((l) => l.toLocationModel(address: coordAddress(l)))
        .toList();

    final scrollController = ScrollController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Keep a full-height sheet (photos + hours + multi-day on small
      // screens) from rendering its header under the status bar/notch.
      useSafeArea: true,
      builder: (ctx) => LocationDetailSheet(
        location: locationModel,
        number: indexInList + 1,
        parentScrollController: scrollController,
        locationsForDate: dateGroupModels,
        // Pass the viewed trip ID so the Multi-day stay section's
        // permission gate and write path target this trip rather than
        // whichever trip is currently active on the map.
        tripId: widget.trip.id,
      ),
    ).whenComplete(scrollController.dispose);
  }

  @override
  void initState() {
    super.initState();
    // Ongoing trip with "carry unvisited places forward" on: catch up now
    // (once per trip per day) so the page shows today's real plan.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(TripRolloverService.runIfDue(ref));
    });
    _locationsStream = ref.read(locationRepositoryProvider).watchLocations();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Checklist: the add-locations guide is pre-armed by the wizard (or a
      // checklist tap on home). Consume it once the FAB is laid out.
      if (ref.read(checklistGuideRequestProvider) ==
          ChecklistGuide.addLocations) {
        ref.read(checklistGuideRequestProvider.notifier).state = null;
        Future.delayed(const Duration(milliseconds: 450), () {
          if (!mounted) return;
          showChecklistCoach(
            context,
            targetKey: _addLocationFabKey,
            title: 'Add 2 places',
            body: 'Search for spots you want to visit — cafés, sights, your '
                'hotel. Add 2 and step 2 is done; the badge up top keeps '
                'count.',
            align: ContentAlign.top,
          );
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Invalidate permissions when screen is first created to ensure fresh data
      ref.invalidate(hasWriteAccessProvider(widget.trip.id));
      ref.invalidate(isTripOwnerProvider(widget.trip.id));
      ref.invalidate(userTripPermissionProvider(widget.trip.id));

      // Refresh location cache from Supabase so collaborators see each other's locations.
      // The local Hive box is only populated at login, so it may be stale if the user
      // was invited after they last logged in.
      //
      // DEFERRED past the push transition (~300 ms): the refresh can write
      // Hive rows, and each write re-emits the locations stream to every
      // watcher — doing that mid-animation was a visible stutter on the
      // home → details transition. Half a second of extra staleness is
      // imperceptible; a janked push animation is not.
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        ref.read(locationRepositoryProvider).fetchRemoteLocations();
      });

      // One-time "first trip" congrats. Double-gated: the caller only sets
      // the flag on a genuine first creation, and the per-user prefs flag
      // makes it impossible to repeat (e.g. delete-and-recreate).
      if (widget.celebrateFirstTrip) {
        _maybeCelebrateFirstTrip();
      }

      // Notification tap landing: open the added location's detail sheet
      // once its row is in (the remote refresh above may still be running).
      if (widget.initialLocationId != null) {
        _maybeOpenInitialLocation();
      }
    });
  }

  /// Waits (bounded) for [TripDetailsScreen.initialLocationId] to appear in
  /// this trip's locations, then opens its detail sheet — mirroring a tap on
  /// its card, including the same day-group so the multi-day section works.
  Future<void> _maybeOpenInitialLocation() async {
    final targetId = widget.initialLocationId;
    if (targetId == null) return;
    try {
      final all = await ref
          .read(locationRepositoryProvider)
          .watchLocations()
          .firstWhere((locs) =>
              locs.any((l) => l.id == targetId && l.tripId == widget.trip.id))
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      final tripLocations =
          all.where((l) => l.tripId == widget.trip.id).toList();
      final target = tripLocations.firstWhere((l) => l.id == targetId);
      final targetStart = target.scheduledDate;
      // Same day-cover rule as _buildLocationsList: the group holds every
      // location whose scheduled range covers the target's first day. An
      // unscheduled target groups with the other Unscheduled-bucket rows.
      final dateGroup = targetStart == null
          ? tripLocations.where((l) => l.scheduledDate == null).toList()
          : tripLocations.where((l) {
              final startRaw = l.scheduledDate;
              if (startRaw == null) return false;
              final day = _dayKey(targetStart);
              final s = _dayKey(startRaw);
              final e = _dayKey(l.scheduledEndDate ?? startRaw);
              return !day.isBefore(s) && !day.isAfter(e);
            }).toList();
      var index = dateGroup.indexWhere((l) => l.id == targetId);
      if (index < 0) index = 0;
      _showLocationDetail(target, index, dateGroup);
    } catch (_) {
      // Timed out or gone (deleted / access revoked) — the details page is
      // still the right landing; just don't pop a sheet.
    }
  }

  Future<void> _maybeCelebrateFirstTrip() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final service = OnboardingService.instance;
    if (await service.hasCelebrated(userId, OnboardingMilestone.firstTrip)) {
      return;
    }
    await service.markCelebrated(userId, OnboardingMilestone.firstTrip);
    if (mounted) {
      await showFirstTripCelebration(
        context,
        placesUsed: SubscriptionLimitService.ownPlaceCount(ref),
      );
    }
  }

  @override
  void dispose() {
    _stopDragAutoScroll();
    _listScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _setActiveTrip() async {
    try {
      ref.read(tripProvider.notifier).clearTrip();
      await ref
          .read(localActiveTripIdProvider.notifier)
          .setActiveTrip(widget.trip.id);
      // Checklist step 3 completes on ANY activation path, not only the home
      // card's button — guests activate here and the trips-list reconcile
      // only sees server-side `isActive`, so without this the step stayed
      // pending while the trip was plainly active. No guide chaining from
      // here: the "Go to map" spotlight lives on the home card.
      await ref
          .read(checklistProvider.notifier)
          .mark(ChecklistStep.activateTrip, silent: true);
      if (mounted) {
        AppToast.success(context, '${widget.trip.name} is now active');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Could not activate trip. Please try again.');
      }
    }
  }

  Future<void> _deactivateTrip() async {
    try {
      await ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
      if (mounted) {
        AppToast.info(context, 'Trip deactivated');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Could not deactivate trip. Please try again.');
      }
    }
  }

  Future<void> _refreshPermissions() async {
    // Invalidate permission providers to force re-fetch from database
    ref.invalidate(hasWriteAccessProvider(widget.trip.id));
    ref.invalidate(isTripOwnerProvider(widget.trip.id));
    ref.invalidate(userTripPermissionProvider(widget.trip.id));

    // Also invalidate location data to refresh the list
    ref.invalidate(locationRepositoryProvider);

    // Wait a bit for providers to refresh
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    // Initialize collaborator realtime listener (handles permission updates and removal)
    ref.watch(collaboratorRealtimeInitProvider);

    // Check if current user is the owner
    final isOwnerAsync = ref.watch(isTripOwnerProvider(widget.trip.id));
    final hasWriteAccessAsync =
        ref.watch(hasWriteAccessProvider(widget.trip.id));

    return Stack(
      children: [
        // Ambient rotating globe behind the page (see-through cards + a
        // transparent app bar let it show, matching the home screen).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: _selectionMode
              ? AppBar(
                  elevation: 0,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _exitSelectionMode,
                  ),
                  title: Text(
                    '${_selectedIds.length} selected',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  actions: [
                    // Tristate checkbox: null=some, true=all, false=none
                    Checkbox(
                      tristate: true,
                      value: _selectedIds.isEmpty
                          ? false
                          : _selectedIds.length == _currentTripLocations.length
                              ? true
                              : null,
                      onChanged: (_) {
                        setState(() {
                          if (_selectedIds.length ==
                              _currentTripLocations.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds
                                .addAll(_currentTripLocations.map((l) => l.id));
                          }
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: 'Delete selected',
                      onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                    ),
                  ],
                )
              : AppBar(
                  elevation: 0,
                  backgroundColor: Colors.transparent,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: Text(
                    widget.trip.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    // Export the whole itinerary as a PDF (every member can;
                    // it only reads the plan).
                    IconButton(
                      key: _exportButtonKey,
                      tooltip: 'Export itinerary (PDF)',
                      onPressed: _exportingItinerary ? null : _exportItinerary,
                      icon: _exportingItinerary
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : const Icon(Icons.picture_as_pdf_outlined),
                    ),
                    // Auto-plan: cluster → order cities → spread across
                    // days. Operates on the ACTIVE trip's state, so it only
                    // shows when THIS trip is the active one, with 2+
                    // places to arrange. Badge dot when the trip clearly
                    // needs it (bucket rows, or an overloaded day).
                    Consumer(builder: (context, ref, _) {
                      final activeId =
                          ref.watch(realtimeActiveTripProvider).valueOrNull?.id;
                      if (activeId != widget.trip.id) {
                        return const SizedBox.shrink();
                      }
                      final placeCount = ref.watch(
                          tripProvider.select((s) => s.pinnedLocations.length));
                      if (placeCount < 2) return const SizedBox.shrink();
                      final unscheduled = ref.watch(unscheduledCountProvider);
                      final overloaded = ref.watch(tripProvider.select((s) {
                        final perDay = <DateTime, int>{};
                        for (final l in s.pinnedLocations) {
                          final d = l.scheduledDate;
                          if (d == null) continue;
                          final k = DateTime(d.year, d.month, d.day);
                          perDay[k] = (perDay[k] ?? 0) + 1;
                        }
                        return perDay.values
                            .any((c) => c > 12); // clearly too many
                      }));
                      final needsAttention = unscheduled > 0 || overloaded;
                      return IconButton(
                        tooltip: 'Auto-plan my days',
                        onPressed: () => showAutoPlanSheet(context),
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Icon(Icons.auto_awesome_rounded),
                            if (needsAttention)
                              Positioned(
                                right: -2,
                                top: -2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFFB300),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    // Team members button - only visible to trip owner.
                    // Guests see it too (they own their local trips), but
                    // tapping it prompts sign-up: collaboration needs an
                    // account, and hiding the button would keep guests from
                    // ever learning the feature exists.
                    isOwnerAsync.when(
                      data: (isOwner) => isOwner
                          ? IconButton(
                              icon: const Icon(Icons.group_outlined),
                              tooltip: 'Travel buddies',
                              onPressed: () {
                                if (ref.read(currentUserIdProvider) == null) {
                                  showSignUpRequiredSheet(
                                    context,
                                    icon: Icons.group_add_rounded,
                                    title: 'Sign up to invite travel buddies',
                                    message: 'Trip collaboration needs a free '
                                        'account — your buddies get live '
                                        'access, and every change syncs to '
                                        'everyone instantly. This trip stays '
                                        'on your device and comes with you '
                                        'when you sign up.',
                                  );
                                  return;
                                }
                                _showCollaboratorsSheet();
                              },
                            )
                          : const SizedBox.shrink(),
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                  ],
                ),
          bottomNavigationBar: _selectionMode
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: FilledButton.icon(
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                          'Delete ${_selectedIds.length} location${_selectedIds.length == 1 ? '' : 's'}'),
                    ),
                  ),
                )
              : null,
          body: RefreshIndicator(
            onRefresh: _refreshPermissions,
            child: Column(
              children: [
                // Search bar
                _buildSearchBar(),
                // Locations list. Pass write-access down so drag-to-move handles
                // and drop targets are only enabled for users who can edit.
                Expanded(
                  child: _buildLocationStreamBody(
                    hasWriteAccess:
                        hasWriteAccessAsync.whenOrNull(data: (v) => v) ?? false,
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: _selectionMode
              ? null
              : hasWriteAccessAsync.when(
                  data: (hasWriteAccess) => hasWriteAccess
                      // Single glowing Add Location FAB — the old secondary
                      // "Add Existing" entry confused more than it helped.
                      ? StaticGlow(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.circular(16),
                          glowColor: Theme.of(context).colorScheme.primary,
                          child: FloatingActionButton.extended(
                            key: _addLocationFabKey,
                            heroTag: 'fab_add_location',
                            onPressed: () => _showAddLocationDialog(),
                            icon: const Icon(Icons.add_location_alt_outlined),
                            label: const Text('Add Location'),
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            foregroundColor: Colors.black,
                          ),
                        )
                      : null,
                  loading: () => null,
                  error: (_, __) => null,
                ),
        ),
        // Floating step-2 progress badge (checklist): visible only while
        // "add places" is the active goal — the checklist lives on home,
        // so this is the on-screen definition of done.
        Positioned(
          top: MediaQuery.of(context).padding.top + kToolbarHeight + 6,
          left: 0,
          right: 0,
          child: Center(
            child: AddLocationsProgressBadge(
                count: ref.watch(checklistProvider).locCount),
          ),
        ),
      ],
    );
  }

  void _showCollaboratorsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Light barrier so the page stays visible behind the glass sheet.
      barrierColor: AppTheme.sheetBarrierColor(context),
      builder: (context) => CollaboratorsSheet(
        tripId: widget.trip.id,
        tripName: widget.trip.name,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        cursorOpacityAnimates: false,
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search locations...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).dividerColor,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          filled: true,
          fillColor: Theme.of(context).cardColor,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
        onChanged: (value) {
          setState(() => _searchQuery = value.toLowerCase());
        },
      ),
    );
  }

  Widget _buildLocationStreamBody({required bool hasWriteAccess}) {
    return StreamBuilder<List<SavedLocation>>(
      stream: _locationsStream,
      initialData: const [],
      builder: (context, snapshot) {
        debugPrint(
            'Trip details - Stream state: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, data length: ${snapshot.data?.length ?? 0}');

        // Handle connection states
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        // Handle errors
        if (snapshot.hasError) {
          debugPrint('Stream error: ${snapshot.error}');
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error loading locations: ${snapshot.error}'),
            ),
          );
        }

        // Get data safely
        final allLocations = snapshot.data ?? const [];

        // Filter by trip ID
        var tripLocations =
            allLocations.where((loc) => loc.tripId == widget.trip.id).toList();

        // Checklist step 2 progress: report this trip's live count (marks
        // the step at 3). Post-frame — never mutate providers during build —
        // and only when the count actually changed.
        final checklistCount = tripLocations.length;
        if (checklistCount != _lastReportedChecklistCount) {
          _lastReportedChecklistCount = checklistCount;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref
                  .read(checklistProvider.notifier)
                  .reportTripLocationCount(checklistCount);
            }
          });
        }

        // Apply search filter if query is not empty
        if (_searchQuery.isNotEmpty) {
          tripLocations = tripLocations
              .where((loc) => matchesSearchQuery(loc.name, _searchQuery))
              .toList();
          // A search with no hits keeps the plain empty state — day slots
          // full of empty groups would read as "no results" badly.
          if (tripLocations.isEmpty) return _buildEmptyState(false);
        }

        debugPrint('Trip details - Trip ID: ${widget.trip.id}');
        debugPrint(
            'Trip details - Filtered locations: ${tripLocations.length}');

        // NO empty-list early return here: a trip with a date range but no
        // locations yet must still render its per-day slots (with the
        // per-date add affordances). _buildLocationsList falls back to the
        // empty state itself when the trip has no dates either.

        // Keep a reference so the selection-mode AppBar can select all.
        // Compare by CONTENT: `tripLocations` is a fresh list every build,
        // so the old identity check was always true and its post-frame
        // setState re-ran this build on every frame — the whole screen
        // rendered at ~48 fps / 62 % CPU while idle (measured). The field
        // is updated in place for the body; the post-frame setState exists
        // only to refresh the AppBar's select-all state on a real change.
        if (!_sameLocationIds(_currentTripLocations, tripLocations)) {
          _currentTripLocations = tripLocations;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }

        return _buildLocationsList(tripLocations,
            hasWriteAccess: hasWriteAccess);
      },
    );
  }

  /// Normalizes a [DateTime] to midnight local time so two timestamps from
  /// the same calendar day compare equal.
  DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// True when [day] is a calendar day strictly before today. Drives the
  /// past tense of folded day summaries only — places CAN be added to past
  /// days (logging where you actually went), so this no longer gates the
  /// add affordances.
  bool _isPastDay(DateTime day) =>
      _dayKey(day).isBefore(_dayKey(DateTime.now()));

  /// Day labels for this trip: "Day N" while it has no dates yet.
  DayLabeler get _labeler => DayLabeler.forTrip(_trip);

  /// True once the trip's last day has passed. An ended trip keeps its
  /// dates: no rescheduling, no adding or removing days — but places can
  /// still be added to the days it had.
  bool get _tripEnded {
    final last = _trip.endDate ?? _trip.startDate;
    return last != null && _dayKey(last).isBefore(_dayKey(DateTime.now()));
  }

  /// "No Date" on a dated trip (owner): the dates come off, the days stay
  /// as Day 1 … N with every place in place.
  Future<void> _clearTripDates() async {
    final trip = _trip;
    final start = trip.startDate;
    final end = trip.endDate ?? start;
    final days = start == null || end == null
        ? null
        : daySpanDays(dayKey(start), dayKey(end)) + 1;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Switch to No Date?'),
        content: Text(
          'The dates come off "${trip.name}". '
          '${days == null ? 'Its days' : 'Its $days ${days == 1 ? 'day stays' : 'days stay'}'} '
          'as Day 1${days == null || days == 1 ? '' : ' – Day $days'} with '
          'every place where it is, and you can set new dates any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    try {
      final updated = await TripDatesService.clearDates(ref, trip);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      AppToast.success(context, '"${trip.name}" has no dates now');
    } catch (e) {
      debugPrint('_clearTripDates: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t remove the dates — try again.');
      }
    }
  }

  /// "Set dates" on a trip planned without them (owner): Day 1 lands on
  /// the picked day and every place keeps its day number.
  Future<void> _setTripDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      helpText: 'First day of the trip',
    );
    if (picked == null || !mounted) return;
    try {
      final updated = await TripDatesService.setStartDate(ref, _trip, picked);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      final fmt = DateFormat('MMM d');
      AppToast.success(
          context,
          'Dates set — ${fmt.format(updated.startDate!)} to '
          '${fmt.format(updated.endDate!)}');
    } catch (e) {
      debugPrint('_setTripDates: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t set the dates — try again.');
      }
    }
  }

  bool _busyRollover = false;

  /// Owner toggle for "carry unvisited places forward". Persists on the
  /// trip, then — when switched ON — runs the carry-over immediately so the
  /// effect is visible right away instead of at the next launch.
  Future<void> _setAutoRoll(bool enabled) async {
    if (_busyRollover) return;
    setState(() => _busyRollover = true);
    try {
      final updated = await ref
          .read(tripRepositoryProvider)
          .updateTrip(_trip.id, autoRollUnvisited: enabled);
      ref.invalidate(userTripsProvider);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      if (enabled) {
        final notice = await TripRolloverService.rollNow(ref, updated);
        if (!mounted) return;
        AppToast.success(
          context,
          notice == null
              ? 'On — unvisited places will move to the current day.'
              : notice.message,
          duration: notice == null ? null : const Duration(seconds: 5),
        );
      } else {
        AppToast.info(context, 'Off — places stay on their planned day.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Couldn\'t update this setting. $e');
      }
    } finally {
      if (mounted) setState(() => _busyRollover = false);
    }
  }

  /// Ongoing trip: open on today. Runs once per screen life, after the
  /// first frame that laid the day list out.
  void _scheduleAutoScrollToToday() {
    if (_didAutoScrollToToday) return;
    _didAutoScrollToToday = true;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoScrollToToday(attempt: 0));
  }

  /// The day list is a lazy sliver: today's section doesn't exist until it
  /// is near the viewport, so `ensureVisible` alone can't reach it. Page
  /// the list down until the keyed section is built, then align it just
  /// under the header. Bounded so a missing key can never loop forever.
  void _autoScrollToToday({required int attempt}) {
    if (!mounted || !_listScrollController.hasClients) return;
    final ctx = _todayDayKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.02,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final pos = _listScrollController.position;
    if (attempt >= 40 || pos.pixels >= pos.maxScrollExtent - 1) return;
    _listScrollController.jumpTo(math.min(
        pos.pixels + pos.viewportDimension * 0.9, pos.maxScrollExtent));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoScrollToToday(attempt: attempt + 1));
  }

  /// Builds the full, gap-free list of dates to display: the contiguous span
  /// from the earliest to the latest date the trip touches — the trip's
  /// declared start..end range unioned with every scheduled location — with
  /// every in-between day filled in. That guarantees an empty interstitial
  /// day (e.g. Jan 2 between stops on Jan 1 and Jan 3) still gets a drop
  /// slot, even when the trip has no explicit date range. Sorted
  /// chronologically. See [contiguousTripDates] — the same helper drives the
  /// trip-plan bottom sheet so both surfaces show identical days.
  List<DateTime> _buildAllDates(List<SavedLocation> locations) {
    return contiguousTripDates([
      _trip.startDate,
      _trip.endDate,
      // Unscheduled rows (null dates) don't stretch the axis — they render
      // in the Unscheduled section, not on a day. Nulls are skipped.
      for (final loc in locations) ...[
        loc.scheduledDate,
        loc.scheduledEndDate,
      ],
    ]);
  }

  Widget _buildLocationsList(
    List<SavedLocation> locations, {
    required bool hasWriteAccess,
  }) {
    // Group locations by every day they cover. Multi-day stays show up on
    // each day in their `[scheduledDate..scheduledEndDate]` range — same
    // SavedLocation instance reused across day groups so edits/drag still
    // work via id.
    final groupedByDay = <DateTime, List<SavedLocation>>{};
    final unscheduled = <SavedLocation>[];
    for (final location in locations) {
      final startRaw = location.scheduledDate;
      if (startRaw == null) {
        // No date = the trip's Unscheduled bucket, rendered as its own
        // section above the day list.
        unscheduled.add(location);
        continue;
      }
      final start = _dayKey(startRaw);
      final endRaw = location.scheduledEndDate ?? startRaw;
      final end = _dayKey(endRaw);
      // Step by calendar day (not Duration(days:1)) so keys stay on local
      // midnight across DST transitions and match _buildAllDates' slots.
      for (var d = start;
          !d.isAfter(end);
          d = DateTime(d.year, d.month, d.day + 1)) {
        groupedByDay.putIfAbsent(d, () => []).add(location);
      }
    }

    final allDates = _buildAllDates(locations);

    // Ongoing trip = it has started and today is on or before its last day.
    // Only then does every day except today fold up (the page opens on
    // "now", with the rest a tap away); on a finished trip EVERY day is
    // past, and folding them all would hide the whole memory of the trip.
    final today = _dayKey(DateTime.now());
    final tripOngoing = allDates.isNotEmpty &&
        allDates.first.isBefore(today) &&
        !allDates.last.isBefore(today);
    if (tripOngoing && _searchQuery.isEmpty) _scheduleAutoScrollToToday();

    // If the trip has no date range AND no locations anywhere (days or the
    // Unscheduled bucket), fall back to the standard empty state below the
    // trip info card.
    if (allDates.isEmpty && unscheduled.isEmpty) {
      return Column(
        children: [
          _buildTripInfoSection(),
          Expanded(child: _buildEmptyState(false)),
        ],
      );
    }

    return CustomScrollView(
      key: _listViewportKey,
      controller: _listScrollController,
      slivers: [
        // Endorsement: how many people copied this trip — social proof for
        // the OWNER only, and only once it's non-zero (a "0 travelers"
        // badge would read as the opposite of an endorsement). Guests'
        // local trips can never be copied, so the count gate covers them.
        SliverToBoxAdapter(child: _buildCopyEndorsement()),
        SliverToBoxAdapter(
          child: _buildTripInfoSection(),
        ),
        // Places that belong to the trip but sit on NO day. Rendered above
        // the day list so leftovers are impossible to miss; each card can
        // be dragged onto any day below (or scheduled via its own sheet).
        if (unscheduled.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildUnscheduledSection(
              unscheduled,
              hasWriteAccess: hasWriteAccess,
            ),
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index == allDates.length) {
                return _buildAddDayTile(allDates);
              }
              final day = allDates[index];
              final dateGroup = groupedByDay[day] ?? const <SavedLocation>[];
              final section = _buildDateSection(
                day,
                dateGroup,
                hasWriteAccess: hasWriteAccess,
                tripOngoing: tripOngoing,
              );
              // Keyed so the ongoing-trip landing can scroll to it.
              return day == today
                  ? KeyedSubtree(key: _todayDayKey, child: section)
                  : section;
            },
            childCount: allDates.length +
                ((hasWriteAccess && _searchQuery.isEmpty && !_tripEnded)
                    ? 1
                    : 0),
          ),
        ),
        // Bottom padding sized to clear the two stacked extended FABs
        // (~56pt each + 12pt gap + 16pt scaffold margin + SafeArea bottom).
        // Without this the last expanded photo card disappears behind the
        // floating buttons.
        const SliverPadding(padding: EdgeInsets.only(bottom: 200)),
      ],
    );
  }

  Widget _buildEmptyState(bool isLoading) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!isLoading)
            Icon(
              Icons.location_off_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
            ),
          const SizedBox(height: 16),
          Text(
            'No locations added yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start adding locations to this trip',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.6),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyEndorsement() {
    final theme = Theme.of(context);
    final count = widget.trip.copyCount;
    final isOwner =
        ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
    if (!isOwner || count <= 0) return const SizedBox.shrink();

    const gold = Color(0xFFF5A623);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: [
              gold.withValues(alpha: 0.16),
              gold.withValues(alpha: 0.05),
            ],
          ),
          border: Border.all(color: gold.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            const Icon(Icons.favorite_rounded, color: gold, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$count traveler${count == 1 ? '' : 's'} ',
                      style: const TextStyle(
                          color: gold, fontWeight: FontWeight.w800),
                    ),
                    TextSpan(
                      text: 'loved this trip and made it their own',
                    ),
                  ],
                ),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            const Icon(Icons.auto_awesome_rounded, color: gold, size: 16),
          ],
        ),
      ),
    );
  }

  /// Publish / unpublish from the trip page. Confirms first (publishing is
  /// privacy-affecting; unpublishing revokes every code holder). The server
  /// mints the code on first publish and keeps it across re-publishes.
  Future<void> _setTripPublished(bool goPublic) async {
    final trip = _trip;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(goPublic ? 'Make this trip public?' : 'Make it private?'),
        content: Text(
          goPublic
              ? 'You\'ll get a share code. Anyone with it can copy '
                  '"${trip.name}" as their own trip — they never see your '
                  'name, your edits, or your progress, and you can turn '
                  'this off any time.'
              : 'People who have your code will no longer be able to copy '
                  'this trip. Making it public again restores the same code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(goPublic ? 'Publish' : 'Go private'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final code = await ref
          .read(tripRepositoryProvider)
          .setTripPublic(trip.id, goPublic);
      ref.invalidate(userTripsProvider);
      if (!mounted) return;
      setState(() {
        _tripOverride = trip.copyWith(
          isPublic: goPublic,
          shareCode: goPublic ? (code ?? trip.shareCode) : trip.shareCode,
        );
      });
      AppToast.success(
          context,
          goPublic
              ? 'Trip published — tap the code to copy it'
              : 'Trip is private again');
    } catch (e) {
      debugPrint('setTripPublic failed: $e');
      if (mounted) {
        AppToast.error(
            context, 'Could not update sharing. Check your connection.');
      }
    }
  }

  Widget _buildTripInfoSection() {
    final localActiveTripId = ref.watch(localActiveTripIdProvider);
    final isActive = localActiveTripId == widget.trip.id;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.trip_origin_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.trip.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // Activate / Deactivate button
                FilledButton.tonal(
                  onPressed: isActive ? _deactivateTrip : _setActiveTrip,
                  style: FilledButton.styleFrom(
                    backgroundColor: isActive
                        ? Colors.green.withValues(alpha: 0.15)
                        : Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                    foregroundColor: isActive
                        ? Colors.green
                        : Theme.of(context).colorScheme.primary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isActive) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        isActive ? 'Active' : 'Activate',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_trip.startDate != null && _trip.endDate != null) ...[
              const SizedBox(height: 10),
              Consumer(builder: (context, ref, _) {
                final s = dayKey(_trip.startDate!);
                final e = dayKey(_trip.endDate!);
                final dayCount = daySpanDays(s, e) + 1;
                final undated = _trip.isUndated;
                final dateText = undated
                    ? 'No dates yet'
                    : s == e
                        ? DateFormat('MMM d, y').format(s)
                        : '${DateFormat('MMM d').format(s)} - ${DateFormat('MMM d, y').format(e)}';
                final isOwner = ref
                        .watch(isTripOwnerProvider(widget.trip.id))
                        .valueOrNull ??
                    false;
                return Row(
                  children: [
                    Icon(
                      undated
                          ? Icons.event_note_rounded
                          : Icons.calendar_today_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$dateText  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Owner: give an undated trip dates (Day 1 lands on the
                    // picked day), or take a dated trip's dates off (its
                    // days stay as Day 1 … N). An ended trip keeps its
                    // dates.
                    if (isOwner && undated)
                      TextButton.icon(
                        onPressed: _setTripDates,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon:
                            const Icon(Icons.event_available_rounded, size: 16),
                        label: const Text('Set dates'),
                      )
                    else if (isOwner && !_tripEnded)
                      TextButton.icon(
                        onPressed: _clearTripDates,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.event_busy_rounded, size: 16),
                        label: const Text('No Date'),
                      ),
                  ],
                );
              }),
            ],
            // ── Carry unvisited places forward (owner, dated trips only) ──
            if (_trip.startDate != null &&
                _trip.endDate != null &&
                !_trip.isUndated)
              Consumer(builder: (context, ref, _) {
                final isOwner = ref
                        .watch(isTripOwnerProvider(widget.trip.id))
                        .valueOrNull ??
                    false;
                if (!isOwner) return const SizedBox.shrink();
                final theme = Theme.of(context);
                final on = _trip.autoRollUnvisited;
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.update_rounded,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Carry unvisited places forward',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Each new day, places you didn\'t visit move '
                              'to today. A place already planned that day '
                              'stays where it is.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: on,
                        onChanged: _busyRollover ? null : _setAutoRoll,
                      ),
                    ],
                  ),
                );
              }),
            // ── Sharing: publish for copy-by-code; the code (tap to copy)
            // once public. Owner-only and signed-in (the RPC enforces both).
            Consumer(builder: (context, ref, _) {
              final signedIn = ref.watch(currentUserIdProvider) != null;
              final isOwner =
                  ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ??
                      false;
              if (!signedIn || !isOwner) return const SizedBox.shrink();
              final theme = Theme.of(context);
              final primary = theme.colorScheme.primary;
              final trip = _trip;
              final hasCode = trip.isPublic && trip.shareCode != null;
              if (!hasCode) {
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Publish to get a share code others can copy '
                          'this trip with.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.3),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _setTripPublished(true),
                        icon: const Icon(Icons.public_rounded, size: 16),
                        label: const Text('Publish'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primary,
                          side:
                              BorderSide(color: primary.withValues(alpha: 0.5)),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          textStyle: theme.textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                );
              }
              final display = 'TRIP-${trip.shareCode}';
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: display));
                          AppToast.success(
                              context, 'Code copied — send it to anyone!');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                                color: primary.withValues(alpha: 0.45)),
                            color: primary.withValues(alpha: 0.08),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.public_rounded,
                                  size: 16, color: primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  display,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.4,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Icon(Icons.copy_rounded,
                                  size: 16, color: primary),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _setTripPublished(false),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Go private'),
                    ),
                  ],
                ),
              );
            }),
            if (widget.trip.description != null &&
                widget.trip.description!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                widget.trip.description!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.7),
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Framed, transparent "add a day" box after the last date: extends the
  /// trip's range by one day (start pinned to the current first day so
  /// location-derived ranges become explicit).
  Widget _buildAddDayTile(List<DateTime> allDates) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final last = allDates.last;
    final newDay = DateTime(last.year, last.month, last.day + 1);
    final canRemove = allDates.length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          if (canRemove) ...[
            // Remove the last day (framed, transparent — quiet next to Add).
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _removeLastTripDay(allDates),
                child: Container(
                  height: 54,
                  width: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.45),
                        width: 1.4),
                  ),
                  child: Icon(Icons.remove_rounded,
                      size: 22, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _addTripDayAtEnd(allDates),
                child: Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: primary.withValues(alpha: 0.5), width: 1.4),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 20, color: primary),
                      const SizedBox(width: 8),
                      Text(
                        _labeler.tbd
                            ? 'Add ${_labeler(newDay)}'
                            : 'Add a day (${DateFormat('MMM d').format(newDay)})',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeLastTripDay(List<DateTime> allDates) async {
    final range = await TripDayService.removeLastDay(
      context,
      ref,
      trip: _trip,
      days: allDates,
    );
    if (range != null && mounted) {
      setState(() {
        _tripOverride =
            _trip.copyWith(startDate: range.start, endDate: range.end);
      });
    }
  }

  Future<void> _addTripDayAtEnd(List<DateTime> allDates) async {
    final range = await TripDayService.addDayAtEnd(
      context,
      ref,
      trip: _trip,
      days: allDates,
    );
    if (range != null && mounted) {
      setState(() {
        _tripOverride =
            _trip.copyWith(startDate: range.start, endDate: range.end);
      });
    }
  }

  /// The trip's Unscheduled bucket: places that belong to the trip but sit
  /// on no day. Mirrors [_buildDateSection]'s visual language (chip header,
  /// drop-target highlight, same cards) with an amber identity so it can't
  /// be mistaken for a day. The whole section is a [DragTarget]: dropping a
  /// dated card here clears its date (guarded — accommodations, completed
  /// places, and multi-day stays keep their days).
  Widget _buildUnscheduledSection(
    List<SavedLocation> unscheduled, {
    required bool hasWriteAccess,
  }) {
    final theme = Theme.of(context);
    const amber = Color(0xFFFFB300);

    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      child: DragTarget<SavedLocation>(
        onWillAcceptWithDetails: (details) {
          if (!hasWriteAccess) return false;
          final loc = details.data;
          // Only dated, movable rows can be un-dated by dropping here.
          return loc.scheduledDate != null &&
              !loc.isAccommodation &&
              !loc.isDone &&
              !loc.isMultiDay;
        },
        onAcceptWithDetails: (details) =>
            _moveLocationToUnscheduled(details.data),
        builder: (context, candidate, rejected) {
          final highlighted = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: highlighted
                  ? amber.withValues(alpha: 0.14)
                  : amber.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted ? amber : amber.withValues(alpha: 0.35),
                width: highlighted ? 2 : 1.2,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color: amber.withValues(alpha: 0.35),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: amber.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.inventory_2_outlined,
                                size: 15, color: amber),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Unscheduled',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: amber,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${unscheduled.length}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: amber.withValues(alpha: 0.8),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The "I insist" path: put EVERY unscheduled place
                        // on one chosen day, no planner involved. Same-day
                        // duplicates of that day's occupants are skipped and
                        // reported, never silently dropped.
                        if (hasWriteAccess)
                          IconButton(
                            onPressed: () =>
                                _scheduleAllUnscheduled(unscheduled),
                            icon: const Icon(Icons.event_available_rounded,
                                color: amber),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: 'Put all on one day',
                          ),
                        // One-tap fix for the whole bucket — Auto-plan
                        // spreads these onto days. Active trip only (the
                        // planner works on active-trip state).
                        Consumer(builder: (context, ref, _) {
                          final activeId = ref
                              .watch(realtimeActiveTripProvider)
                              .valueOrNull
                              ?.id;
                          if (activeId != widget.trip.id || !hasWriteAccess) {
                            return const SizedBox.shrink();
                          }
                          return TextButton.icon(
                            onPressed: () => showAutoPlanSheet(context),
                            icon: const Icon(Icons.auto_awesome_rounded,
                                size: 15),
                            label: const Text('Plan'),
                            style: TextButton.styleFrom(
                              foregroundColor: amber,
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          );
                        }),
                        IconButton(
                          onPressed: () => setState(() =>
                              _unscheduledCollapsed = !_unscheduledCollapsed),
                          icon: Icon(
                            _unscheduledCollapsed
                                ? Icons.expand_more_rounded
                                : Icons.expand_less_rounded,
                            color: amber,
                          ),
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 40, minHeight: 32),
                          tooltip: _unscheduledCollapsed ? 'Show' : 'Hide',
                        ),
                      ],
                    ),
                  ],
                ),
                if (!_unscheduledCollapsed) ...[
                  const SizedBox(height: 4),
                  Text(
                    'On no day yet — drag each onto a day below, open a '
                    'card to schedule it, or use the buttons above to put '
                    'them all on one day or let Auto-plan spread them.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: unscheduled.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) => _buildLocationCard(
                      unscheduled[index],
                      index,
                      unscheduled,
                      hasWriteAccess: hasWriteAccess,
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

  /// Bulk "put all on one day": the user picks a day and every unscheduled
  /// place lands on it — however many that is (their call; the optimizer's
  /// over-cap dialog will speak up later if it's too many to route). Runs
  /// the shared same-day duplicate guard once for the whole batch and
  /// writes through the batch path (one Hive commit, one upsert).
  Future<void> _scheduleAllUnscheduled(List<SavedLocation> rows) async {
    if (rows.isEmpty) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final all =
        ref.read(savedLocationsProvider).valueOrNull ?? const <SavedLocation>[];
    final tripRows = all.where((l) => l.tripId == widget.trip.id);
    final highlighted = {
      for (final l in tripRows)
        if (l.scheduledDate != null) _dayKey(l.scheduledDate!)
    };
    final DateTime? picked;
    if (_labeler.tbd) {
      picked = await showTripDayPicker(
        context,
        days: _buildAllDates(tripRows.toList()),
        labeler: _labeler,
        marked: highlighted,
        title: 'Schedule on which day?',
      );
    } else {
      // Past days of the trip are pickable too (logging where you went).
      final tripStart = _trip.startDate;
      final earliest = tripStart != null && tripStart.isBefore(today)
          ? _dayKey(tripStart)
          : today;
      picked = await DatePickerUtils.showCustomDatePicker(
        context: context,
        initialDate:
            tripStart != null && !tripStart.isBefore(today) ? tripStart : today,
        firstDate: earliest,
        lastDate: DateTime(now.year + 5),
        highlightedDates: highlighted,
      );
    }
    if (picked == null || !mounted) return;
    final day = _dayKey(picked);

    final dup = filterSameDayDuplicates(
      moving: rows.map(placeKeyOfSaved),
      occupantsOnDay: tripRows
          .where((l) =>
              l.scheduledDate != null &&
              !rows.any((r) => r.id == l.id) &&
              l.isActiveOnDate(day))
          .map(placeKeyOfSaved),
    );
    final allowed = rows.where((r) => dup.allowedIds.contains(r.id)).toList();
    if (allowed.isEmpty) {
      AppToast.warning(
          context, 'All of these are already on ${_labeler(day)}.');
      return;
    }
    try {
      await ref.read(locationRepositoryProvider).updateLocationsBatch({
        for (final r in allowed)
          r.id: {
            'scheduled_date': day.toIso8601String(),
            'scheduled_end_date': null,
          },
      });
      if (!mounted) return;
      final skipped = rows.length - allowed.length;
      AppToast.success(
        context,
        '${allowed.length} ${allowed.length == 1 ? 'place' : 'places'} '
        'scheduled on ${_labeler(day)}'
        '${skipped > 0 ? ' · $skipped already there, skipped' : ''}.',
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('scheduleAllUnscheduled failed: $e');
      if (!mounted) return;
      AppToast.error(context, "Couldn't schedule them. Try again.");
    }
  }

  /// Clears [location]'s date — it moves to the Unscheduled bucket but
  /// stays in the trip. Repository-direct like [_moveLocationToDate] so it
  /// works on any writable trip, active or not; RLS backstops auth.
  Future<void> _moveLocationToUnscheduled(SavedLocation location) async {
    if (location.isAccommodation) {
      AppToast.warning(context, 'Accommodations need a date.');
      return;
    }
    if (location.isDone || location.isMultiDay) {
      AppToast.info(context, 'Completed places and stays keep their days.');
      return;
    }
    try {
      await ref.read(locationRepositoryProvider).updateLocation(
        location.id,
        {'scheduled_date': null},
      );
      if (!mounted) return;
      AppToast.info(context, '"${location.name}" moved to Unscheduled.');
    } catch (e) {
      debugPrint('moveLocationToUnscheduled failed: $e');
      if (!mounted) return;
      AppToast.error(context, "Couldn't move \"${location.name}\".");
    }
  }

  Widget _buildDateSection(
    DateTime day,
    List<SavedLocation> locations, {
    required bool hasWriteAccess,
    bool tripOngoing = false,
  }) {
    final labeler = _labeler;
    final dateLabel =
        labeler.tbd ? labeler(day) : DateFormat('MMMM dd, yyyy').format(day);
    final theme = Theme.of(context);
    // Adding is allowed on any day, past ones included — the folded
    // summary just switches to the past tense.
    final canAddHere = hasWriteAccess;

    // Every day folds from its header (chevron on the date chip). On an
    // ONGOING trip every day but today starts folded, so the page opens on
    // the day being lived; on any other trip every day starts open. A
    // search shows everything — a hit inside a folded day would otherwise
    // look like a miss.
    final isPast = _isPastDay(day);
    final isToday = labeler.isToday(day);
    final foldable = _searchQuery.isEmpty;
    final foldedByDefault = tripOngoing && !isToday;
    // Today's header is green; every other day keeps the primary tint.
    final accent = isToday ? _todayGreen : theme.colorScheme.primary;
    final folded = foldable && (_dayFoldOverrides[day] ?? foldedByDefault);
    void toggleFold() => setState(() => _dayFoldOverrides[day] = !folded);

    // Header sort toggle. null = natural order; true = oldest added first;
    // false = newest added first. Sorts on createdAt — the exact value the
    // card prints as "Added …", so the order is verifiable on screen.
    // View-only: nothing is written, and the natural order comes back.
    final bool? sortAscending = _sortByAddedDays[day];
    final displayLocations = sortAscending == null
        ? locations
        : (List<SavedLocation>.from(locations)
          ..sort((a, b) => sortAscending
              ? a.createdAt.compareTo(b.createdAt)
              : b.createdAt.compareTo(a.createdAt)));

    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      // DragTarget around the whole day so users can drop on either the
      // header or anywhere inside the section (including the empty
      // placeholder for a day with no locations yet).
      child: DragTarget<SavedLocation>(
        onWillAcceptWithDetails: (details) {
          if (!hasWriteAccess) return false;
          // Reject re-drops onto the same day to keep highlight feedback
          // honest and avoid a no-op write. A row dragged out of the
          // Unscheduled bucket (null date) is welcome on ANY day.
          final src = details.data.scheduledDate;
          if (src == null) return true;
          return _dayKey(src) != day;
        },
        onAcceptWithDetails: (details) =>
            _moveLocationToDate(details.data, day),
        builder: (context, candidate, rejected) {
          final highlighted = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              // Unmistakable drop target: at 6% the fill was easy to miss
              // while the eye was following the dragged card.
              color: highlighted
                  ? theme.colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.35),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  // spaceBetween + a grouped icon Row instead of a Spacer.
                  // A Spacer is Expanded(flex:1), so it COMPETED with the
                  // Flexible chip for free space and capped the chip at
                  // roughly half the header — truncating "October 05, 2026"
                  // to "October 05, …" with the right half sitting empty.
                  // Now the chip may use everything the icons don't.
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Flexible + ellipsis so a long date label at large
                    // accessibility text scales truncates instead of
                    // overflowing the header Row.
                    Flexible(
                      child: InkWell(
                        // Foldable days toggle from the date chip (and from
                        // the folded summary row below).
                        onTap: foldable ? toggleFold : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color:
                                accent.withValues(alpha: isToday ? 0.22 : 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: isToday
                                ? Border.all(
                                    color: accent.withValues(alpha: 0.6),
                                    width: 1.2)
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (foldable) ...[
                                Icon(
                                  folded
                                      ? Icons.chevron_right_rounded
                                      : Icons.expand_more_rounded,
                                  size: 18,
                                  color: accent,
                                ),
                                const SizedBox(width: 2),
                              ],
                              Flexible(
                                child: Text(
                                  dateLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: accent,
                                    fontWeight: isToday
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (isToday) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: _todayGreen,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'Today',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ],
                              if (locations.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '${locations.length}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: accent.withValues(alpha: 0.8),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Grouped so the free space lands BETWEEN the chip and
                    // the buttons, never between the buttons themselves.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Sort this day's cards by when they were ADDED.
                        // Three states, cycled by tapping: off (the natural
                        // order, which is also the drag order) → oldest
                        // first (arrow up) → newest first (arrow down).
                        // The arrow always points the way the dates run.
                        if (locations.length > 1 && !folded)
                          IconButton(
                            onPressed: () => setState(() {
                              final current = _sortByAddedDays[day];
                              if (current == null) {
                                _sortByAddedDays[day] = true; // oldest first
                              } else if (current) {
                                _sortByAddedDays[day] = false; // newest first
                              } else {
                                _sortByAddedDays.remove(day); // natural
                              }
                            }),
                            icon: Icon(
                              sortAscending == null
                                  ? Icons.swap_vert_rounded
                                  : sortAscending
                                      ? Icons.arrow_upward_rounded
                                      : Icons.arrow_downward_rounded,
                              color: sortAscending == null
                                  ? theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.45)
                                  : theme.colorScheme.primary,
                            ),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: sortAscending == null
                                ? 'Sort by date added'
                                : sortAscending
                                    ? 'Oldest added first — tap for newest'
                                    : 'Newest added first — tap to reset',
                          ),
                        // Per-day quick-add: adds a place already scheduled
                        // to THIS day, so empty gap days can be filled
                        // directly (past days too).
                        if (canAddHere)
                          IconButton(
                            onPressed: () => _showAddLocationForDate(day),
                            icon: Icon(Icons.add_circle_outline,
                                color: theme.colorScheme.primary),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: 'Add a place on this day',
                          ),
                      ],
                    ),
                  ],
                ),
                if (folded)
                  _buildFoldedDaySummary(day, locations, isPast: isPast)
                else ...[
                  const SizedBox(height: 12),
                  if (locations.isEmpty)
                    canAddHere
                        ? InkWell(
                            onTap: () => _showAddLocationForDate(day),
                            borderRadius: BorderRadius.circular(10),
                            child: _buildEmptyDayPlaceholder(
                                highlighted: highlighted, canAdd: true),
                          )
                        : _buildEmptyDayPlaceholder(highlighted: highlighted)
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: displayLocations.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      // displayLocations everywhere (card, index, group) so
                      // the detail sheet's swipe-through order matches the
                      // screen.
                      itemBuilder: (context, index) => _buildLocationCard(
                        displayLocations[index],
                        index,
                        displayLocations,
                        hasWriteAccess: hasWriteAccess,
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

  /// One-line stand-in for a folded day — what's on it and a nudge that it
  /// opens on tap. Tappable itself, so the whole header area unfolds, not
  /// just the date chip. Past days read in the past tense ("was planned").
  Widget _buildFoldedDaySummary(
    DateTime day,
    List<SavedLocation> locations, {
    required bool isPast,
  }) {
    final theme = Theme.of(context);
    final n = locations.length;
    final done = locations.where((l) => l.isDone).length;
    final String summary;
    if (n == 0) {
      summary = isPast ? 'Nothing was planned' : 'Nothing planned yet';
    } else {
      final places = '$n place${n == 1 ? '' : 's'}';
      summary = done == 0
          ? places
          : done == n
              ? '$places · all done'
              : '$places · $done done';
    }
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    return InkWell(
      onTap: () => setState(() => _dayFoldOverrides[day] = false),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 2),
        child: Row(
          children: [
            Icon(
              isPast ? Icons.history_rounded : Icons.unfold_more_rounded,
              size: 14,
              color: muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$summary · tap to show',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyDayPlaceholder(
      {required bool highlighted, bool canAdd = false}) {
    final theme = Theme.of(context);
    final color = highlighted
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.4);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1.2),
      ),
      child: Row(
        children: [
          Icon(canAdd && !highlighted ? Icons.add : Icons.add_road_outlined,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              highlighted
                  ? 'Release to move here'
                  : (canAdd
                      ? 'No places yet · tap to add or drag a card here'
                      : 'No locations · drag a card here'),
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Small floating chip rendered under the user's finger while dragging a
  /// location card. Lighter than re-rendering the whole card — keeps the
  /// drop targets visible underneath.
  /// Width of the card that rides under the finger while dragging.
  static const double _dragCardWidth = 260;

  /// The dragged location rendered as a miniature of its own card, so the
  /// user is visibly carrying the card rather than a generic chip. Centred
  /// under the finger (see the anchor strategy at the Draggable) and tilted
  /// a touch so it reads as "lifted off the page".
  Widget _buildDragFeedback(SavedLocation location) {
    final theme = Theme.of(context);
    final photoRefs = location.effectivePhotoReferences;
    return Material(
      color: Colors.transparent,
      child: Transform.rotate(
        angle: -0.02,
        child: Opacity(
          opacity: 0.95,
          child: Container(
            width: _dragCardWidth,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.9),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: photoRefs.isNotEmpty
                        ? LocationPhotoThumbnail(
                            photoRef: photoRefs.first,
                            size: 44,
                          )
                        : ColoredBox(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            child: Icon(Icons.location_on_rounded,
                                color: theme.colorScheme.primary, size: 22),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        location.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Drop on a day',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Auto-scroll while dragging ─────────────────────────────────────────
  // Draggable/DragTarget do NOT scroll the enclosing scroll view (unlike
  // ReorderableListView), so a card could never be moved to a day that was
  // off-screen. These drive the list from the drag's pointer position.

  final ScrollController _listScrollController = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  double? _dragPointerY;

  void _startDragAutoScroll() {
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _stopDragAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPointerY = null;
  }

  void _autoScrollTick() {
    final y = _dragPointerY;
    if (y == null || !_listScrollController.hasClients) return;
    final box =
        _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    // Hot zones at each end; speed ramps up the deeper the finger goes in.
    const zone = 130.0;
    const maxStep = 16.0;
    double delta = 0;
    if (y < top + zone) {
      delta = -maxStep * ((top + zone - y) / zone).clamp(0.0, 1.0);
    } else if (y > bottom - zone) {
      delta = maxStep * ((y - (bottom - zone)) / zone).clamp(0.0, 1.0);
    }
    if (delta == 0) return;

    final pos = _listScrollController.position;
    final target =
        (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (target != pos.pixels) _listScrollController.jumpTo(target);
  }

  /// Reassigns [location] to [newDay]. Uses the repository directly (mirrors
  /// the bypass pattern in [_deleteSelected]) so the trip-details screen can
  /// edit any trip the user has write access to, not just the active one.
  /// Backend RLS still enforces auth.
  Future<void> _moveLocationToDate(
      SavedLocation location, DateTime newDay) async {
    try {
      // Captured before the write: dragging onto a previously-empty day
      // materializes a new trip day → ask about accommodation after.
      // (Active-trip data; the prompt self-skips for non-active trips.)
      final dayKey = DateTime(newDay.year, newDay.month, newDay.day);
      // Shared same-day duplicate rule: same place may repeat across days,
      // never within one day.
      final saved = ref.read(savedLocationsProvider).valueOrNull ??
          const <SavedLocation>[];
      final dup = filterSameDayDuplicates(
        moving: [placeKeyOfSaved(location)],
        occupantsOnDay: saved
            .where((l) =>
                l.tripId == widget.trip.id &&
                l.id != location.id &&
                l.scheduledDate != null &&
                l.isActiveOnDate(dayKey))
            .map(placeKeyOfSaved),
      );
      if (dup.allowedIds.isEmpty) {
        AppToast.warning(
            context, '"${location.name}" is already on ${_labeler(dayKey)}');
        return;
      }
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      // Multi-day stays move WHOLE: shifting only the start left
      // start > end and the row disappeared from every day section.
      // Unscheduled rows have no span — oldStart is moot (delta zero).
      final newEnd = shiftedSpanEnd(
        oldStart: location.scheduledDate ?? newDay,
        oldEnd: location.scheduledEndDate,
        newStart: newDay,
      );
      await ref.read(locationRepositoryProvider).updateLocation(
        location.id,
        {
          'scheduled_date': newDay.toIso8601String(),
          'scheduled_end_date': newEnd?.toIso8601String(),
        },
      );
      if (!mounted) return;
      AppToast.success(
        context,
        'Moved ${location.name} to ${_labeler(newDay)}',
      );
      if (dayWasEmpty && mounted) {
        await maybePromptAccommodationForNewDays(
          context,
          ref,
          trip: widget.trip,
          newDays: [dayKey],
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not move location: $e');
    }
  }

  Widget _buildLocationCard(
    SavedLocation location,
    int index,
    List<SavedLocation> dateGroup, {
    required bool hasWriteAccess,
  }) {
    final isSelected = _selectedIds.contains(location.id);
    final photoRefs = location.effectivePhotoReferences;
    final hasPhotos = photoRefs.isNotEmpty;
    // Renew old Google photo references while the card is on screen; a
    // tile that fails to load asks for a renewal right away.
    final photoTarget = PhotoRefreshTarget.fromSaved(location);
    if (hasPhotos) {
      ref.read(placePhotoRefreshProvider).noteShown(photoTarget);
    }
    // Expanded by default — collapse only if the user explicitly
    // hides the gallery (their id ends up in [_photoCollapsedIds]).
    final isExpanded = !_photoCollapsedIds.contains(location.id);
    final showDragHandle = hasWriteAccess && !_selectionMode;

    void togglePhotos() {
      setState(() {
        if (isExpanded) {
          _photoCollapsedIds.add(location.id);
        } else {
          _photoCollapsedIds.remove(location.id);
        }
      });
    }

    return GestureDetector(
      onLongPress: () => _enterSelectionMode(location.id),
      onTap: () {
        if (_selectionMode) {
          _toggleSelection(location.id);
        } else {
          _showLocationDetail(location, index, dateGroup);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          // Translucent so the ambient globe stays visible behind the list.
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Theme.of(context).cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor.withValues(alpha: 0.1),
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Checkbox in selection mode, icon otherwise
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _selectionMode
                        ? Checkbox(
                            key: ValueKey('${location.id}_checkbox'),
                            value: isSelected,
                            onChanged: (_) => _toggleSelection(location.id),
                            visualDensity: VisualDensity.compact,
                          )
                        : Container(
                            key: ValueKey('${location.id}_icon'),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              location.isMultiDay
                                  ? Icons.hotel_rounded
                                  : Icons.location_on_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          location.name,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        if (location.isMultiDay)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '${_labeler(location.scheduledDate!)} → '
                              '${_labeler(location.scheduledEndDate!)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        // Raw lat/lng told the user nothing; the timestamp
                        // does. NOTE: `locations` has no updated_at column
                        // (last_synced_at is populated on ~6% of rows), so
                        // this is the ADD time — labelled honestly rather
                        // than passed off as a modification date.
                        Text(
                          'Added ${DateFormat('d MMM yyyy, h:mm a').format(location.createdAt.toLocal())}',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.6),
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // (The added-time + "Xm stay" column lived here — removed:
                  // the "Added …" line under the name already carries the
                  // timestamp, and stay is edited from the plan sheet.)
                  if (hasPhotos && !_selectionMode) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: isExpanded ? 'Hide photos' : 'Show photos',
                      icon: AnimatedRotation(
                        turns: isExpanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Icon(Icons.expand_more),
                      ),
                      onPressed: togglePhotos,
                    ),
                  ],
                  // Dedicated drag handle — using a handle (vs. wrapping the
                  // whole card in LongPressDraggable) avoids fighting the
                  // existing long-press → enter selection mode gesture.
                  if (showDragHandle) ...[
                    const SizedBox(width: 2),
                    Draggable<SavedLocation>(
                      data: location,
                      // Centre the card horizontally on the finger with the
                      // finger just below its top edge, so the card is
                      // carried rather than trailing off to one side.
                      dragAnchorStrategy: (_, __, ___) =>
                          const Offset(_dragCardWidth / 2, 26),
                      onDragStarted: () {
                        HapticFeedback.mediumImpact();
                        _startDragAutoScroll();
                      },
                      onDragUpdate: (d) => _dragPointerY = d.globalPosition.dy,
                      onDragEnd: (_) => _stopDragAutoScroll(),
                      onDragCompleted: _stopDragAutoScroll,
                      onDraggableCanceled: (_, __) => _stopDragAutoScroll(),
                      feedback: _buildDragFeedback(location),
                      childWhenDragging: Opacity(
                        opacity: 0.35,
                        child: Icon(
                          Icons.drag_indicator,
                          size: 22,
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Tooltip(
                        message: 'Drag to another day',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Padding(
                            // Roomier target: a 22px glyph is a hard thing
                            // to land a thumb on mid-scroll.
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 8),
                            child: Icon(
                              Icons.drag_indicator,
                              size: 22,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: hasPhotos && isExpanded
                  ? LocationPhotoGallery(
                      photoRefs: photoRefs,
                      heroTagPrefix: '${location.id}_trip_detail_photo',
                      title: location.name,
                      onLoadFailed: () => ref
                          .read(placePhotoRefreshProvider)
                          .noteLoadFailed(photoTarget),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddLocationDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Light barrier: the page (and its globe) stays visible behind the
      // frosted sheet instead of going near-black.
      barrierColor: AppTheme.sheetBarrierColor(context),
      builder: (context) => _LocationSearchSheet(
        trip: _trip,
      ),
    );
  }

  /// Opens the place-search sheet pre-scheduled to [day], so a place picked
  /// there lands on that specific date instead of today. Wired to the
  /// per-date add button and the empty-day placeholder.
  void _showAddLocationForDate(DateTime day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Light barrier: the page (and its globe) stays visible behind the
      // frosted sheet instead of going near-black.
      barrierColor: AppTheme.sheetBarrierColor(context),
      builder: (context) => _LocationSearchSheet(
        trip: _trip,
        scheduledDate: day,
      ),
    );
  }
}

class _LocationSearchSheet extends ConsumerStatefulWidget {
  final Trip trip;

  /// When set, a place added through this sheet is scheduled to this day
  /// instead of today — used by the per-date "add to this day" affordances.
  final DateTime? scheduledDate;

  const _LocationSearchSheet({
    required this.trip,
    this.scheduledDate,
  });

  String get tripId => trip.id;
  String? get tripCountryCode => trip.countryCode;

  @override
  ConsumerState<_LocationSearchSheet> createState() =>
      _LocationSearchSheetState();
}

class _LocationSearchSheetState extends ConsumerState<_LocationSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounceTimer;
  bool _isAddingPlace = false;

  /// Captured in initState because Riverpod forbids touching `ref` from
  /// dispose (it threw "Cannot use ref after the widget was disposed" on
  /// every sheet close). The provider is app-lifetime (not autoDispose),
  /// so calling clear() on the captured notifier after unmount is safe.
  late final PaginatedSearchNotifier _searchStateNotifier;

  @override
  void initState() {
    super.initState();
    _searchStateNotifier = ref.read(tripDetailSearchProvider.notifier);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    // Clear search state when sheet is closed.
    Future.microtask(_searchStateNotifier.clear);
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.isEmpty) {
        ref.read(tripDetailSearchProvider.notifier).clear();
      } else {
        ref.read(tripDetailSearchProvider.notifier).search(
              value,
              countryCodeOverride: widget.tripCountryCode,
            );
      }
    });
    setState(() {}); // Update clear button visibility
  }

  /// True iff [placeId] is already attached to THIS trip (the sheet is
  /// scoped to widget.trip, so we filter by trip_id rather than using a
  /// global pinned list — the trip being viewed in trip-details is often
  /// not the user's active trip).
  /// Same-day duplicate check for the add flow — the same shared rule as
  /// every reschedule path: the place may already exist elsewhere in the
  /// trip, just not on the day this sheet adds to.
  bool _isAlreadyOnTargetDay({
    String? placeId,
    String? name,
    double? lat,
    double? lng,
  }) {
    final target = _effectiveScheduledDate();
    final day = DateTime(target.year, target.month, target.day);
    final saved =
        ref.read(savedLocationsProvider).valueOrNull ?? const <SavedLocation>[];
    final candidate = (
      id: '',
      placeId: placeId,
      name: name ?? '',
      lat: lat ?? double.nan,
      lng: lng ?? double.nan,
    );
    return filterSameDayDuplicates(
      moving: [candidate],
      occupantsOnDay: saved
          .where((l) =>
              l.tripId == widget.tripId &&
              l.scheduledDate != null &&
              l.isActiveOnDate(day))
          .map(placeKeyOfSaved),
      samePlace: isLikelySamePlace,
    ).allowedIds.isEmpty;
  }

  /// Reset the sheet back to its "ready for the next search" state after
  /// a successful add or a duplicate hit. Keeps the sheet open so the
  /// user can chain adds without re-opening it each time, and refocuses
  /// the TextField so the keyboard stays up.
  void _resetSearchForNextAdd() {
    _debounceTimer?.cancel();
    _searchController.clear();
    ref.read(tripDetailSearchProvider.notifier).clear();
    if (mounted) {
      setState(() {}); // Update suffix-icon visibility
      _searchFocusNode.requestFocus();
    }
  }

  void _onScroll(ScrollController scrollController) {
    if (scrollController.position.pixels >=
        scrollController.position.maxScrollExtent * 0.8) {
      ref.read(tripDetailSearchProvider.notifier).loadMore();
    }
  }

  String _formatDistance(int distanceMeters) {
    if (distanceMeters < 1000) return '${distanceMeters}m away';
    return '${(distanceMeters / 1000).toStringAsFixed(1)}km away';
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(collaboratorRealtimeInitProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        scrollController.addListener(() => _onScroll(scrollController));
        // Frosted glass: the trip page (and its ambient globe) stays visible
        // through the sheet while the blur keeps the modal content readable.
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: AppTheme.sheetBlurSigma,
                sigmaY: AppTheme.sheetBlurSigma),
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .scaffoldBackgroundColor
                    .withValues(alpha: AppTheme.sheetFillAlpha(context)),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border.all(
                  color: AppTheme.sheetBorderColor(context),
                  width: 0.8,
                ),
              ),
              // Stack so the busy overlay can cover the whole sheet (close
              // button, drag handle, results) while a request is in flight —
              // prevents the user from queuing a second tap mid-add.
              child: Stack(
                children: [
                  Column(
                    children: [
                      // Drag handle
                      Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        height: 4,
                        width: 40,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),

                      // Header
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Search for Location',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                      ),

                      // Search bar
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: TextField(
                          cursorOpacityAnimates: false,
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: 'Search for a place...',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.link),
                                  tooltip: 'Paste Google Maps link',
                                  onPressed: _showUrlInputDialog,
                                ),
                                if (_searchController.text.isNotEmpty)
                                  IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _searchController.clear();
                                      ref
                                          .read(
                                              tripDetailSearchProvider.notifier)
                                          .clear();
                                      setState(() {});
                                    },
                                  ),
                              ],
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).cardColor,
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),

                      const Divider(),

                      // Search results
                      Expanded(
                        child: _buildSearchResults(scrollController),
                      ),
                    ],
                  ),
                  // Busy overlay shown during either add path. AbsorbPointer
                  // blocks taps so a second _addLocationToTrip can't queue
                  // up before the first round trip finishes — and gives the
                  // user clear "the tap took" feedback.
                  if (_isAddingPlace || _isPastingUrl)
                    Positioned.fill(
                      child: AbsorbPointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.25),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 20),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 16,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.4),
                                  ),
                                  const SizedBox(width: 14),
                                  Text(
                                    _isPastingUrl
                                        ? 'Decoding link…'
                                        : 'Adding location…',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSearchResults(ScrollController scrollController) {
    if (_searchController.text.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search,
              size: 64,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'Search for places to add',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Results will be filtered by your country',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.5),
                  ),
            ),
          ],
        ),
      );
    }

    final searchState = ref.watch(tripDetailSearchProvider);

    // Initial loading
    if (searchState.isLoading && searchState.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Error state
    if (searchState.error != null && searchState.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: ${searchState.error}'),
          ],
        ),
      );
    }

    // No results
    if (searchState.results.isEmpty && !searchState.isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_off,
              size: 64,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No places found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try a different search term',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.6),
                  ),
            ),
          ],
        ),
      );
    }

    // Results with infinite scroll
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: searchState.results.length + (searchState.hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        // Loading indicator at the end
        if (index == searchState.results.length) {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: searchState.isLoading
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const SizedBox.shrink(),
            ),
          );
        }

        final prediction = searchState.results[index];
        return ListTile(
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.location_on,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            prediction.mainText,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                prediction.secondaryText,
                style: TextStyle(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.6),
                ),
              ),
              // Distance from the device — same "Xkm away" line the map's
              // search screen shows, so both add paths read identically.
              // Null when the device has no fix (search still works).
              if (prediction.distanceMeters != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.near_me,
                      size: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDistance(prediction.distanceMeters!),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          onTap: () => _addLocationToTrip(prediction),
        );
      },
    );
  }

  bool _isPastingUrl = false;

  Future<void> _showUrlInputDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) => const GoogleMapsUrlDialog(),
    );
    if (url != null && url.isNotEmpty) {
      _processGoogleMapsUrl(url);
    }
  }

  /// Backstop for the per-date add flow. The sheet can carry a preselected
  /// [scheduledDate] (from a day slot's add button); refuse to schedule a new

  /// The day a place added through this sheet lands on.
  ///
  /// Per-date adds use their explicit day. The general add defaults to
  /// today — but unlike the map screen, the trip-details flow does NOT
  /// bother the user with the "Outside trip dates" dialog: when today is
  /// before the trip's range even starts, the place simply lands on the
  /// trip's FIRST day. (Today after the range is left to the existing
  /// confirm dialog, which offers extending the trip — silently dropping
  /// the place on a past first day would collide with the past-date lock.)
  DateTime _effectiveScheduledDate() {
    final explicit = widget.scheduledDate;
    if (explicit != null) return explicit;
    final now = DateTime.now();
    final start = widget.trip.startDate;
    // No dates yet: "today" means nothing on a numbered trip — Day 1.
    if (widget.trip.isUndated && start != null) {
      return DateTime(start.year, start.month, start.day);
    }
    if (start != null) {
      final today = DateTime(now.year, now.month, now.day);
      final startDay = DateTime(start.year, start.month, start.day);
      if (today.isBefore(startDay)) return startDay;
    }
    return now;
  }

  Future<void> _processGoogleMapsUrl(String text) async {
    if (_isPastingUrl || _isAddingPlace) return;

    if (!GoogleMapsUrlExtractor.isValidGoogleMapsUrl(text)) {
      if (mounted) {
        AppToast.warning(context, 'Not a valid Google Maps link');
      }
      return;
    }

    if (!mounted) return;

    // Inline overlay (see Stack in build()) handles the busy visual, so
    // no modal-dialog spinner is needed here. This also keeps the sheet
    // open so consecutive adds chain naturally.
    setState(() => _isPastingUrl = true);

    try {
      PlaceDetails? placeDetails;

      // Try extracting coordinates from the URL
      try {
        final coordinates =
            await GoogleMapsUrlExtractor.processGoogleMapsUrl(text);
        if (coordinates != null &&
            coordinates['latitude'] != null &&
            coordinates['longitude'] != null) {
          final lat = coordinates['latitude'] as double;
          final lng = coordinates['longitude'] as double;
          placeDetails =
              await PlacesService.getPlaceFromCoordinates(LatLng(lat, lng));
        }
      } catch (_) {}

      // Fallback: expand short URL and geocode the q parameter
      if (placeDetails == null) {
        String? expandedUrl;
        try {
          expandedUrl = await GoogleMapsUrlExtractor.expandShortUrl(text);
        } catch (_) {}
        final urlToParse = expandedUrl ?? text;
        final uri = Uri.tryParse(urlToParse);
        final query = uri?.queryParameters['q'];
        if (query != null && query.isNotEmpty) {
          placeDetails = await PlacesService.getPlaceFromAddress(query);
        }
      }

      if (placeDetails == null) {
        if (mounted) {
          AppToast.error(context, 'Could not decode location from URL');
        }
        return;
      }

      // Permission check
      final hasWriteAccess =
          await ref.read(hasWriteAccessProvider(widget.tripId).future);
      if (!hasWriteAccess) {
        if (mounted) {
          AppToast.warning(
            context,
            'You don\'t have permission to add locations to this trip.',
          );
        }
        return;
      }

      if (!mounted) return;

      // Reject the paste if the decoded place is already on this trip —
      // mirrors the tap-to-add path so both entry points behave the same.
      if (_isAlreadyOnTargetDay(
        placeId: placeDetails.placeId,
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
      )) {
        AppToast.warning(
          context,
          '"${placeDetails.name}" is already planned for this day',
        );
        _resetSearchForNextAdd();
        return;
      }

      final newLocation = SavedLocation(
        id: const Uuid().v4(),
        userId: '',
        fingerprint: '',
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
        isSkipped: false,
        stayDuration: 1800,
        scheduledDate: _effectiveScheduledDate(),
        createdAt: DateTime.now(),
        tripId: widget.tripId,
        photoReference: placeDetails.photoReference,
        photoReferences: placeDetails.photoReferences.isEmpty
            ? null
            : placeDetails.photoReferences,
        photoAttributions: placeDetails.photoAttributions,
        placeId: placeDetails.placeId,
        originalName: placeDetails.name,
        placeTypes: placeDetails.types.isEmpty ? null : placeDetails.types,
        googleOpeningHours: placeDetails.openingHours,
        hoursLastRefreshedAt:
            placeDetails.openingHours != null ? DateTime.now() : null,
      );

      final added = await LocationAddService(ref).addSavedLocation(
        context,
        newLocation,
        locationCountryCode: placeDetails.countryCode,
      );
      if (!mounted) return;
      if (!added) return;

      // Stay on the sheet so the user can paste another link / search
      // for the next place without re-opening it.
      AppToast.success(context, 'Added ${placeDetails.name} to trip');
      _resetSearchForNextAdd();
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Failed to decode URL: $e');
      }
    } finally {
      if (mounted) setState(() => _isPastingUrl = false);
    }
  }

  Future<void> _addLocationToTrip(PlacePrediction prediction) async {
    // Defensive — overlay should block a second tap, but guard the
    // race during its mount frame.
    if (_isAddingPlace || _isPastingUrl) return;

    // Permission check at function level
    final hasWriteAccess =
        await ref.read(hasWriteAccessProvider(widget.tripId).future);
    if (!mounted) return;
    if (!hasWriteAccess) {
      AppToast.warning(
        context,
        'You don\'t have permission to add locations to this trip.',
      );
      return;
    }

    // Cheap duplicate check using the prediction's place_id — saves the
    // round-trip cost of Place Details when the pick is already in the
    // trip. Notify the user, reset the search, and bail.
    if (_isAlreadyOnTargetDay(placeId: prediction.placeId)) {
      AppToast.warning(
        context,
        '"${prediction.mainText}" is already planned for this day',
      );
      _resetSearchForNextAdd();
      return;
    }

    setState(() => _isAddingPlace = true);
    try {
      final placeDetails =
          await PlacesService.getPlaceDetails(prediction.placeId);

      if (placeDetails == null) {
        if (mounted) {
          AppToast.error(context, 'Failed to get location details');
        }
        return;
      }
      if (!mounted) return;

      // Place Details may return a canonical place_id that differs from
      // the autocomplete prediction's id (CID vs ChIJ, region variants).
      // Re-check duplicates against the canonical id before committing.
      final canonicalPlaceId = placeDetails.placeId ?? prediction.placeId;
      if (_isAlreadyOnTargetDay(
        placeId: canonicalPlaceId,
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
      )) {
        AppToast.warning(
          context,
          '"${placeDetails.name}" is already planned for this day',
        );
        _resetSearchForNextAdd();
        return;
      }

      final newLocation = SavedLocation(
        id: const Uuid().v4(),
        userId: '', // Will be set by repository
        fingerprint: '',
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
        isSkipped: false,
        stayDuration: 1800, // 30 minutes default
        scheduledDate: _effectiveScheduledDate(),
        createdAt: DateTime.now(),
        tripId: widget.tripId, // Assign to this trip
        photoReference: placeDetails.photoReference,
        photoReferences: placeDetails.photoReferences.isEmpty
            ? null
            : placeDetails.photoReferences,
        photoAttributions: placeDetails.photoAttributions,
        placeId: canonicalPlaceId,
        originalName: placeDetails.name,
        placeTypes: placeDetails.types.isEmpty ? null : placeDetails.types,
        googleOpeningHours: placeDetails.openingHours,
        hoursLastRefreshedAt:
            placeDetails.openingHours != null ? DateTime.now() : null,
      );

      final added = await LocationAddService(ref).addSavedLocation(
        context,
        newLocation,
        locationCountryCode: placeDetails.countryCode,
      );
      if (!mounted) return;
      if (!added) return;

      // Stay on the sheet so the user can immediately pick the next
      // place — clears input, drops predictions, refocuses the field.
      AppToast.success(context, 'Added ${placeDetails.name} to trip');
      _resetSearchForNextAdd();
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Error: $e');
      }
    } finally {
      if (mounted) setState(() => _isAddingPlace = false);
    }
  }
}
