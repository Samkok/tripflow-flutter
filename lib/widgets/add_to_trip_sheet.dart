import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/location_model.dart';
import '../models/trip.dart';
import '../providers/user_trip_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';

class AddToTripSheet extends ConsumerStatefulWidget {
  final List<LocationModel> availableLocations;
  final VoidCallback? onSuccess;

  const AddToTripSheet({
    super.key,
    required this.availableLocations,
    this.onSuccess,
  });

  @override
  ConsumerState<AddToTripSheet> createState() => _AddToTripSheetState();
}

class _AddToTripSheetState extends ConsumerState<AddToTripSheet> {
  late Set<String> selectedLocationIds;
  Trip? selectedTrip;

  @override
  void initState() {
    super.initState();
    selectedLocationIds = {};
  }

  @override
  Widget build(BuildContext context) {
    final tripsAsync = ref.watch(userTripsProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
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
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Add Locations to Trip',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Select ${selectedLocationIds.length} location${selectedLocationIds.length != 1 ? 's' : ''} and a trip',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.6),
                          ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Locations List
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: widget.availableLocations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final location = widget.availableLocations[index];
                    final isSelected = selectedLocationIds.contains(location.id);

                    return _buildLocationTile(location, isSelected, () {
                      setState(() {
                        if (isSelected) {
                          selectedLocationIds.remove(location.id);
                        } else {
                          selectedLocationIds.add(location.id);
                        }
                      });
                    });
                  },
                ),
              ),
              const Divider(height: 1),
              // Trip Selection
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Trip',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 12),
                    tripsAsync.when(
                      data: (trips) {
                        if (trips.isEmpty) {
                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'No trips available. Create a trip first.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          );
                        }

                        return Wrap(
                          spacing: 8,
                          children: trips.map((trip) {
                            final isSelected = selectedTrip?.id == trip.id;
                            return FilterChip(
                              selected: isSelected,
                              label: Text(trip.name),
                              onSelected: (selected) {
                                setState(() {
                                  selectedTrip = selected ? trip : null;
                                });
                              },
                              backgroundColor: Theme.of(context).cardColor,
                              selectedColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.2),
                            );
                          }).toList(),
                        );
                      },
                      loading: () => const SizedBox(
                        height: 40,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      error: (_, __) => Text(
                        'Error loading trips',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.red,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Action Buttons
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed:
                            selectedLocationIds.isEmpty || selectedTrip == null
                                ? null
                                : () async {
                                    // Check if user has write access to the selected trip
                                    final hasWriteAccess = await ref.read(
                                        hasWriteAccessProvider(selectedTrip!.id)
                                            .future);

                                    if (!hasWriteAccess) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'You don\'t have permission to add locations to this trip.'),
                                            backgroundColor: Colors.orange,
                                          ),
                                        );
                                      }
                                      return;
                                    }

                                    // Add locations to trip
                                    await ref
                                        .read(tripProvider.notifier)
                                        .addLocationsToTrip(
                                          selectedLocationIds.toList(),
                                          selectedTrip!.id,
                                        );

                                    if (mounted) {
                                      Navigator.pop(context);
                                      widget.onSuccess?.call();

                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '${selectedLocationIds.length} location${selectedLocationIds.length != 1 ? 's' : ''} added to ${selectedTrip!.name}',
                                          ),
                                          duration:
                                              const Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  },
                        child: const Text('Add to Trip'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLocationTile(
    LocationModel location,
    bool isSelected,
    VoidCallback onToggle,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor.withOpacity(0.1),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                onChanged: (_) => onToggle(),
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
                      '${location.coordinates.latitude.toStringAsFixed(4)}, ${location.coordinates.longitude.toStringAsFixed(4)}',
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
            ],
          ),
        ),
      ),
    );
  }
}
