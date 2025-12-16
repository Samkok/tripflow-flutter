import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/screens/trip_details_screen.dart';

class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  bool _showCreateForm = false;
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _resetForm() {
    _nameController.clear();
    _descriptionController.clear();
    setState(() => _showCreateForm = false);
  }

  Future<void> _createTrip() async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a trip name')),
      );
      return;
    }

    try {
      final authState = ref.read(authStateProvider);
      final tripRepository = ref.read(tripRepositoryProvider);

      await authState.whenData((state) async {
        final userId = state.session?.user.id;
        if (userId == null) throw Exception('User not authenticated');

        await tripRepository.createTrip(
          userId: userId,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
        );

        // Invalidate and refresh
        ref.invalidate(userTripsProvider);
        _resetForm();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Trip created successfully!')),
          );
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating trip: $e')),
        );
      }
    }
  }

  Future<void> _setActiveTrip(Trip trip) async {
    try {
      // Clear cached locations on the map before activating a new trip
      ref.read(tripProvider.notifier).clearTrip();

      final tripRepository = ref.read(tripRepositoryWithEventsProvider);
      await tripRepository.setActiveTrip(trip.userId, trip.id);
      ref.invalidate(activeTripsProvider);
      ref.invalidate(userTripsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${trip.name} is now active')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error setting active trip: $e')),
        );
      }
    }
  }

  Future<void> _deleteTrip(Trip trip) async {
    try {
      final tripRepository = ref.read(tripRepositoryProvider);
      await tripRepository.deleteTrip(trip.id);
      ref.invalidate(userTripsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting trip: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tripsAsync = ref.watch(userTripsProvider);
    final activeTripAsync = ref.watch(activeTripsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Header
          SliverAppBar(
            floating: true,
            pinned: true,
            elevation: 0,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            title: Text(
              'My Trips',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),

          // Active Trip Section
          SliverToBoxAdapter(
            child: activeTripAsync.when(
              data: (activeTrip) {
                if (activeTrip == null) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildEmptyActiveTrip(context),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: _buildActiveTrip(context, activeTrip),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (err, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $err'),
              ),
            ),
          ),

          const SliverPadding(padding: EdgeInsets.symmetric(vertical: 8)),

          // Create Trip Button or Form
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _showCreateForm
                  ? _buildCreateForm(context)
                  : ElevatedButton.icon(
                      onPressed: () => setState(() => _showCreateForm = true),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('New Trip'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
            ),
          ),

          const SliverPadding(padding: EdgeInsets.symmetric(vertical: 8)),

          // Trips List
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Your Trips',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ),

          tripsAsync.when(
            data: (trips) {
              if (trips.isEmpty) {
                return SliverFillRemaining(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'No trips yet. Create one to get started!',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.color
                                  ?.withOpacity(0.6),
                            ),
                      ),
                    ),
                  ),
                );
              }

              return SliverPadding(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: 32,
                ),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final trip = trips[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildTripCard(context, trip),
                      );
                    },
                    childCount: trips.length,
                  ),
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => SliverFillRemaining(
              child: Center(child: Text('Error: $err')),
            ),
          ),

          const SliverPadding(padding: EdgeInsets.symmetric(vertical: 30)),
        ],
      ),
    );
  }

  Widget _buildEmptyActiveTrip(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.trip_origin_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'No Active Trip',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Select or create a trip to get started',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.7),
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTrip(BuildContext context, Trip trip) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary.withOpacity(0.2),
            Theme.of(context).colorScheme.secondary.withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
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
                          Icons.navigation_rounded,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Active Trip',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      trip.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () async =>
                    await _setActiveTrip(trip.copyWith(isActive: false)),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .secondary
                        .withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    color: Theme.of(context).colorScheme.secondary,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          if (trip.description != null && trip.description!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              trip.description!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.7),
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'Trip name',
              labelText: 'Trip Name',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: InputDecoration(
              hintText: 'Optional description',
              labelText: 'Description',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            minLines: 2,
            maxLines: 3,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _resetForm,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _createTrip,
                  child: const Text('Create'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTripCard(BuildContext context, Trip trip) {
    // Watch locations to get location count and date range
    final locationsAsync = ref.watch(savedLocationsProvider);

    return locationsAsync.when(
      data: (allLocations) {
        // Filter locations for this trip
        final tripLocations = allLocations
            .where((loc) => loc.tripId == trip.id)
            .toList();

        // Calculate date range
        DateTime? startDate;
        DateTime? endDate;
        if (tripLocations.isNotEmpty) {
          final dates = tripLocations
              .map((loc) => loc.scheduledDate ?? loc.createdAt)
              .toList()
            ..sort();
          startDate = dates.first;
          endDate = dates.last;
        }

        return _buildTripCardContent(
          context,
          trip,
          tripLocations.length,
          startDate,
          endDate,
        );
      },
      loading: () => _buildTripCardContent(context, trip, 0, null, null),
      error: (_, __) => _buildTripCardContent(context, trip, 0, null, null),
    );
  }

  Widget _buildTripCardContent(
    BuildContext context,
    Trip trip,
    int locationCount,
    DateTime? startDate,
    DateTime? endDate,
  ) {
    final statusColor = trip.isActive ? Colors.green : Colors.orange;
    final statusText = trip.isActive ? 'Active' : 'Inactive';

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TripDetailsScreen(trip: trip),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: trip.isActive
                ? Colors.green.withValues(alpha: 0.3)
                : Theme.of(context).dividerColor.withValues(alpha: 0.2),
            width: trip.isActive ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: trip.isActive
                  ? Colors.green.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: trip.isActive ? 8 : 4,
              offset: Offset(0, trip.isActive ? 4 : 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with name and action menu
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      trip.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.6),
                    ),
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: 'rename',
                        child: Row(
                          children: [
                            Icon(
                              Icons.edit_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            const Text('Rename'),
                          ],
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: const Row(
                          children: [
                            Icon(
                              Icons.delete_rounded,
                              size: 18,
                              color: Colors.red,
                            ),
                            SizedBox(width: 12),
                            Text(
                              'Delete',
                              style: TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'rename') {
                        _showEditTripDialog(context, trip);
                      } else if (value == 'delete') {
                        _showDeleteConfirmation(context, trip);
                      }
                    },
                  ),
                ],
              ),
            ),

            // Trip info
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Location count
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          Icons.location_on,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$locationCount ${locationCount == 1 ? 'location' : 'locations'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ],
                  ),

                  // Date range
                  if (startDate != null && endDate != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.calendar_today,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            startDate == endDate
                                ? DateFormat('MMM d, y').format(startDate)
                                : '${DateFormat('MMM d').format(startDate)} - ${DateFormat('MMM d, y').format(endDate)}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 12),

                  // Status and activate button
                  Row(
                    children: [
                      // Status indicator
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              statusText,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const Spacer(),

                      // Activate/Deactivate button
                      SizedBox(
                        height: 32,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (trip.isActive) {
                              _deactivateTrip(trip);
                            } else {
                              _setActiveTrip(trip);
                            }
                          },
                          icon: Icon(
                            trip.isActive
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                            size: 18,
                          ),
                          label: Text(trip.isActive ? 'Deactivate' : 'Activate'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: trip.isActive
                                ? Colors.orange
                                : Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deactivateTrip(Trip trip) async {
    try {
      final tripRepository = ref.read(tripRepositoryWithEventsProvider);
      await tripRepository.deactivateTrip(trip.id);
      ref.invalidate(activeTripsProvider);
      ref.invalidate(userTripsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip deactivated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deactivating trip: $e')),
        );
      }
    }
  }

  void _showDeleteConfirmation(BuildContext context, Trip trip) {
    // Get location count for this trip
    final locationsAsync = ref.read(savedLocationsProvider);

    locationsAsync.whenData((allLocations) {
      final tripLocations = allLocations
          .where((loc) => loc.tripId == trip.id)
          .toList();
      final locationCount = tripLocations.length;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: Colors.red,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Delete Trip?'),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete "${trip.name}"?',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 12),
              if (locationCount > 0) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Colors.orange,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This trip has $locationCount ${locationCount == 1 ? 'location' : 'locations'}. All locations will also be deleted.',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Text(
                'This action cannot be undone.',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _deleteTrip(trip);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
    });
  }

  void _showEditTripDialog(BuildContext context, Trip trip) {
    final editNameController = TextEditingController(text: trip.name);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Trip Name'),
        content: TextField(
          controller: editNameController,
          decoration: InputDecoration(
            hintText: 'Trip name',
            labelText: 'Trip Name',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _updateTripName(trip, editNameController.text.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateTripName(Trip trip, String newName) async {
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trip name cannot be empty')),
      );
      return;
    }

    if (newName == trip.name) {
      return; // No changes made
    }

    try {
      final tripRepository = ref.read(tripRepositoryProvider);
      await tripRepository.updateTrip(
        trip.id,
        name: newName,
      );

      ref.invalidate(userTripsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip name updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating trip: $e')),
        );
      }
    }
  }
}

extension on String {
}
