import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tripflow/models/location_model.dart';
import 'package:tripflow/providers/settings_provider.dart';
import 'package:tripflow/providers/map_ui_state_provider.dart';
import '../providers/trip_provider.dart';
import 'package:tripflow/widgets/location_detail_sheet.dart';
import '../utils/date_picker_utils.dart';
import '../core/theme.dart';

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
  static final viewHistoricalRouteProvider = StateProvider<bool>((ref) => false);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripState = ref.watch(tripProvider);

    return DraggableScrollableSheet(
      controller: sheetController,
      // Define snap points for a magnetic feel
      snap: true,
      snapSizes: const [0.12, 0.85],
      initialChildSize: 0.12, // Start in the collapsed state
      minChildSize: 0.12,      // Collapsed state shows only the header
      maxChildSize: 0.85,      // Expanded state leaves search bar visible
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration( // Uses theme colors
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
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
                    // Header
                    Consumer(builder: (context, ref, _) {
                      final isSelectionMode = ref.watch(isSelectionModeProvider);
                      return isSelectionMode
                          ? _buildSelectionModeHeader(context, ref)
                          : _buildDefaultHeader(context, ref, tripState);
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

                    const SizedBox(height: 16),

                    // Trip Summary
                    if (tripState.pinnedLocations.isNotEmpty) ...[
                      Consumer(builder: (context, ref, _) {
                        final locationsForDate = ref.watch(locationsForSelectedDateProvider);
                        return _buildTripSummary(context, tripState, locationsForDate.length);
                      }),
                      const SizedBox(height: 16),
                    ],

                    // Date Selector - Moved here from the header
                    if (tripState.pinnedLocations.isNotEmpty) ...[
                      _buildDatePicker(context, ref),
                    ],


                    // Locations List
                    Consumer(builder: (context, ref, _) {
                      final locationsForDate = ref.watch(locationsForSelectedDateProvider);
                      return _buildLocationsList(context, ref, locationsForDate, scrollController);
                    }),
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

  Widget _buildDefaultHeader(BuildContext context, WidgetRef ref, TripState tripState) {
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
            Consumer(
              builder: (context, ref, child) {
                final showNames = ref.watch(showMarkerNamesProvider);
                return IconButton(
                  icon: Icon(showNames ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: () => ref.read(showMarkerNamesProvider.notifier).state = !showNames,
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  tooltip: showNames ? 'Hide place names' : 'Show place names',
                );
              },
            ),
            if (tripState.pinnedLocations.isNotEmpty) ...[
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
                          final locationsForDate = ref.read(locationsForSelectedDateProvider);
                          _showChooseStartPointDialog(context, ref, isReoptimizing: tripState.optimizedRoute.isNotEmpty);
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
    final selectedCount = ref.watch(selectedLocationsProvider.select((s) => s.length));
    
    // FIX: Use only the locations for the selected date to determine the total count and which IDs to select.
    final locationsForDate = ref.watch(locationsForSelectedDateProvider);
    final totalCountForDate = locationsForDate.length;
    final allSelectedOnDate = selectedCount == totalCountForDate && totalCountForDate > 0;

    // Determine if we are on a past date to disable editing actions.
    final selectedDate = ref.watch(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPastDate = selectedDate.isBefore(today);

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
              Text(allSelectedOnDate ? 'Deselect All' : 'Select All', style: Theme.of(context).textTheme.bodyMedium),
              Checkbox(
                value: allSelectedOnDate,
                onChanged: (bool? value) {
                  final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
                  if (value == true) {
                    // Select all for the current date
                    final idsForDate = locationsForDate.map((l) => l.id).toSet();
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
                  if (value == 'delete') {
                    _showMultiDeleteConfirmationDialog(context, ref);
                  } else if (value == 'move') {
                    _showMoveLocationsDialog(context, ref);
                  } else if (value == 'copy') {
                    _showCopyLocationsDialog(context, ref);
                  } else if (value == 'skip' && !isPastDate) { // Only allow skipping on current/future dates
                    // Add skip action
                    _showSkipConfirmationDialog(context, ref);
                  }
                },
                icon: Icon(Icons.more_vert, color: Theme.of(context).textTheme.bodyMedium?.color),
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'delete',
                    enabled: !isPastDate,
                    child: ListTile(
                      leading: Icon(
                        Icons.delete_outline,
                        color: isPastDate ? Colors.grey : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        'Delete',
                        style: TextStyle(color: isPastDate ? Colors.grey : Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'move',
                    enabled: !isPastDate,
                    child: ListTile(
                      leading: Icon(Icons.calendar_today_outlined, color: isPastDate ? Colors.grey : null),
                      title: Text('Move to...', style: TextStyle(color: isPastDate ? Colors.grey : null)),
                    ),
                  ),
                  PopupMenuItem<String>( // Uses theme colors
                    value: 'skip',
                    enabled: !isPastDate, // Disable skipping for past dates
                    child: ListTile(
                      leading: Icon(
                        Icons.remove_circle_outline,
                        color: isPastDate ? Colors.grey : Theme.of(context).textTheme.bodyMedium?.color,
                      ),
                      title: Text('Skip', style: TextStyle(color: isPastDate ? Colors.grey : null)),
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
      final isToday = selectedDate.isAtSameMomentAs(
          DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));

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
                final newDate = await DatePickerUtils.showCustomDatePicker(
                  context: context,
                  initialDate: selectedDate,
                  firstDate: firstDate,
                  lastDate: DateTime.now().add(const Duration(days: 365 * 5)), // 5 years in the future
                  highlightedDates: highlightedDates,
                );

                if (newDate != null) {
                  ref.read(selectedDateProvider.notifier).state = newDate;
                }
              },
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(
                isToday
                    ? 'Today'
                    : DateFormat.yMMMd().format(selectedDate),
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
        color: Theme.of(context).colorScheme.secondary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.secondary.withOpacity(0.5),
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
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.secondary, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildTripSummary(BuildContext context, TripState tripState, int totalStopsForDate) {
    final estimatedArrival = DateTime.now().add(tripState.totalTravelTime);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
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
                _formatDuration(tripState.totalTravelTime),
              ),
              _summaryItem(
                context,
                'Distance',
                _formatDistance(tripState.totalDistance),
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

  Widget _buildLocationsList(
      BuildContext context, WidgetRef ref, List<LocationModel> locations, ScrollController scrollController) {
    if (locations.isEmpty) {
      return Container(
        padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32, top: 16),
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
        // Normal (upcoming) locations
        if (normalLocations.isNotEmpty)
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: normalLocations.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              thickness: 1,
              color: Theme.of(context).dividerColor.withOpacity(0.1),
              indent: 20,
              endIndent: 20,
            ),
            itemBuilder: (context, index) {
              final location = normalLocations[index];
              return _buildLocationCard(context, ref, location, index + 1, scrollController);
            },
          ),

        // Skipped locations section
        if (skippedLocations.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 4.0),
            child: Row(
              children: [
                Icon(Icons.remove_circle_outline, color: Colors.grey[600], size: 20),
                const SizedBox(width: 8),
                Text(
                  'Skipped Locations',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey[600]),
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
              // Pass the original index from the full list to maintain correct highlighting and actions
              return _buildLocationCard(context, ref, location, -1, scrollController);
            },
          ),
        ],

        const SizedBox(height: 24),
        // Optimize button
        Consumer(builder: (context, ref, _) {
          final isGenerating = ref.watch(isGeneratingRouteProvider);
          final tripState = ref.watch(tripProvider);
          final selectedDate = ref.watch(selectedDateProvider);

          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final isPastDate = selectedDate.isBefore(today);

          final hasRoute = tripState.optimizedRoute.isNotEmpty;
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
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : Icon(isViewingHistory ? Icons.visibility_outlined : Icons.route),
              label: Text(buttonText),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildLocationCard(BuildContext context, WidgetRef ref, LocationModel location,
      int number,
      ScrollController scrollController) {
    final tripState = ref.watch(tripProvider);    
    final index = tripState.pinnedLocations.indexOf(location);
    final isHighlighted = ref.watch(highlightedLocationIndexProvider) == index;
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final isSelected = ref.watch(selectedLocationsProvider.select((s) => s.contains(location.id)));
    final isSkipped = location.isSkipped;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withOpacity(0.25)
            : (isHighlighted
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)                
                : Theme.of(context).cardColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHighlighted
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],        
        
      ),
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: ListTile(
        onTap: () {
          if (isSelectionMode) {
            final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
            if (isSelected) {
              selectedNotifier.update((state) => state.difference({location.id}));
            } else {
              selectedNotifier.update((state) => state.union({location.id}));
            }
          } else {
            // Show detailed location info modal
            showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (modalContext) => LocationDetailSheet(
                location: location,
                number: number,
                parentScrollController: scrollController,
                parentSheetController: sheetController,
                onLocationTap: onLocationTap,
              ),
            );
          }
        },
        onLongPress: () {
          if (!isSelectionMode) {
            ref.read(isSelectionModeProvider.notifier).state = true;
            ref.read(selectedLocationsProvider.notifier).update((state) => state.union({location.id}));
          }
        },
        leading: CircleAvatar(
          backgroundColor: isSkipped ? Colors.grey : Theme.of(context).colorScheme.primary,
          child: Text(
            isSkipped ? '-' : '$number',
            style: const TextStyle(
              color: Colors.black, // This is the color for the number inside the circle
              fontWeight: FontWeight.bold,
            ), // Uses theme colors
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    location.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1, // Uses theme colors
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (location.travelTimeFromPrevious != null && location.distanceFromPrevious != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 14, // Uses theme colors
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDuration(location.travelTimeFromPrevious!),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith( // Uses theme colors
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.straighten,
                    size: 14, // Uses theme colors
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDistance(location.distanceFromPrevious!),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith( // Uses theme colors
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            location.address,
            style: Theme.of(context).textTheme.bodyMedium, // Uses theme colors
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: isSelectionMode
            ? Checkbox( // Checkbox for multi-selection mode
              value: isSelected,
              onChanged: (bool? value) {
                final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
                if (value == true) {
                  selectedNotifier.update((state) => state.union({location.id}));
                } else {
                  selectedNotifier.update((state) => state.difference({location.id}));
                }
              },
            )
            : PopupMenuButton<String>( // "More" menu for normal mode
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  // Temporarily add the single location to the selection provider to reuse dialogs
                  final selectedIds = {location.id};

                  if (value == 'delete') {
                    ref.read(selectedLocationsProvider.notifier).state = selectedIds;
                    _showMultiDeleteConfirmationDialog(context, ref);
                  } else if (value == 'skip') {
                    ref.read(tripProvider.notifier).skipMultipleLocations(selectedIds);
                  } else if (value == 'unskip') {
                    ref.read(tripProvider.notifier).unskipMultipleLocations(selectedIds);
                  }

                  // Clear selection after action dialog is shown
                  // Future.delayed(const Duration(milliseconds: 100), () {
                  //   ref.read(selectedLocationsProvider.notifier).state = {};
                  // });
                },
                itemBuilder: (context) {
                  final isPastDate = ref.read(selectedDateProvider).isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
                  return [
                    if (location.isSkipped)
                      PopupMenuItem<String>(
                        value: 'unskip',
                        enabled: !isPastDate,
                        child: const ListTile(leading: Icon(Icons.add_circle_outline), title: Text('Un-skip')),
                      )
                    else
                      PopupMenuItem<String>(
                        value: 'skip',
                        enabled: !isPastDate,
                        child: const ListTile(leading: Icon(Icons.remove_circle_outline), title: Text('Skip')),
                      ),
                    PopupMenuItem<String>(
                      value: 'move',
                      enabled: !isPastDate,
                      child: const ListTile(leading: Icon(Icons.calendar_today_outlined), title: Text('Move to...')),
                    ),
                    const PopupMenuItem<String>(
                      value: 'copy',
                      child: ListTile(leading: Icon(Icons.copy), title: Text('Copy to...')),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(value: 'delete', enabled: !isPastDate, child: const ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Delete', style: TextStyle(color: Colors.red)))),
                  ];
                },
              ),
      ),
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
            return AlertDialog( // Uses theme colors
              backgroundColor: Theme.of(context).cardColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),              
              title: const Text('Choose Starting Point'),
              content: SizedBox( // Uses theme colors
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (tripState.currentLocation != null)
                      RadioListTile<String>(
                        title: const Text('My Current Location'),
                        value: 'current_location',
                        groupValue: selectedStartId,
                        onChanged: (value) => setDialogState(() => selectedStartId = value),
                        activeColor: Theme.of(context).colorScheme.primary,
                      ),
                    ...locationsForDate.map((location) {
                      return RadioListTile<String>(
                        title: Text(location.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(location.address, overflow: TextOverflow.ellipsis, maxLines: 1),
                        value: location.id,
                        groupValue: selectedStartId,
                        onChanged: (value) => setDialogState(() => selectedStartId = value),
                        activeColor: Theme.of(context).colorScheme.primary,
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel', style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color)),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (selectedStartId != null) {
                      final selectedDate = ref.read(selectedDateProvider);
                      ref.read(tripProvider.notifier).generateOptimizedRoute(
                          startLocationId: selectedStartId, selectedDate: selectedDate);
                    }
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    isReoptimizing ? 'Re-optimize' : 'Optimize',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDeleteConfirmationDialog(BuildContext context, WidgetRef ref, LocationModel location) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Delete Location'),
          content: Text('Are you sure you want to delete "${location.name}"?'),
          actionsPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await ref.read(tripProvider.notifier).removeLocation(location.id);

                    // After deletion, if there are still locations, show the re-optimize dialog.
                    if (ref.read(tripProvider).pinnedLocations.isNotEmpty) {
                      final locationsForDate = ref.read(locationsForSelectedDateProvider);
                      _showChooseStartPointDialog(context, ref, isReoptimizing: true);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text(
                    'Delete & Re-optimize',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ),
          ],
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Delete $selectedCount Locations?'),
          content: const Text('Are you sure you want to permanently delete the selected locations? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel', style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final selectedIds = ref.read(selectedLocationsProvider);
                ref.read(tripProvider.notifier).removeMultipleLocations(selectedIds);
                // Exit selection mode after action
                ref.read(isSelectionModeProvider.notifier).state = false;
                ref.read(selectedLocationsProvider.notifier).state = {};
                Navigator.of(dialogContext).pop(); // Close the dialog
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  void _showEditLocationNameDialog(BuildContext context, WidgetRef ref, LocationModel location) {
    final textController = TextEditingController(text: location.name);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog( // Uses theme colors
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.edit, color: Theme.of(context).colorScheme.primary, size: 24),
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
                borderRadius: BorderRadius.circular(12), // Uses theme colors
                borderSide: BorderSide(color: AppTheme.primaryColor, width: 2),
              ),
            ),
            onSubmitted: (newName) {
              if (newName.isNotEmpty && newName != location.name) {
                ref.read(tripProvider.notifier).updateLocationName(location.id, newName);
              }
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final newName = textController.text;
                if (newName.isNotEmpty && newName != location.name) {
                  ref.read(tripProvider.notifier).updateLocationName(location.id, newName);
                }
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      await ref.read(tripProvider.notifier).copyMultipleLocationsToDate(selectedIds, newDate);

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
      await ref.read(tripProvider.notifier).updateMultipleLocationsScheduledDate(selectedIds, newDate);

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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Skip $selectedCount Locations?'),
          content: const Text('Are you sure you want to skip the selected locations? They will be excluded from the route but remain on the map.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel', style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                final selectedIds = ref.read(selectedLocationsProvider);
                ref.read(tripProvider.notifier).skipMultipleLocations(selectedIds);
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
