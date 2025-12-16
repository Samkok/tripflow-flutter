import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/widgets/add_to_trip_sheet.dart';

import '../core/theme.dart';

class LocationDetailSheet extends ConsumerWidget {
  final LocationModel location;
  final int number;
  final ScrollController parentScrollController;
  final DraggableScrollableController? parentSheetController;
  final Function(LatLng)? onLocationTap;

  const LocationDetailSheet({
    super.key,
    required this.location,
    required this.number,
    required this.parentScrollController,
    this.parentSheetController,
    this.onLocationTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the provider to get the most up-to-date location data
    final updatedLocation = ref.watch(tripProvider.select((trip) => trip
        .pinnedLocations
        .firstWhere((l) => l.id == location.id, orElse: () => location)));

    // Determine if the location is on a past date to disable editing.
    final selectedDate = ref.watch(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPastDate = selectedDate.isBefore(today);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with stop number
          _buildHeader(context, ref, updatedLocation, isPastDate),
          const SizedBox(height: 24),

          // Address
          _buildDetailRow(
            context,
            Icons.location_on,
            'Address',
            updatedLocation.address,
          ),

          // Stay Duration
          _buildDetailRow(
            context,
            Icons.timer_outlined,
            'Planned Stay',
            _formatDuration(updatedLocation.stayDuration),
          ),

          // Coordinates
          _buildDetailRow(
            context,
            Icons.my_location,
            'Coordinates',
            '${updatedLocation.coordinates.latitude.toStringAsFixed(6)}, ${updatedLocation.coordinates.longitude.toStringAsFixed(6)}',
          ),

          // Travel info (if available)
          if (updatedLocation.travelTimeFromPrevious != null &&
              updatedLocation.distanceFromPrevious != null) ...[
            const Divider(height: 32),
            _buildTravelInfo(context, ref, updatedLocation),
          ],

          const SizedBox(height: 24),

          // Action buttons
          _buildActionButtons(context, ref, updatedLocation, isPastDate),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref,
      LocationModel updatedLocation, bool isPastDate) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Stop number and label row
        Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              radius: 24,
              child: Text(
                '$number',
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              'Stop $number',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Location name - full width with proper wrapping
        Text(
          updatedLocation.name,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 16),

        // Action buttons row - separated from name
        Row(
          children: [
            // Schedule Date Button
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: isPastDate
                      ? Colors.grey
                      : Theme.of(context).colorScheme.primary,
                ),
                label: const Text('Date'),
                onPressed: isPastDate
                    ? null
                    : () async {
                        final datesWithLocations =
                            ref.read(datesWithLocationsProvider);
                        final now = DateTime.now();
                        final newDate =
                            await DatePickerUtils.showCustomDatePicker(
                          context: context,
                          initialDate: updatedLocation.scheduledDate ?? now,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: DateTime(now.year + 5),
                          highlightedDates: datesWithLocations,
                        );
                        if (newDate != null) {
                          final normalizedDate = DateTime(
                              newDate.year, newDate.month, newDate.day);
                          ref
                              .read(tripProvider.notifier)
                              .updateLocationScheduledDate(
                                  updatedLocation.id, normalizedDate);
                        }
                      },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  side: BorderSide(
                    color: isPastDate
                        ? Colors.grey.withValues(alpha: 0.3)
                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Edit Button
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: isPastDate
                      ? Colors.grey
                      : Theme.of(context).colorScheme.primary,
                ),
                label: const Text('Edit'),
                onPressed: isPastDate
                    ? null
                    : () => _showEditLocationNameDialog(
                        context, ref, updatedLocation),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  side: BorderSide(
                    color: isPastDate
                        ? Colors.grey.withValues(alpha: 0.3)
                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Delete Button
            OutlinedButton.icon(
              icon: const Icon(
                Icons.delete_outline,
                size: 18,
                color: Colors.red,
              ),
              label: const Text(
                'Delete',
                style: TextStyle(color: Colors.red),
              ),
              onPressed: () => _showDeleteConfirmationDialog(
                  context, ref, updatedLocation),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                side: BorderSide(
                  color: Colors.red.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Add to Trip Icon Button
            IconButton(
              icon: Icon(
                Icons.playlist_add,
                size: 24,
                color: Theme.of(context).colorScheme.primary,
              ),
              onPressed: () async {
                // Show trip selection bottom sheet for this location
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (context) => AddToTripSheet(
                    availableLocations: [updatedLocation],
                    onSuccess: () {
                      Navigator.of(context).pop();
                    },
                  ),
                );
              },
              style: IconButton.styleFrom(
                side: BorderSide(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              tooltip: 'Add to Trip',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTravelInfo(
      BuildContext context, WidgetRef ref, LocationModel updatedLocation) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Travel from Previous Stop',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        Builder(builder: (context) {
          final trip = ref.read(tripProvider);
          // Get all locations for the date, then filter out skipped ones to get the actual route order.
          final allLocationsForDate =
              ref.read(locationsForSelectedDateProvider);
          final routedLocations =
              allLocationsForDate.where((l) => !l.isSkipped).toList();

          // Find the index of the current location in the day's list.
          final locationIndexInList =
              routedLocations.indexWhere((l) => l.id == updatedLocation.id);

          // The leg index is the index of the route segment that *ends* at the current location.
          // The number of legs can be either N or N-1 depending on the start point.
          // The number of locations for the date is N.
          //
          // The leg leading to the location at index `i` in the list of stops
          // is at index `i` if start is current location, or `i-1` if start is another stop.
          // For location #2 (index 1), we want leg #1 (index 0).
          // For location #3 (index 2), we want leg #2 (index 1).
          final legIndex = (trip.startLocationId == 'current_location')
              ? locationIndexInList
              : locationIndexInList - 1;

          if (legIndex < 0 || locationIndexInList == 0)
            return const SizedBox.shrink();
          final previousLocation = routedLocations[locationIndexInList - 1];

          return Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.arrow_upward),
                  label: Text(
                    'From: ${previousLocation.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () {
                    // 1. Dismiss the current detail sheet.
                    Navigator.of(context).pop();

                    // 2. Highlight the corresponding route segment on the map.
                    ref
                        .read(mapUIStateProvider.notifier)
                        .setTappedPolyline('leg_$legIndex');

                    // 3. Collapse the main bottom sheet to its minimum size.
                    parentSheetController?.animateTo(0.12,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut);

                    // 4. Scroll the main list back to the top.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      parentScrollController.animateTo(0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut);
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    foregroundColor:
                        Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildInfoCard(
                      context,
                      Icons.access_time,
                      'Duration',
                      _formatDuration(updatedLocation.travelTimeFromPrevious!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildInfoCard(
                      context,
                      Icons.straighten,
                      'Distance',
                      _formatDistance(updatedLocation.distanceFromPrevious!),
                    ),
                  ),
                ],
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildActionButtons(BuildContext context, WidgetRef ref,
      LocationModel updatedLocation, bool isPastDate) {
    return Row(
      children: [
        Expanded(
            child: ElevatedButton.icon(
          onPressed: isPastDate
              ? null
              : () =>
                  _showEditStayDurationDialog(context, ref, updatedLocation),
          icon: const Icon(Icons.timer_outlined),
          label: const Text('Set Stay'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        )),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onLocationTap?.call(updatedLocation.coordinates);
              parentSheetController?.animateTo(
                0.15, // minChildSize
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                parentScrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              });
            },
            icon: const Icon(Icons.map),
            label: const Text('View on Map'),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
              foregroundColor: Theme.of(context).colorScheme.primary,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }

  void _showEditLocationNameDialog(
      BuildContext context, WidgetRef ref, LocationModel location) {
    final textController = TextEditingController(text: location.name);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.edit,
                  color: Theme.of(context).colorScheme.primary, size: 24),
              const SizedBox(width: 8),
              const Text('Edit Location Name'),
            ],
          ),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Enter new name',
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.primaryColor, width: 2),
              ),
            ),
            onSubmitted: (newName) {
              if (newName.isNotEmpty && newName != location.name) {
                ref
                    .read(tripProvider.notifier)
                    .updateLocationName(location.id, newName);
              }
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final newName = textController.text;
                if (newName.isNotEmpty && newName != location.name) {
                  ref
                      .read(tripProvider.notifier)
                      .updateLocationName(location.id, newName);
                }
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Save',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showEditStayDurationDialog(
      BuildContext context, WidgetRef ref, LocationModel location) {
    final List<Duration> commonDurations = [
      const Duration(minutes: 15),
      const Duration(minutes: 30),
      const Duration(hours: 1),
      const Duration(hours: 2),
      const Duration(hours: 4),
    ];

    final customMinutesController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.timer_outlined,
                  color: Theme.of(context).colorScheme.primary, size: 24),
              const SizedBox(width: 8),
              const Text('Set Stay Duration'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                children: commonDurations.map((duration) {
                  return ActionChip(
                      label: Text(_formatDuration(duration)),
                      backgroundColor: location.stayDuration == duration
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surface,
                      labelStyle: TextStyle(
                        color: location.stayDuration == duration
                            ? Colors.black
                            : Theme.of(context).textTheme.bodyLarge?.color,
                        fontWeight: FontWeight.bold,
                      ),
                      onPressed: () {
                        ref
                            .read(tripProvider.notifier)
                            .updateLocationStayDuration(location.id, duration);
                        Navigator.of(context).pop();
                      });
                }).toList(),
              ),
              const Divider(height: 32),
              Text(
                'Or enter custom duration (minutes):',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Form(
                key: formKey,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: customMinutesController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: 'e.g., 45',
                          suffixText: 'min',
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) return 'Required';
                          if (int.tryParse(value) == null) return 'Invalid';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: () {
                        if (formKey.currentState?.validate() ?? false) {
                          final minutes =
                              int.parse(customMinutesController.text);
                          ref
                              .read(tripProvider.notifier)
                              .updateLocationStayDuration(
                                  location.id, Duration(minutes: minutes));
                          Navigator.of(context).pop();
                        }
                      },
                      child: const Text('Set'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteConfirmationDialog(
      BuildContext context, WidgetRef ref, LocationModel location) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Delete Location'),
          content: Text(
              'Are you sure you want to delete "${location.name}"? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                // Pop both the dialog and the detail sheet
                Navigator.of(dialogContext).pop();
                Navigator.of(context).pop();

                // Perform the deletion
                ref.read(tripProvider.notifier).removeLocation(location.id);

                // Show a confirmation snackbar
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Deleted ${location.name}'),
                    backgroundColor: Theme.of(context).colorScheme.error,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(
      BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[400],
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(
      BuildContext context, IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppTheme.primaryColor, size: 24),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey[400],
                ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
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
