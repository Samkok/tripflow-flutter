import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';

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

          // Travel info (if available)
          if (updatedLocation.travelTimeFromPrevious != null &&
              updatedLocation.distanceFromPrevious != null) ...[
            const Divider(height: 32),
            _buildTravelInfo(context, ref, updatedLocation),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref,
      LocationModel updatedLocation, bool isPastDate) {
    // Check if user has write access to the active trip
    // OPTIMIZATION: Watch only when permission data is ready to avoid unnecessary rebuilds
    // The widget will rebuild ONLY when permission actually changes, not on every event
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.whenOrNull(data: (value) => value) ?? false;

    // Disable editing if past date OR no write access
    final canEdit = !isPastDate && hasWriteAccess;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Stop number and label row
        Row(
          children: [
            CircleAvatar(
              backgroundColor: updatedLocation.isDone
                  ? Colors.green.shade500
                  : Theme.of(context).colorScheme.primary,
              radius: 24,
              child: updatedLocation.isDone
                  ? const Icon(Icons.check, color: Colors.white, size: 24)
                  : Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  updatedLocation.isDone ? 'Done' : 'Stop $number',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: updatedLocation.isDone
                            ? Colors.green.shade500
                            : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                Text(
                  'Planned Stay: ${_formatDuration(updatedLocation.stayDuration)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[500],
                      ),
                ),
              ],
            ),
            const Spacer(),
            // Delete button
            GestureDetector(
              onTap: hasWriteAccess
                  ? () => _showDeleteConfirmationDialog(context, ref, updatedLocation)
                  : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hasWriteAccess ? Colors.red[600] : Colors.grey[400],
                ),
                child: const Icon(Icons.delete_outline, color: Colors.white, size: 22),
              ),
            ),
            const SizedBox(width: 8),
            // Mark as done button
            GestureDetector(
              onTap: hasWriteAccess
                  ? () {
                      if (updatedLocation.isDone) {
                        ref
                            .read(tripProvider.notifier)
                            .unmarkLocationsAsDone({updatedLocation.id});
                      } else {
                        ref
                            .read(tripProvider.notifier)
                            .markLocationsAsDone({updatedLocation.id});
                      }
                    }
                  : null,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: !hasWriteAccess
                      ? Colors.grey[400]
                      : updatedLocation.isDone
                          ? Colors.grey[700]
                          : Colors.green[600],
                ),
                child: Icon(
                  updatedLocation.isDone ? Icons.close : Icons.check,
                  color: Colors.white,
                  size: 22,
                ),
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

        // Action buttons — 2×2 grid
        Row(
          children: [
            // Date
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(Icons.calendar_today_outlined, size: 18,
                    color: canEdit ? Theme.of(context).colorScheme.primary : Colors.grey),
                label: const Text('Date'),
                onPressed: canEdit
                    ? () async {
                        final datesWithLocations = ref.read(datesWithLocationsProvider);
                        final now = DateTime.now();
                        final newDate = await DatePickerUtils.showCustomDatePicker(
                          context: context,
                          initialDate: updatedLocation.scheduledDate ?? now,
                          firstDate: DateTime(now.year, now.month, now.day),
                          lastDate: DateTime(now.year + 5),
                          highlightedDates: datesWithLocations,
                        );
                        if (newDate != null) {
                          ref.read(tripProvider.notifier).updateLocationScheduledDate(
                              updatedLocation.id,
                              DateTime(newDate.year, newDate.month, newDate.day));
                        }
                      }
                    : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  side: BorderSide(
                    color: canEdit
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
                        : Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Edit
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(Icons.edit_outlined, size: 18,
                    color: canEdit ? Theme.of(context).colorScheme.primary : Colors.grey),
                label: const Text('Edit'),
                onPressed: canEdit
                    ? () => _showEditLocationNameDialog(context, ref, updatedLocation)
                    : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  side: BorderSide(
                    color: canEdit
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
                        : Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Set Stay
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(Icons.timer_outlined, size: 18,
                    color: canEdit ? Theme.of(context).colorScheme.primary : Colors.grey),
                label: const Text('Set Stay'),
                onPressed: canEdit
                    ? () => _showEditStayDurationDialog(context, ref, updatedLocation)
                    : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  side: BorderSide(
                    color: canEdit
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
                        : Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Google Map
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(Icons.map_outlined, size: 18,
                    color: Theme.of(context).colorScheme.primary),
                label: const Text('Google Map'),
                onPressed: () => _openGoogleMaps(updatedLocation.coordinates),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
              ),
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

          if (legIndex < 0 || locationIndexInList == 0) {
            return const SizedBox.shrink();
          }
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

  Future<void> _openGoogleMaps(LatLng coordinates) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=${coordinates.latitude},${coordinates.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
            maxLength: 30,
            decoration: InputDecoration(
              hintText: 'Enter new name',
              counterText: '',
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
    final List<Duration> presets = [
      const Duration(minutes: 15),
      const Duration(minutes: 30),
      const Duration(hours: 1),
      const Duration(hours: 2),
      const Duration(hours: 3),
      const Duration(hours: 4),
    ];

    final customController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocalState) {
          Duration selected = location.stayDuration;

          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.timer_outlined,
                      color: Theme.of(context).colorScheme.primary, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Set Stay Duration'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  'Quick select',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.grey[500],
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 10),
                ...[
                  [presets[0], presets[1], presets[2]],
                  [presets[3], presets[4], presets[5]],
                ].map((rowPresets) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: rowPresets
                        .expand((duration) {
                          final isSelected = selected == duration;
                          return [
                            Expanded(
                              child: InkWell(
                                onTap: () {
                                  ref
                                      .read(tripProvider.notifier)
                                      .updateLocationStayDuration(
                                          location.id, duration);
                                  Navigator.of(ctx).pop();
                                },
                                borderRadius: BorderRadius.circular(10),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isSelected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primary
                                          : Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      _formatDuration(duration),
                                      style: TextStyle(
                                        color: isSelected
                                            ? Colors.black
                                            : Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.color,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (duration != rowPresets.last)
                              const SizedBox(width: 8),
                          ];
                        })
                        .toList(),
                  ),
                )),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 14),
                Text(
                  'Custom duration',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.grey[500],
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: customController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: 'e.g. 45',
                    suffixText: 'min',
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          final minutes =
                              int.tryParse(customController.text);
                          if (minutes != null && minutes > 0) {
                            ref
                                .read(tripProvider.notifier)
                                .updateLocationStayDuration(
                                    location.id,
                                    Duration(minutes: minutes));
                            Navigator.of(ctx).pop();
                          }
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Set',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
            actions: const [],
          );
        },
      ),
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

                // Perform the deletion directly via repository (bypasses
                // tripProvider's access-check which is tied to the active map
                // trip, not the trip being viewed in trip details).
                ref.read(locationRepositoryProvider).deleteLocation(location.id);

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
