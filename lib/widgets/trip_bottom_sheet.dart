import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../utils/date_picker_utils.dart';
import '../core/theme.dart';
import 'package:url_launcher/url_launcher.dart';
import 'optimized_location_card.dart';
import '../services/csv_service.dart';

class TripBottomSheet extends ConsumerWidget {
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;
  final VoidCallback? onShowZoneSettings;
  final int? highlightedLocationIndex;

  TripBottomSheet({
    super.key,
    this.sheetController,
    this.onLocationTap,
    this.onShowZoneSettings,
    this.highlightedLocationIndex,
  });

  // A simple provider to signal when the "View Route" button is tapped for a historical trip.
  static final viewHistoricalRouteProvider =
      StateProvider<bool>((ref) => false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // OPTIMIZATION: Watch only specific fields to prevent rebuilds during drag
    // Don't watch entire tripState here since it rebuilds on every state change
    final hasPinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.isNotEmpty));

    return DraggableScrollableSheet(
      controller: sheetController,
      // Define snap points for a magnetic feel
      snap: true,
      snapSizes: const [0.23, 0.85],
      initialChildSize: 0.23, // Start in the collapsed state
      minChildSize: 0.23, // Collapsed state shows only the header
      maxChildSize: 0.85, // Expanded state leaves search bar visible
      builder: (context, scrollController) {
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
              // Drag handle
              GestureDetector(
                onTap: () {
                  // Intelligently toggle between the collapsed and expanded snap points
                  if (sheetController != null) {
                    final currentSize = sheetController!.size;
                    final targetSize = currentSize < 0.5 ? 0.85 : 0.12;
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
                child: Container(
                  margin: const EdgeInsets.only(top: 12),
                  height: 4,
                  width: 50,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Scrollable Content - Everything is now scrollable
              Expanded(
                child: ListView(
                  controller: scrollController,
                  shrinkWrap: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    // Header - OPTIMIZATION: Use separate widgets to minimize rebuilds
                    Consumer(builder: (context, ref, _) {
                      final isSelectionMode =
                          ref.watch(isSelectionModeProvider);
                      return isSelectionMode
                          ? _buildSelectionModeHeader(context, ref)
                          : _buildDefaultHeader(context, ref);
                    }),

                    // History Banner
                    Consumer(builder: (context, ref, _) {
                      final selectedDate = ref.watch(selectedDateProvider);
                      final now = DateTime.now();
                      final today = DateTime(now.year, now.month, now.day);
                      final isPastDate = selectedDate.isBefore(today);

                      if (isPastDate) {
                        return _buildHistoryBanner(context);
                      } else {
                        return const SizedBox.shrink();
                      }
                    }),

                    // Trip Summary - OPTIMIZATION: Build only if there are locations
                    if (hasPinnedLocations) ...[
                      Consumer(builder: (context, ref, _) {
                        final locationsForDate =
                            ref.watch(locationsForSelectedDateProvider);
                        final totalTravelTime = ref.watch(
                            tripProvider.select((s) => s.totalTravelTime));
                        final totalDistance = ref
                            .watch(tripProvider.select((s) => s.totalDistance));
                        return _buildTripSummary(context, totalTravelTime,
                            totalDistance, locationsForDate.length);
                      }),
                    ],

                    // Date Selector - Always visible to allow date switching
                    _buildDatePicker(context, ref),

                    // Locations List
                    Consumer(builder: (context, ref, _) {
                      final locationsForDate =
                          ref.watch(locationsForSelectedDateProvider);
                      return _buildLocationsList(
                          context, ref, locationsForDate, scrollController);
                    }),

                    const SizedBox(height: 75),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Provider to clear the optimized route when the date changes.
  // This prevents showing an old route on a new day's location list.
  final routeClearerProvider = Provider<void>((ref) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      // When the date changes, clear the old route from the state.
      ref.read(tripProvider.notifier).clearOptimizedRoute();
    });
  });

  Widget _buildDefaultHeader(BuildContext context, WidgetRef ref) {
    // OPTIMIZATION: Read values only when needed, not watched in parent
    final hasPinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.isNotEmpty));
    final hasOptimizedRoute =
        ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Trip Plan',
          style: Theme.of(context).textTheme.headlineMedium,
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
            if (hasPinnedLocations) ...[
              Container(
                height: 24,
                width: 1,
                color: Theme.of(context).dividerColor,
                margin: const EdgeInsets.symmetric(horizontal: 4),
              ),
              Consumer(builder: (context, ref, _) {
                final isGenerating = ref.watch(isGeneratingRouteProvider);
                return IconButton(
                  icon: const Icon(Icons.route),
                  onPressed: isGenerating
                      ? null
                      : () {
                          ref.read(locationsForSelectedDateProvider);
                          _showChooseStartPointDialog(context, ref,
                              isReoptimizing: hasOptimizedRoute);
                        },
                  color: Theme.of(context).colorScheme.primary,
                  tooltip: 'Optimize route',
                );
              }),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionModeHeader(BuildContext context, WidgetRef ref) {
    final selectedCount =
        ref.watch(selectedLocationsProvider.select((s) => s.length));

    // FIX: Use only the locations for the selected date to determine the total count and which IDs to select.
    final locationsForDate = ref.watch(locationsForSelectedDateProvider);
    final totalCountForDate = locationsForDate.length;
    final allSelectedOnDate =
        selectedCount == totalCountForDate && totalCountForDate > 0;

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
            // Select All / Deselect All Button
            if (totalCountForDate > 0) ...[
              Text(allSelectedOnDate ? 'Deselect All' : 'Select All',
                  style: Theme.of(context).textTheme.bodyMedium),
              Checkbox(
                value: allSelectedOnDate,
                onChanged: (bool? value) {
                  final selectedNotifier =
                      ref.read(selectedLocationsProvider.notifier);
                  if (value == true) {
                    // Select all for the current date
                    final idsForDate =
                        locationsForDate.map((l) => l.id).toSet();
                    selectedNotifier.state = idsForDate;
                  } else {
                    // Deselect all
                    selectedNotifier.state = {};
                  }
                },
              ),
            ],
            if (selectedCount > 0) ...[
              PopupMenuButton<String>(
                onSelected: (value) {
                  // Check write access for all write operations
                  if (!hasWriteAccess && value != 'copy') {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('You don\'t have permission to modify locations in this trip.'),
                        backgroundColor: Colors.orange,
                      ),
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
                    // Only allow skipping on current/future dates with write access
                    _showSkipConfirmationDialog(context, ref);
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
                          style: TextStyle(
                              color: canEdit ? null : Colors.grey)),
                    ),
                  ),
                  PopupMenuItem<String>(
                    // Uses theme colors
                    value: 'skip',
                    enabled: canEdit, // Disable skipping for past dates or read-only
                    child: ListTile(
                      leading: Icon(
                        Icons.remove_circle_outline,
                        color: canEdit
                            ? Theme.of(context).textTheme.bodyMedium?.color
                            : Colors.grey,
                      ),
                      title: Text('Skip',
                          style: TextStyle(
                              color: canEdit ? null : Colors.grey)),
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
                final initialDateForPicker = selectedDate.isBefore(firstDate)
                    ? firstDate
                    : selectedDate;

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

  Widget _buildTripSummary(BuildContext context, Duration totalTravelTime,
      double totalDistance, int totalStopsForDate) {
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
              // Google Maps navigation button - only show if there are 2+ locations
              if (totalStopsForDate >= 2)
                Consumer(
                  builder: (context, ref, _) {
                    return IconButton.filledTonal(
                      onPressed: () => _openGoogleMaps(context, ref),
                      icon: const Icon(Icons.directions, size: 20),
                      tooltip: 'Open in Google Maps',
                      style: IconButton.styleFrom(
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        padding: const EdgeInsets.all(8),
                      ),
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
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _summaryItem(
                context,
                'ETA',
                DateFormat('h:mm a').format(estimatedArrival),
              ),
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

  // Opens Google Maps with directions from the first to last location with waypoints
  Future<void> _openGoogleMaps(BuildContext context, WidgetRef ref) async {
    try {
      final locations = ref.read(locationsForSelectedDateProvider);

      if (locations.length < 2) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Need at least 2 locations to open directions'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final firstLocation = locations.first;
      final lastLocation = locations.last;

      // BUGFIX: Build proper Google Maps URL with all waypoints
      // Using google.navigation:// scheme for better compatibility with Google Maps app
      final startLat = firstLocation.coordinates.latitude;
      final startLng = firstLocation.coordinates.longitude;
      final endLat = lastLocation.coordinates.latitude;
      final endLng = lastLocation.coordinates.longitude;

      // Build waypoints string if more than 2 locations
      String waypointsString = '';
      if (locations.length > 2) {
        // Add intermediate locations as waypoints
        final waypoints = locations.sublist(1, locations.length - 1);
        waypointsString = waypoints
            .map((loc) => '${loc.coordinates.latitude},${loc.coordinates.longitude}')
            .join('|');
      }

      // BUGFIX: Use proper URL encoding and format for Google Maps
      // Try multiple URL formats for better compatibility
      Uri url;
      
      if (waypointsString.isNotEmpty) {
        // Format with waypoints for web
        url = Uri.https(
          'www.google.com',
          '/maps/dir/',
          {
            'api': '1',
            'origin': '$startLat,$startLng',
            'destination': '$endLat,$endLng',
            'waypoints': waypointsString,
            'travelmode': 'driving',
          },
        );
      } else {
        // Format without waypoints
        url = Uri.https(
          'www.google.com',
          '/maps/dir/',
          {
            'api': '1',
            'origin': '$startLat,$startLng',
            'destination': '$endLat,$endLng',
            'travelmode': 'driving',
          },
        );
      }

      // Try to launch the URL
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // Fallback: Try alternative format with geo: scheme
        final fallbackUrl = Uri.parse(
          'geo:$startLat,$startLng?q=$endLat,$endLng(Route End)',
        );
        
        if (await canLaunchUrl(fallbackUrl)) {
          await launchUrl(fallbackUrl, mode: LaunchMode.externalApplication);
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Google Maps app not found. Please install it.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } catch (e) {
      print('Error opening Google Maps: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open Google Maps: $e'),
            backgroundColor: Colors.red,
          ),
        );
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

  Widget _buildLocationsList(BuildContext context, WidgetRef ref,
      List<LocationModel> locations, ScrollController scrollController) {
    if (locations.isEmpty) {
      return Container(
        padding:
            const EdgeInsets.only(left: 32, right: 32, bottom: 32, top: 16),
        child: Column(
          children: [
            Icon(
              Icons.map_outlined,
              size: 64, // Uses theme colors
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
            const SizedBox(height: 16),
            Text(
              'No locations for this date', // Uses theme colors
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Select another date or add new locations.', // Uses theme colors
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final normalLocations = locations.where((l) => !l.isSkipped).toList();
    final skippedLocations = locations.where((l) => l.isSkipped).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Normal (upcoming) locations - OPTIMIZATION: Use ListView.builder with keys
        if (normalLocations.isNotEmpty)
          ListView.builder(
            // OPTIMIZATION: Use ListView.builder instead of ListView.separated for better performance
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: normalLocations.length,
            itemBuilder: (context, index) {
              final location = normalLocations[index];
              // OPTIMIZATION: Add unique keys to prevent unnecessary rebuilds
              return Column(
                key: ValueKey(location.id),
                children: [
                  OptimizedLocationCard(
                    location: location,
                    number: index + 1,
                    scrollController: scrollController,
                    sheetController: sheetController,
                    onLocationTap: onLocationTap,
                  ),
                  if (index < normalLocations.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color:
                          Theme.of(context).dividerColor.withValues(alpha: 0.1),
                      indent: 20,
                      endIndent: 20,
                    ),
                ],
              );
            },
          ),

        // Skipped locations section
        if (skippedLocations.isNotEmpty) ...[
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
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: skippedLocations.length,
            itemBuilder: (context, index) {
              final location = skippedLocations[index];
              // OPTIMIZATION: Add unique keys to prevent unnecessary rebuilds
              return OptimizedLocationCard(
                key: ValueKey('skipped_${location.id}'),
                location: location,
                number: -1,
                scrollController: scrollController,
                sheetController: sheetController,
                onLocationTap: onLocationTap,
              );
            },
          ),
        ],

        // Optimize button
        Consumer(builder: (context, ref, _) {
          final isGenerating = ref.watch(isGeneratingRouteProvider);
          final hasRoute = ref
              .watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
          final selectedDate = ref.watch(selectedDateProvider);

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final isPastDate = selectedDate.isBefore(today);

          final isViewingHistory = isPastDate && hasRoute;

          String buttonText;
          VoidCallback? onPressedAction;

          if (isGenerating) {
            buttonText = 'Optimizing...';
            onPressedAction = null;
          } else if (isViewingHistory) {
            buttonText = 'View Route';
            onPressedAction = () {
              // Simply collapse the sheet to view the route on the map
              sheetController?.animateTo(
                0.12, // minChildSize
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
              // Signal that we want to zoom to the historical route.
              ref.read(viewHistoricalRouteProvider.notifier).state = true;
            };
          } else {
            buttonText = hasRoute ? 'Re-optimize Route' : 'Optimize Route';
            onPressedAction = () => _showChooseStartPointDialog(context, ref,
                isReoptimizing: hasRoute);
          }

          return SizedBox(
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
                  : Icon(isViewingHistory
                      ? Icons.visibility_outlined
                      : Icons.route),
              label: Text(buttonText),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        Consumer(builder: (context, ref, _) {
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
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  'Please restart the app to enable CSV download.'),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Failed to download CSV. Please restart the app.'),
                              backgroundColor: Colors.red,
                            ),
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
        }),
      ],
    );
  }

  void _showChooseStartPointDialog(BuildContext context, WidgetRef ref,
      {required bool isReoptimizing}) {
    final tripState = ref.read(tripProvider);
    // Always read the latest, most correct list of locations for the date from the provider.
    final locationsForDate = ref.read(locationsForSelectedDateProvider);

    String? selectedStartId = tripState.currentLocation != null
        ? 'current_location'
        : (locationsForDate.isNotEmpty ? locationsForDate.first.id : null);

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              // Uses theme colors
              backgroundColor: Theme.of(context).cardColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('Choose Starting Point'),
              content: SizedBox(
                // Uses theme colors
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (tripState.currentLocation != null)
                      RadioListTile<String>(
                        title: const Text('My Current Location'),
                        value: 'current_location',
                        groupValue: selectedStartId,
                        onChanged: (value) =>
                            setDialogState(() => selectedStartId = value),
                        activeColor: Theme.of(context).colorScheme.primary,
                      ),
                    ...locationsForDate.map((location) {
                      return RadioListTile<String>(
                        title: Text(location.name,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(location.address,
                            overflow: TextOverflow.ellipsis, maxLines: 1),
                        value: location.id,
                        groupValue: selectedStartId,
                        onChanged: (value) =>
                            setDialogState(() => selectedStartId = value),
                        activeColor: Theme.of(context).colorScheme.primary,
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel',
                      style: TextStyle(
                          color:
                              Theme.of(context).textTheme.bodyMedium?.color)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (selectedStartId != null) {
                      final selectedDate = ref.read(selectedDateProvider);
                      ref.read(tripProvider.notifier).generateOptimizedRoute(
                          startLocationId: selectedStartId,
                          selectedDate: selectedDate);
                    }
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    isReoptimizing ? 'Re-optimize' : 'Optimize',
                    style: const TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
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
                ref
                    .read(tripProvider.notifier)
                    .removeMultipleLocations(selectedIds);
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
      final selectedIds = ref.read(selectedLocationsProvider);
      await ref
          .read(tripProvider.notifier)
          .copyMultipleLocationsToDate(selectedIds, newDate);

      // Exit selection mode and clear selections
      ref.read(isSelectionModeProvider.notifier).state = false;
      ref.read(selectedLocationsProvider.notifier).state = {};

      // Switch the view to the new date to show the copied items
      ref.read(selectedDateProvider.notifier).state = newDate;
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
      final selectedIds = ref.read(selectedLocationsProvider);
      await ref
          .read(tripProvider.notifier)
          .updateMultipleLocationsScheduledDate(selectedIds, newDate);

      // Exit selection mode and clear selections
      ref.read(isSelectionModeProvider.notifier).state = false;
      ref.read(selectedLocationsProvider.notifier).state = {};

      // Optionally, switch the view to the new date
      ref.read(selectedDateProvider.notifier).state = newDate;
    }
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
