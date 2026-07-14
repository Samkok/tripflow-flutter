import 'dart:async';
import 'package:flutter/material.dart';
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
import 'package:voyza/utils/trip_dates.dart';

class TripDetailsScreen extends ConsumerStatefulWidget {
  final Trip trip;

  /// True only when pushed right after the user created their very first
  /// trip (see trip_screen._createTrip). Shows the one-time congrats modal
  /// on arrival — celebrating here, where the next action (adding places)
  /// lives, instead of on the screen being left behind.
  final bool celebrateFirstTrip;

  const TripDetailsScreen({
    super.key,
    required this.trip,
    this.celebrateFirstTrip = false,
  });

  @override
  ConsumerState<TripDetailsScreen> createState() => _TripDetailsScreenState();
}

class _TripDetailsScreenState extends ConsumerState<TripDetailsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  // Stream created once so rebuilds (e.g. typing in search) don't recreate it,
  // which would cause StreamBuilder to briefly flash ConnectionState.waiting.
  late final Stream<List<SavedLocation>> _locationsStream;

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
    });
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

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              elevation: 0,
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
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
                      if (_selectedIds.length == _currentTripLocations.length) {
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
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
                // Team members button - only visible to trip owner
                isOwnerAsync.when(
                  data: (isOwner) => isOwner
                      ? IconButton(
                          icon: const Icon(Icons.group_outlined),
                          tooltip: 'Team Members',
                          onPressed: () => _showCollaboratorsSheet(),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
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
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        FloatingActionButton.extended(
                          heroTag: 'fab_add_existing',
                          onPressed: () => _showExistingLocationsSheet(),
                          icon: const Icon(Icons.playlist_add_rounded),
                          label: const Text('Add Existing'),
                          backgroundColor: Theme.of(context).cardColor,
                          foregroundColor:
                              Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        FloatingActionButton.extended(
                          heroTag: 'fab_add_location',
                          onPressed: () => _showAddLocationDialog(),
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Add Location'),
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.black,
                        ),
                      ],
                    )
                  : null,
              loading: () => null,
              error: (_, __) => null,
            ),
    );
  }

  void _showCollaboratorsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
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
        debugPrint(
            'Trip details - Total locations in stream: ${allLocations.length}');

        if (allLocations.isEmpty) {
          debugPrint('Trip details - No locations in stream');
          return _buildEmptyState(true);
        }

        // Filter by trip ID
        var tripLocations =
            allLocations.where((loc) => loc.tripId == widget.trip.id).toList();

        // Apply search filter if query is not empty
        if (_searchQuery.isNotEmpty) {
          tripLocations = tripLocations
              .where((loc) => loc.name.toLowerCase().contains(_searchQuery))
              .toList();
        }

        debugPrint('Trip details - Trip ID: ${widget.trip.id}');
        debugPrint(
            'Trip details - Filtered locations: ${tripLocations.length}');
        debugPrint(
            'Trip details - Location details: ${allLocations.map((l) => '${l.name}(tripId=${l.tripId})').join(", ")}');

        if (tripLocations.isEmpty) {
          debugPrint('Trip details - No locations match this trip');
          return _buildEmptyState(false);
        }

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
      widget.trip.startDate,
      widget.trip.endDate,
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
      slivers: [
        SliverToBoxAdapter(
          child: _buildTripInfoSection(),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final day = allDates[index];
              final dateGroup = groupedByDay[day] ?? const <SavedLocation>[];
              return _buildDateSection(
                day,
                dateGroup,
                hasWriteAccess: hasWriteAccess,
              );
            },
            childCount: allDates.length,
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
            if (widget.trip.startDate != null &&
                widget.trip.endDate != null) ...[
              const SizedBox(height: 10),
              Builder(builder: (context) {
                final s = DateTime(widget.trip.startDate!.year,
                    widget.trip.startDate!.month, widget.trip.startDate!.day);
                final e = DateTime(widget.trip.endDate!.year,
                    widget.trip.endDate!.month, widget.trip.endDate!.day);
                final dayCount = e.difference(s).inDays + 1;
                final dateText = widget.trip.startDate == widget.trip.endDate
                    ? DateFormat('MMM d, y').format(widget.trip.startDate!)
                    : '${DateFormat('MMM d').format(widget.trip.startDate!)} - ${DateFormat('MMM d, y').format(widget.trip.endDate!)}';
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
              color: highlighted
                  ? theme.colorScheme.primary.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted
                    ? theme.colorScheme.primary.withValues(alpha: 0.6)
                    : Colors.transparent,
                width: 1.5,
              ),
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
  Widget _buildDragFeedback(SavedLocation location) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Transform.translate(
        offset: const Offset(12, 12),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_rounded,
                  color: Colors.black, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  location.name,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Reassigns [location] to [newDay]. Uses the repository directly (mirrors
  /// the bypass pattern in [_deleteSelected]) so the trip-details screen can
  /// edit any trip the user has write access to, not just the active one.
  /// Backend RLS still enforces auth.
  Future<void> _moveLocationToDate(
      SavedLocation location, DateTime newDay) async {
    try {
      await ref.read(locationRepositoryProvider).updateLocation(
        location.id,
        {'scheduled_date': newDay.toIso8601String()},
      );
      if (!mounted) return;
      AppToast.success(
        context,
        'Moved ${location.name} to ${DateFormat('MMM d').format(newDay)}',
      );
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
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Theme.of(context).cardColor,
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
                          '${(location.stayDuration / 60).toStringAsFixed(0)}m stay',
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
                      dragAnchorStrategy: pointerDragAnchorStrategy,
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 2, vertical: 4),
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
      builder: (context) => _LocationSearchSheet(
        trip: widget.trip,
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
      builder: (context) => _LocationSearchSheet(
        trip: widget.trip,
        scheduledDate: day,
      ),
    );
  }

  void _showExistingLocationsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ExistingLocationsSheet(trip: widget.trip),
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

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _debounceTimer?.cancel();
    // Clear search state when sheet is closed
    Future.microtask(() {
      ref.read(tripDetailSearchProvider.notifier).clear();
    });
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
  bool _isAlreadyInTrip(String? placeId) {
    if (placeId == null || placeId.isEmpty) return false;
    final saved = ref.read(savedLocationsProvider).asData?.value ?? const [];
    return saved.any((l) => l.tripId == widget.tripId && l.placeId == placeId);
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
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                                      .read(tripDetailSearchProvider.notifier)
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.4),
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
      if (_isAlreadyInTrip(placeDetails.placeId)) {
        AppToast.warning(
          context,
          '"${placeDetails.name}" is already in this trip',
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
        scheduledDate: widget.scheduledDate ?? DateTime.now(),
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
    if (_isAlreadyInTrip(prediction.placeId)) {
      AppToast.warning(
        context,
        '"${prediction.mainText}" is already in this trip',
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
      if (_isAlreadyInTrip(canonicalPlaceId)) {
        AppToast.warning(
          context,
          '"${placeDetails.name}" is already in this trip',
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
        scheduledDate: widget.scheduledDate ?? DateTime.now(),
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

class _ExistingLocationsSheet extends ConsumerStatefulWidget {
  /// The viewed trip itself, NOT just its id. The date-range confirmation
  /// in [LocationAddService.attachExistingLocationToTrip] needs the trip's
  /// startDate/endDate up front — looking it up via userTripsProvider
  /// silently fails for collaborator trips (which aren't in that provider)
  /// and during transient loading states, which is why the date dialog
  /// wasn't firing before.
  final Trip trip;

  const _ExistingLocationsSheet({required this.trip});

  @override
  ConsumerState<_ExistingLocationsSheet> createState() =>
      _ExistingLocationsSheetState();
}

class _ExistingLocationsSheetState
    extends ConsumerState<_ExistingLocationsSheet> {
  final Set<String> _adding = {};

  @override
  Widget build(BuildContext context) {
    final currentUserId = ref.watch(currentUserIdProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Add Existing Location',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
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

              const Divider(),

              // Location list
              Expanded(
                child: currentUserId == null
                    ? const Center(child: Text('Not signed in'))
                    : _buildLocationList(currentUserId, scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocationList(
      String currentUserId, ScrollController scrollController) {
    return StreamBuilder<List<SavedLocation>>(
      stream: ref.read(locationRepositoryProvider).watchLocations(),
      initialData: const [],
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final unassigned = (snapshot.data ?? [])
            .where((loc) => loc.tripId == null && loc.userId == currentUserId)
            .toList();

        if (unassigned.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.playlist_add_check_rounded,
                  size: 64,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  'No saved locations available',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Locations not assigned to any trip will appear here',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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

        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: unassigned.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final loc = unassigned[index];
            final isAdding = _adding.contains(loc.id);
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.location_on_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loc.name,
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${loc.lat.toStringAsFixed(4)}, ${loc.lng.toStringAsFixed(4)}',
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
                  const SizedBox(width: 8),
                  isAdding
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: () => _assignToTrip(loc),
                          child: const Text('Add'),
                        ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _assignToTrip(SavedLocation location) async {
    setState(() => _adding.add(location.id));

    try {
      // Best-effort country lookup so the cross-country guard works for
      // legacy rows without a stored country code.
      final details =
          await PlacesService.getPlaceDetails(location.placeId ?? '');

      if (!mounted) return;
      // Routes through the date-range confirmation dialog: if the
      // location's scheduledDate falls outside the viewed trip's range,
      // the user is asked whether to extend the trip dates. The previous
      // code called beforeAddingLocation (which checks the ACTIVE trip,
      // not the viewed one), so the dialog never fired for trip-details
      // attachments and the trip dates were silently left out of sync.
      final added = await LocationAddService(ref).attachExistingLocationToTrip(
        context,
        location,
        widget.trip,
        locationCountryCode: details?.countryCode,
      );
      if (!added || !mounted) return;
      AppToast.success(context, 'Added ${location.name} to trip');
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Failed to add location: $e');
      }
    } finally {
      if (mounted) setState(() => _adding.remove(location.id));
    }
  }
}
