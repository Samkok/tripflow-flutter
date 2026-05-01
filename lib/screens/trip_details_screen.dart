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
import 'package:voyza/widgets/collaborators_sheet.dart';
import 'package:voyza/widgets/google_maps_url_dialog.dart';
import 'package:voyza/services/location_add_service.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/trip_date_validator.dart';

class TripDetailsScreen extends ConsumerStatefulWidget {
  final Trip trip;

  const TripDetailsScreen({
    super.key,
    required this.trip,
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


  void _showLocationDetail(SavedLocation location, int indexInList) {
    final locationModel = LocationModel(
      id: location.id,
      name: location.name,
      address:
          '${location.lat.toStringAsFixed(5)}, ${location.lng.toStringAsFixed(5)}',
      coordinates: LatLng(location.lat, location.lng),
      addedAt: location.createdAt,
      stayDuration: Duration(seconds: location.stayDuration),
      isSkipped: location.isSkipped,
      isDone: location.isDone,
      scheduledDate: location.scheduledDate,
      photoReference: location.photoReference,
      photoReferences: location.effectivePhotoReferences,
      photoAttributions: location.photoAttributions,
    );

    final scrollController = ScrollController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => LocationDetailSheet(
        location: locationModel,
        number: indexInList + 1,
        parentScrollController: scrollController,
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
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _setActiveTrip() async {
    try {
      ref.read(tripProvider.notifier).clearTrip();
      await ref.read(localActiveTripIdProvider.notifier).setActiveTrip(widget.trip.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.trip.name} is now active')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not activate trip. Please try again.')),
        );
      }
    }
  }

  Future<void> _deactivateTrip() async {
    try {
      await ref.read(localActiveTripIdProvider.notifier).deactivateTrip();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip deactivated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not deactivate trip. Please try again.')),
        );
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
    final hasWriteAccessAsync = ref.watch(hasWriteAccessProvider(widget.trip.id));

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
                      if (_selectedIds.length ==
                          _currentTripLocations.length) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(
                            _currentTripLocations.map((l) => l.id));
                      }
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Delete selected',
                  onPressed:
                      _selectedIds.isEmpty ? null : _deleteSelected,
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
                  style:
                      FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed:
                      _selectedIds.isEmpty ? null : _deleteSelected,
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
            // Locations list
            Expanded(child: _buildLocationStreamBody()),
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
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton.extended(
                    heroTag: 'fab_add_location',
                    onPressed: () => _showAddLocationDialog(),
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Add Location'),
                    backgroundColor: Theme.of(context).colorScheme.primary,
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

  Widget _buildLocationStreamBody() {
    return StreamBuilder<List<SavedLocation>>(
      stream: _locationsStream,
      initialData: const [],
      builder: (context, snapshot) {
        debugPrint(
            'Trip details - Stream state: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, data length: ${snapshot.data?.length ?? 0}');

        // Handle connection states
        if (snapshot.connectionState == ConnectionState.waiting && snapshot.data == null) {
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
        debugPrint('Trip details - Total locations in stream: ${allLocations.length}');

        if (allLocations.isEmpty) {
          debugPrint('Trip details - No locations in stream');
          return _buildEmptyState(true);
        }

        // Filter by trip ID
        var tripLocations = allLocations
            .where((loc) => loc.tripId == widget.trip.id)
            .toList();

        // Apply search filter if query is not empty
        if (_searchQuery.isNotEmpty) {
          tripLocations = tripLocations
              .where((loc) => loc.name.toLowerCase().contains(_searchQuery))
              .toList();
        }

        debugPrint('Trip details - Trip ID: ${widget.trip.id}');
        debugPrint('Trip details - Filtered locations: ${tripLocations.length}');
        debugPrint('Trip details - Location details: ${allLocations.map((l) => '${l.name}(tripId=${l.tripId})').join(", ")}');

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

        return _buildLocationsList(tripLocations);
      },
    );
  }

  Widget _buildLocationsList(List<SavedLocation> locations) {
    if (locations.isEmpty) {
      return Column(
        children: [_buildTripInfoSection(), Expanded(child: _buildEmptyState(false))],
      );
    }

    // Group locations by scheduledDate (or createdAt if scheduledDate is null

    final groupedByDate = <String, List<dynamic>>{};

    for (final location in locations) {
      // Use scheduledDate if available, otherwise fall back to createdAt
      final dateToUse = location.scheduledDate ?? location.createdAt;
      final dateKey = DateFormat('MMMM dd, yyyy').format(dateToUse);

      debugPrint('Location ${location.name} belong to trip: ${location.tripId} for date: ${location.scheduledDate}');

      if (!groupedByDate.containsKey(dateKey)) {
        groupedByDate[dateKey] = [];
      }
      groupedByDate[dateKey]!.add(location);
    }

    // Sort dates in ascending order (earliest first)
    final sortedDates = groupedByDate.keys.toList()
      ..sort((a, b) {
        final dateA = DateFormat('MMMM dd, yyyy').parse(a);
        final dateB = DateFormat('MMMM dd, yyyy').parse(b);
        return dateA.compareTo(dateB);
      });

    return CustomScrollView(
      slivers: [
        // Trip info section
        SliverToBoxAdapter(
          child: _buildTripInfoSection(),
        ),

        // Locations by date
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final date = sortedDates[index];
              final locationsForDate = groupedByDate[date] ?? [];

              return _buildDateSection(date, locationsForDate);
            },
            childCount: sortedDates.length,
          ),
        ),

        const SliverPadding(padding: EdgeInsets.symmetric(vertical: 20)),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
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
            if (widget.trip.startDate != null && widget.trip.endDate != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.trip.startDate == widget.trip.endDate
                          ? DateFormat('MMM d, y').format(widget.trip.startDate!)
                          : '${DateFormat('MMM d').format(widget.trip.startDate!)} - ${DateFormat('MMM d, y').format(widget.trip.endDate!)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
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

  Widget _buildDateSection(String date, List<dynamic> locations) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              date,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const SizedBox(height: 12),

          // Locations for this date
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: locations.length,
            separatorBuilder: (context, index) =>
                const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final location = locations[index] as SavedLocation;
              return _buildLocationCard(location, index);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard(SavedLocation location, int index) {
    final timeString = DateFormat('HH:mm').format(location.createdAt);
    final isSelected = _selectedIds.contains(location.id);

    return GestureDetector(
      onLongPress: () => _enterSelectionMode(location.id),
      onTap: () {
        if (_selectionMode) {
          _toggleSelection(location.id);
        } else {
          _showLocationDetail(location, index);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
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
                        Icons.location_on_rounded,
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
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${location.lat.toStringAsFixed(4)}, ${location.lng.toStringAsFixed(4)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color
                              ?.withValues(alpha: 0.5),
                        ),
                  ),
              ],
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

  void _showExistingLocationsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ExistingLocationsSheet(tripId: widget.trip.id),
    );
  }
}

class _LocationSearchSheet extends ConsumerStatefulWidget {
  final Trip trip;

  const _LocationSearchSheet({
    required this.trip,
  });

  String get tripId => trip.id;
  String? get tripCountryCode => trip.countryCode;

  @override
  ConsumerState<_LocationSearchSheet> createState() =>
      _LocationSearchSheetState();
}

class _LocationSearchSheetState extends ConsumerState<_LocationSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  @override
  void dispose() {
    _searchController.dispose();
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Search for Location',
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

              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _searchController,
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
                              ref.read(tripDetailSearchProvider.notifier).clear();
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
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
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

  Future<void> _processGoogleMapsUrl(String text) async {
    if (_isPastingUrl) return;

    if (!GoogleMapsUrlExtractor.isValidGoogleMapsUrl(text)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not a valid Google Maps link'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    setState(() => _isPastingUrl = true);

    // Show loading dialog. Tracked via [loadingShown] so we always pop it
    // exactly once even when an error or early return happens at any point.
    bool loadingShown = false;
    void closeLoading() {
      if (loadingShown && mounted) {
        Navigator.pop(context);
        loadingShown = false;
      }
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator()),
      );
      loadingShown = true;
    }

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
        closeLoading();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not decode location from URL'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Permission check
      final hasWriteAccess =
          await ref.read(hasWriteAccessProvider(widget.tripId).future);
      if (!hasWriteAccess) {
        closeLoading();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'You don\'t have permission to add locations to this trip.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Close the spinner before any confirm modal so they don't stack.
      closeLoading();
      if (!mounted) return;
      final countryOk = await ensureLocationCountryAllowed(
        context,
        widget.trip,
        placeDetails.countryCode,
      );
      if (!countryOk) return;

      final newLocation = SavedLocation(
        id: const Uuid().v4(),
        userId: '',
        fingerprint: '',
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
        isSkipped: false,
        stayDuration: 1800,
        scheduledDate: DateTime.now(),
        createdAt: DateTime.now(),
        tripId: widget.tripId,
        photoReference: placeDetails.photoReference,
        photoReferences: placeDetails.photoReferences.isEmpty
            ? null
            : placeDetails.photoReferences,
        photoAttributions: placeDetails.photoAttributions,
      );

      if (!mounted) return;
      final added = await LocationAddService(ref).addSavedLocation(context, newLocation);
      if (!mounted) return;
      if (!added) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${placeDetails.name} to trip'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context); // Close search sheet
    } catch (e) {
      closeLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to decode URL: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPastingUrl = false);
    }
  }

  Future<void> _addLocationToTrip(PlacePrediction prediction) async {
    // Permission check at function level
    final hasWriteAccess = await ref.read(hasWriteAccessProvider(widget.tripId).future);
    if (!hasWriteAccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You don\'t have permission to add locations to this trip.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    // Show loading indicator. Tracked so we always pop it exactly once.
    bool loadingShown = false;
    void closeLoading() {
      if (loadingShown && mounted) {
        Navigator.pop(context);
        loadingShown = false;
      }
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );
      loadingShown = true;
    }

    try {
      // Get place details
      final placeDetails = await PlacesService.getPlaceDetails(prediction.placeId);

      if (placeDetails == null) {
        closeLoading();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to get location details'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Close the spinner before any confirm modal so they don't stack.
      closeLoading();
      if (!mounted) return;
      final countryOk = await ensureLocationCountryAllowed(
        context,
        widget.trip,
        placeDetails.countryCode,
      );
      if (!countryOk) return;

      // Create SavedLocation
      final newLocation = SavedLocation(
        id: const Uuid().v4(),
        userId: '', // Will be set by repository
        fingerprint: '',
        name: placeDetails.name,
        lat: placeDetails.coordinates.latitude,
        lng: placeDetails.coordinates.longitude,
        isSkipped: false,
        stayDuration: 1800, // 30 minutes default
        scheduledDate: DateTime.now(),
        createdAt: DateTime.now(),
        tripId: widget.tripId, // Assign to this trip
        photoReference: placeDetails.photoReference,
        photoReferences: placeDetails.photoReferences.isEmpty
            ? null
            : placeDetails.photoReferences,
        photoAttributions: placeDetails.photoAttributions,
      );

      if (!mounted) return;
      final added = await LocationAddService(ref).addSavedLocation(context, newLocation);
      if (!mounted) return;
      if (!added) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${placeDetails.name} to trip'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context); // Close search sheet
    } catch (e) {
      closeLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _ExistingLocationsSheet extends ConsumerStatefulWidget {
  final String tripId;

  const _ExistingLocationsSheet({required this.tripId});

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
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
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
      stream:
          ref.read(locationRepositoryProvider).watchLocations(),
      initialData: const [],
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final unassigned = (snapshot.data ?? [])
            .where((loc) =>
                loc.tripId == null && loc.userId == currentUserId)
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
                  color:
                      Theme.of(context).dividerColor.withValues(alpha: 0.1),
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
      await ref
          .read(locationRepositoryProvider)
          .updateLocation(location.id, {'trip_id': widget.tripId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${location.name} to trip'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add location: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _adding.remove(location.id));
    }
  }
}
