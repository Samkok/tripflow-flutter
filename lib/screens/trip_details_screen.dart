import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/providers/places_provider.dart';
import 'package:voyza/widgets/collaborators_sheet.dart';

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

  @override
  void initState() {
    super.initState();
    // Invalidate permissions when screen is first created to ensure fresh data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(hasWriteAccessProvider(widget.trip.id));
      ref.invalidate(isTripOwnerProvider(widget.trip.id));
      ref.invalidate(userTripPermissionProvider(widget.trip.id));
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
      appBar: AppBar(
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
      floatingActionButton: hasWriteAccessAsync.when(
        data: (hasWriteAccess) => hasWriteAccess
            ? FloatingActionButton.extended(
                onPressed: () => _showAddLocationDialog(),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add Location'),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.black,
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
      stream: ref.read(locationRepositoryProvider).watchLocations(),
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _getStatusColor(widget.trip.status, context)
                              .withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          widget.trip.status.toUpperCase(),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: _getStatusColor(
                                    widget.trip.status, context),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.trip.isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Active',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
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
                          ?.withOpacity(0.7),
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
              final location = locations[index];
              return _buildLocationCard(location);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard(SavedLocation location) {
    // Show the time from createdAt
    final timeString = DateFormat('HH:mm').format(location.createdAt);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.1),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
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
                            ?.withOpacity(0.6),
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
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
                          ?.withOpacity(0.5),
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
                            ?.withOpacity(0.5),
                      ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status, BuildContext context) {
    switch (status.toLowerCase()) {
      case 'planning':
        return Colors.blue;
      case 'active':
        return Colors.green;
      case 'completed':
        return Colors.purple;
      case 'archived':
        return Colors.grey;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  void _showAddLocationDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LocationSearchSheet(tripId: widget.trip.id),
    );
  }
}

class _LocationSearchSheet extends ConsumerStatefulWidget {
  final String tripId;

  const _LocationSearchSheet({required this.tripId});

  @override
  ConsumerState<_LocationSearchSheet> createState() =>
      _LocationSearchSheetState();
}

class _LocationSearchSheetState extends ConsumerState<_LocationSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(collaboratorRealtimeInitProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
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
                    ),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                  ),
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                  },
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
    if (_searchQuery.isEmpty) {
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

    // Use the places search provider
    final placesAsync = ref.watch(placesSearchProvider(_searchQuery));

    return placesAsync.when(
      data: (predictions) {
        if (predictions.isEmpty) {
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

        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: predictions.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final prediction = predictions[index];
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
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: $error'),
          ],
        ),
      ),
    );
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

    // Show loading indicator
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    try {
      // Get place details
      final placeDetails = await PlacesService.getPlaceDetails(prediction.placeId);

      if (placeDetails == null) {
        if (mounted) {
          Navigator.pop(context); // Close loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to get location details'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

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
      );

      // Add to repository
      await ref.read(locationRepositoryProvider).addLocation(newLocation);

      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${placeDetails.name} to trip'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context); // Close search sheet
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
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
