import 'dart:async';
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
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/widgets/accommodation_prompts.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/services/trip_day_service.dart';
import 'package:voyza/widgets/pulsing_glow.dart';
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

  // Per-location COLLAPSE state for the photo dropdown. Tracks the
  // ids of cards the user has explicitly collapsed; everything else is
  // expanded by default. (Previously this tracked expanded ids, so the
  // default was collapsed — flipping the polarity here is the whole
  // change needed to show photos out of the box.)
  final Set<String> _photoCollapsedIds = {};

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
      ref.read(locationRepositoryProvider).fetchRemoteLocations();

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
      final day = _dayKey(target.scheduledDate ?? target.createdAt);
      // Same day-cover rule as _buildLocationsList: the group holds every
      // location whose scheduled range covers the target's first day.
      final dateGroup = tripLocations.where((l) {
        final startRaw = l.scheduledDate ?? l.createdAt;
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
                      ? PulsingGlow(
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
        // the step at 3). Post-frame — never mutate providers during build.
        final checklistCount = tripLocations.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(checklistProvider.notifier)
                .reportTripLocationCount(checklistCount);
          }
        });

        // Apply search filter if query is not empty
        if (_searchQuery.isNotEmpty) {
          tripLocations = tripLocations
              .where((loc) => loc.name.toLowerCase().contains(_searchQuery))
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

        // Keep a reference so the selection-mode AppBar can select all
        if (_currentTripLocations != tripLocations) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _currentTripLocations = tripLocations);
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

  /// Stay duration (stored in seconds) → "45m" under an hour, "2h" / "1h 30m"
  /// above it.
  String _formatStayLabel(int seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  /// True when [day] is a calendar day strictly before today. Used to lock
  /// out the per-date "add a place" affordances for dates that have already
  /// passed (mirrors the search screen's guard and the detail sheet's
  /// past-date edit lockout).
  bool _isPastDay(DateTime day) =>
      _dayKey(day).isBefore(_dayKey(DateTime.now()));

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
      for (final loc in locations) ...[
        loc.scheduledDate ?? loc.createdAt,
        loc.scheduledEndDate ?? loc.scheduledDate ?? loc.createdAt,
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
    for (final location in locations) {
      final startRaw = location.scheduledDate ?? location.createdAt;
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

    // If the trip has no date range AND no locations, fall back to the
    // standard empty state below the trip info card.
    if (allDates.isEmpty) {
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
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index == allDates.length) {
                return _buildAddDayTile(allDates);
              }
              final day = allDates[index];
              final dateGroup = groupedByDay[day] ?? const <SavedLocation>[];
              return _buildDateSection(
                day,
                dateGroup,
                hasWriteAccess: hasWriteAccess,
              );
            },
            childCount: allDates.length +
                ((hasWriteAccess && _searchQuery.isEmpty) ? 1 : 0),
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
              Builder(builder: (context) {
                final s = dayKey(_trip.startDate!);
                final e = dayKey(_trip.endDate!);
                final dayCount = daySpanDays(s, e) + 1;
                final dateText = s == e
                    ? DateFormat('MMM d, y').format(s)
                    : '${DateFormat('MMM d').format(s)} - ${DateFormat('MMM d, y').format(e)}';
                return Row(
                  children: [
                    Icon(
                      Icons.calendar_today_rounded,
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
                  ],
                );
              }),
            ],
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
                        'Add a day (${DateFormat('MMM d').format(newDay)})',
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

  Widget _buildDateSection(
    DateTime day,
    List<SavedLocation> locations, {
    required bool hasWriteAccess,
  }) {
    final dateLabel = DateFormat('MMMM dd, yyyy').format(day);
    final theme = Theme.of(context);
    // A place can only be added to today or a future day. Past days stay
    // read-only for adding (existing cards can still be dragged around).
    final canAddHere = hasWriteAccess && !_isPastDay(day);

    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      // DragTarget around the whole day so users can drop on either the
      // header or anywhere inside the section (including the empty
      // placeholder for a day with no locations yet).
      child: DragTarget<SavedLocation>(
        onWillAcceptWithDetails: (details) {
          if (!hasWriteAccess) return false;
          // Reject re-drops onto the same day to keep highlight feedback
          // honest and avoid a no-op write.
          final src = details.data.scheduledDate ?? details.data.createdAt;
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
                  children: [
                    // Flexible + ellipsis so a long date label at large
                    // accessibility text scales truncates instead of
                    // overflowing the header Row.
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                dateLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (locations.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                '${locations.length}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.7),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Per-day quick-add: adds a place already scheduled to
                    // THIS day, so empty gap days can be filled directly.
                    // Hidden on past days — you can't schedule into the past.
                    if (canAddHere)
                      IconButton(
                        onPressed: () => _showAddLocationForDate(day),
                        icon: Icon(Icons.add_circle_outline,
                            color: theme.colorScheme.primary),
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 40, minHeight: 32),
                        tooltip: 'Add a place on this day',
                      ),
                  ],
                ),
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
                    itemCount: locations.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) => _buildLocationCard(
                      locations[index],
                      index,
                      locations,
                      hasWriteAccess: hasWriteAccess,
                    ),
                  ),
              ],
            ),
          );
        },
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
        AppToast.warning(context,
            '"${location.name}" is already on ${DateFormat('MMM d').format(dayKey)}');
        return;
      }
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      // Multi-day stays move WHOLE: shifting only the start left
      // start > end and the row disappeared from every day section.
      final newEnd = shiftedSpanEnd(
        oldStart: location.scheduledDate ?? location.createdAt,
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
        'Moved ${location.name} to ${DateFormat('MMM d').format(newDay)}',
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
    final timeString = DateFormat('HH:mm').format(location.createdAt);
    final isSelected = _selectedIds.contains(location.id);
    final photoRefs = location.effectivePhotoReferences;
    final hasPhotos = photoRefs.isNotEmpty;
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
                              '${DateFormat('MMM d').format(location.scheduledDate!)} → '
                              '${DateFormat('MMM d').format(location.scheduledEndDate!)}',
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
                        Text(
                          '${location.lat.toStringAsFixed(4)}, ${location.lng.toStringAsFixed(4)}',
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
                  const SizedBox(width: 4),
                  // Time + stay
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        timeString,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withValues(alpha: 0.5),
                            ),
                      ),
                      if (location.stayDuration > 0)
                        Text(
                          '${_formatStayLabel(location.stayDuration)} stay',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color
                                        ?.withValues(alpha: 0.5),
                                  ),
                        ),
                    ],
                  ),
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
          subtitle: Text(
            prediction.secondaryText,
            style: TextStyle(
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withValues(alpha: 0.6),
            ),
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
  /// place onto a day before today — covering the edge where the day was
  /// valid at render time but has since rolled into the past, or any future
  /// code path that reaches these add methods without the UI gate. Mirrors
  /// the search screen's guard. Returns true (and warns) when the add must
  /// be refused.
  bool _blockIfScheduledDateInPast() {
    final d = widget.scheduledDate;
    if (d == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (DateTime(d.year, d.month, d.day).isBefore(today)) {
      if (mounted) {
        AppToast.warning(context, 'Cannot add locations to a past date.');
      }
      return true;
    }
    return false;
  }

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
    if (start != null) {
      final today = DateTime(now.year, now.month, now.day);
      final startDay = DateTime(start.year, start.month, start.day);
      if (today.isBefore(startDay)) return startDay;
    }
    return now;
  }

  Future<void> _processGoogleMapsUrl(String text) async {
    if (_isPastingUrl || _isAddingPlace) return;
    if (_blockIfScheduledDateInPast()) return;

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
    if (_blockIfScheduledDateInPast()) return;

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
