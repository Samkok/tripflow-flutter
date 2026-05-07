import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../utils/date_picker_utils.dart';
import 'timing_warnings_sheet.dart';
import '../utils/external_app_links.dart';
import '../utils/trip_date_validator.dart';
import '../core/theme.dart';
import 'optimized_location_card.dart';
import '../services/csv_service.dart';

class TripBottomSheet extends ConsumerStatefulWidget {
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;
  final VoidCallback? onShowZoneSettings;
  final int? highlightedLocationIndex;

  const TripBottomSheet({
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
  ConsumerState<TripBottomSheet> createState() => _TripBottomSheetState();
}

class _TripBottomSheetState extends ConsumerState<TripBottomSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Provider to clear the optimized route when the date changes.
  // This prevents showing an old route on a new day's location list.
  final routeClearerProvider = Provider<void>((ref) {
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      // When the date changes, clear the old route from the state.
      ref.read(tripProvider.notifier).clearOptimizedRoute();
    });
  });

  DraggableScrollableController? get sheetController => widget.sheetController;
  Function(LatLng)? get onLocationTap => widget.onLocationTap;
  VoidCallback? get onShowZoneSettings => widget.onShowZoneSettings;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // OPTIMIZATION: Watch only specific fields to prevent rebuilds during drag
    // Don't watch entire tripState here since it rebuilds on every state change
    final hasPinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations.isNotEmpty));

    // Auto-open the warnings sheet whenever an optimization run lands with
    // simulation warnings. zoomToFitRouteTrigger increments at the end of
    // _performRouteOptimization (and previewRouteBetween — both are user-
    // initiated route renders, both should surface timing problems). We
    // schedule on the next frame so the modal doesn't try to push during
    // build, and re-read the simulation provider then so we see the result
    // computed from the just-landed route.
    ref.listen<int>(zoomToFitRouteTrigger, (prev, next) {
      if (prev == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final sim = ref.read(tripSimulationProvider);
        if (sim != null && !sim.fullyFeasible) {
          TimingWarningsSheet.show(context);
        }
      });
    });

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

                    // Tabs: Selected Date vs. All (grouped by date)
                    if (hasPinnedLocations) _buildLocationsTabBar(context),

                    // Locations List — content depends on active tab
                    ListenableBuilder(
                      listenable: _tabController,
                      builder: (context, _) {
                        if (!hasPinnedLocations || _tabController.index == 0) {
                          return Consumer(builder: (context, ref, _) {
                            final locationsForDate =
                                ref.watch(locationsForSelectedDateProvider);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: _buildLocationsListWidgets(context,
                                  ref, locationsForDate, scrollController),
                            );
                          });
                        }
                        return Consumer(builder: (context, ref, _) {
                          final all = ref.watch(tripProvider
                              .select((s) => s.pinnedLocations));
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildAllLocationsGroupedByDate(
                                context, ref, all, scrollController),
                          );
                        });
                      },
                    ),

                    // Optimize / CSV buttons act on the selected date —
                    // only show on the Selected Date tab.
                    ListenableBuilder(
                      listenable: _tabController,
                      builder: (context, _) {
                        if (hasPinnedLocations && _tabController.index != 0) {
                          return const SizedBox.shrink();
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildOptimizeButton(
                                context, ref, scrollController),
                            const SizedBox(height: 12),
                            _buildCsvDownloadButton(context, ref),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 130),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

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
              // Clear Route chip — visible whenever there's a live optimized
              // route, regardless of the selected date. Sits next to the
              // Re-optimize chip so it's discoverable from the header
              // without scrolling to the bottom of the list. We still
              // suppress while the optimizer is mid-run to avoid a
              // clear-vs-write race.
              Consumer(builder: (context, ref, _) {
                final isGenerating = ref.watch(isGeneratingRouteProvider);
                if (!hasOptimizedRoute || isGenerating) {
                  return const SizedBox.shrink();
                }
                final errorColor = Theme.of(context).colorScheme.error;
                return Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Material(
                    color: errorColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => ref
                          .read(tripProvider.notifier)
                          .clearOptimizedRoute(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.clear_all_rounded,
                                color: errorColor, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'Clear',
                              style: TextStyle(
                                color: errorColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(width: 8),
              Consumer(builder: (context, ref, _) {
                final isGenerating = ref.watch(isGeneratingRouteProvider);
                final locationsForDate =
                    ref.watch(locationsForSelectedDateProvider);
                final hasLocations = locationsForDate.isNotEmpty;
                final canTap = hasLocations && !isGenerating;
                final primaryColor = Theme.of(context).colorScheme.primary;

                final button = Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: canTap
                          ? [
                              primaryColor,
                              primaryColor.withValues(alpha: 0.8),
                            ]
                          : [
                              primaryColor.withValues(alpha: 0.35),
                              primaryColor.withValues(alpha: 0.25),
                            ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: canTap
                          ? () => _showChooseStartPointDialog(context, ref,
                              isReoptimizing: hasOptimizedRoute)
                          : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isGenerating
                                  ? Icons.hourglass_empty
                                  : Icons.route_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              hasOptimizedRoute
                                  ? 'Re-optimize'
                                  : 'Optimize Route',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                if (!canTap) return button;
                return _PulsingGlow(glowColor: primaryColor, child: button);
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
                    _showSkipConfirmationDialog(context, ref);
                  } else if (value == 'done' && hasWriteAccess) {
                    _markSelectedAsDone(context, ref);
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
                  PopupMenuItem<String>(
                    value: 'done',
                    enabled: hasWriteAccess,
                    child: ListTile(
                      leading: Icon(Icons.check_circle_outline,
                          color: hasWriteAccess ? Colors.green : Colors.grey),
                      title: Text('Mark as Done',
                          style: TextStyle(
                              color: hasWriteAccess ? Colors.green : Colors.grey)),
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
              // Google Maps navigation button with distance - only show if there are 2+ locations
              if (totalStopsForDate >= 2)
                Consumer(
                  builder: (context, ref, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton.filledTonal(
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
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.straighten,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _formatDistance(totalDistance),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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

  // Opens Google Maps with directions from the first to last location with
  // waypoints. Hands off via [openDirectionsInGoogleMaps] so each stop's
  // place_id is preferred over its lat/lng — that way renamed entries
  // still resolve to the exact Google place on the receiving end.
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

      await openDirectionsInGoogleMaps(
        origin: locations.first,
        destination: locations.last,
        waypoints: locations.length > 2
            ? locations.sublist(1, locations.length - 1)
            : const [],
      );
    } catch (e) {
      debugPrint('Error opening Google Maps: $e');
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

  /// PERFORMANCE: Build location widgets as a flat list to enable lazy loading
  /// Returns List<Widget> instead of nested ListViews for better performance
  List<Widget> _buildLocationsListWidgets(BuildContext context, WidgetRef ref,
      List<LocationModel> locations, ScrollController scrollController) {
    if (locations.isEmpty) {
      return [
        Container(
          padding:
              const EdgeInsets.only(left: 32, right: 32, bottom: 32, top: 16),
          child: Column(
            children: [
              Icon(
                Icons.map_outlined,
                size: 64,
                color: Theme.of(context).textTheme.bodyMedium?.color,
              ),
              const SizedBox(height: 16),
              Text(
                'No locations for this date',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Select another date or add new locations.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ];
    }

    final normalLocations = locations.where((l) => !l.isSkipped && !l.isDone).toList();
    final skippedLocations = locations.where((l) => l.isSkipped).toList();
    final doneLocations = locations.where((l) => l.isDone).toList();

    final widgets = <Widget>[];

    // Normal (upcoming) locations - directly add to list
    for (int i = 0; i < normalLocations.length; i++) {
      final location = normalLocations[i];
      widgets.add(
        OptimizedLocationCard(
          key: ValueKey(location.id),
          location: location,
          number: i + 1,
          scrollController: scrollController,
          sheetController: sheetController,
          onLocationTap: onLocationTap,
        ),
      );
    }

    // Done locations section
    if (doneLocations.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 24.0, bottom: 8.0, left: 4.0),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text(
                'Done',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: Colors.green),
              ),
            ],
          ),
        ),
      );

      for (final location in doneLocations) {
        widgets.add(
          OptimizedLocationCard(
            key: ValueKey('done_${location.id}'),
            location: location,
            number: -2,
            scrollController: scrollController,
            sheetController: sheetController,
            onLocationTap: onLocationTap,
          ),
        );
      }
    }

    // Skipped locations section
    if (skippedLocations.isNotEmpty) {
      widgets.add(
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
      );

      // Add skipped location cards
      for (final location in skippedLocations) {
        widgets.add(
          OptimizedLocationCard(
            key: ValueKey('skipped_${location.id}'),
            location: location,
            number: -1,
            scrollController: scrollController,
            sheetController: sheetController,
            onLocationTap: onLocationTap,
          ),
        );
      }
    }

    return widgets;
  }

  /// Tab bar that switches between the locations for the selected date
  /// and a grouped-by-date view of every location in the trip.
  Widget _buildLocationsTabBar(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: TabBar(
          controller: _tabController,
          labelColor: Colors.black,
          unselectedLabelColor: theme.textTheme.bodyMedium?.color,
          indicator: BoxDecoration(
            color: primary,
            borderRadius: BorderRadius.circular(12),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Selected Date'),
            Tab(text: 'All'),
          ],
        ),
      ),
    );
  }

  /// Builds the "All" tab — every location in the trip, grouped by their
  /// scheduledDate. Tapping a date header makes that date the selected date
  /// and switches the user back to the "Selected Date" tab.
  List<Widget> _buildAllLocationsGroupedByDate(
    BuildContext context,
    WidgetRef ref,
    List<LocationModel> all,
    ScrollController scrollController,
  ) {
    if (all.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            children: [
              Icon(Icons.event_note_outlined,
                  size: 64,
                  color: Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(height: 16),
              Text('No locations yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Add locations to see them grouped by date here.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ];
    }

    // Group by date-only key. Locations without a scheduledDate fall back to
    // their addedAt date — matches the behavior of locationsForSelectedDateProvider.
    final Map<DateTime, List<LocationModel>> grouped = {};
    for (final loc in all) {
      final raw = loc.scheduledDate ?? loc.addedAt;
      final key = DateTime(raw.year, raw.month, raw.day);
      grouped.putIfAbsent(key, () => []).add(loc);
    }
    final sortedDates = grouped.keys.toList()..sort();

    final selectedDate = ref.watch(selectedDateProvider);
    final today = DateTime(
        DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final widgets = <Widget>[];
    for (final date in sortedDates) {
      final locs = grouped[date]!;
      final isSelected = date == selectedDate;
      widgets.add(_buildDateGroupHeader(context, date, today, locs.length,
          isSelected: isSelected, onTap: () {
        ref.read(selectedDateProvider.notifier).state = date;
        _tabController.animateTo(0);
      }));

      // Sort within a date: upcoming first, then done, then skipped.
      final normal = locs.where((l) => !l.isSkipped && !l.isDone).toList();
      final done = locs.where((l) => l.isDone).toList();
      final skipped = locs.where((l) => l.isSkipped).toList();
      final ordered = [...normal, ...done, ...skipped];

      for (int i = 0; i < ordered.length; i++) {
        final loc = ordered[i];
        widgets.add(OptimizedLocationCard(
          key: ValueKey('all_${date.toIso8601String()}_${loc.id}'),
          location: loc,
          number: loc.isDone ? -2 : (loc.isSkipped ? -1 : i + 1),
          scrollController: scrollController,
          sheetController: sheetController,
          onLocationTap: onLocationTap,
        ));
      }
    }
    return widgets;
  }

  Widget _buildDateGroupHeader(
    BuildContext context,
    DateTime date,
    DateTime today,
    int count, {
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isToday = date == today;
    final isPast = date.isBefore(today);

    String label;
    if (isToday) {
      label = 'Today · ${DateFormat.MMMd().format(date)}';
    } else if (date == today.add(const Duration(days: 1))) {
      label = 'Tomorrow · ${DateFormat.MMMd().format(date)}';
    } else {
      label = DateFormat('EEE, MMM d, y').format(date);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? primary.withValues(alpha: 0.18)
                  : primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? primary
                    : primary.withValues(alpha: 0.2),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isPast ? Icons.history : Icons.calendar_today_outlined,
                  size: 18,
                  color: primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: isSelected ? primary : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: theme.textTheme.bodyMedium?.color
                        ?.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build optimize and CSV buttons as separate widgets
  Widget _buildOptimizeButton(BuildContext context, WidgetRef ref,
      ScrollController scrollController) {
    return Consumer(builder: (context, ref, _) {
      final isGenerating = ref.watch(isGeneratingRouteProvider);
      final hasRoute = ref
          .watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
      final selectedDate = ref.watch(selectedDateProvider);
      final locationsForDate = ref.watch(locationsForSelectedDateProvider);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isPastDate = selectedDate.isBefore(today);

      final isViewingHistory = isPastDate && hasRoute;
      final hasLocations = locationsForDate.isNotEmpty;

      String buttonText;
      VoidCallback? onPressedAction;

      if (isGenerating) {
        buttonText = 'Optimizing...';
        onPressedAction = null;
      } else if (isViewingHistory) {
        buttonText = 'View Route';
        onPressedAction = () {
          ref.read(TripBottomSheet.viewHistoricalRouteProvider.notifier)
              .state = true;
          final collapse = sheetController?.animateTo(
            0.12,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
          // Reset the list to the top after the sheet finishes collapsing.
          // Animating during collapse fights the shrinking viewport (the
          // DraggableScrollableSheet's scroll controller treats edge-pulls
          // as drags), and the list is hidden anyway by the time it lands —
          // so a post-collapse jumpTo is both reliable and invisible.
          void resetScroll() {
            if (scrollController.hasClients) scrollController.jumpTo(0);
          }
          if (collapse != null) {
            collapse.then((_) => resetScroll());
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) => resetScroll());
          }
        };
      } else if (!hasLocations) {
        buttonText = 'Optimize Route';
        onPressedAction = null; // disabled — no locations for this date
      } else {
        buttonText = hasRoute ? 'Re-optimize Route' : 'Optimize Route';
        onPressedAction = () => _showChooseStartPointDialog(context, ref,
            isReoptimizing: hasRoute);
      }

      final canGlow = onPressedAction != null && !isGenerating;
      final primaryColor = Theme.of(context).colorScheme.primary;

      final button = SizedBox(
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

      final primary =
          canGlow ? _PulsingGlow(glowColor: primaryColor, child: button) : button;

      // Clear Route is shown whenever there's a live optimized route and
      // locations to anchor it — past, today, and future alike. Suppressed
      // only while the optimizer is mid-run, to avoid a clear-vs-write
      // race against the in-flight optimization.
      final showClear = hasRoute && !isGenerating && hasLocations;
      if (!showClear) return primary;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          primary,
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(tripProvider.notifier).clearOptimizedRoute(),
            icon: const Icon(Icons.clear_all_rounded, size: 18),
            label: const Text('Clear Route'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              foregroundColor: Theme.of(context).colorScheme.error,
              side: BorderSide(
                color: Theme.of(context)
                    .colorScheme
                    .error
                    .withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildCsvDownloadButton(BuildContext context, WidgetRef ref) {
    return Consumer(builder: (context, ref, _) {
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
    });
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
                    // "Start at" — wall-clock the simulation should treat as
                    // arrival time at the first stop. Defaults to now (today)
                    // / 09:00 (future); user can override here. The picker
                    // writes to tripStartTimeOverrideProvider so the
                    // simulation provider sees the new value before it runs.
                    _StartAtRow(
                      onChanged: () => setDialogState(() {}),
                    ),
                    const Divider(height: 16),
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
      final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
      if (!context.mounted) return;
      final allowed = await ensureScheduledDateAllowed(
        context,
        activeTrip,
        newDate,
        actionLabel: 'Copy anyway',
      );
      if (!allowed) return;

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
      final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
      if (!context.mounted) return;
      final allowed = await ensureScheduledDateAllowed(
        context,
        activeTrip,
        newDate,
        actionLabel: 'Move anyway',
      );
      if (!allowed) return;

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

  void _markSelectedAsDone(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.read(selectedLocationsProvider);
    ref.read(tripProvider.notifier).markLocationsAsDone(selectedIds);
    ref.read(isSelectionModeProvider.notifier).state = false;
    ref.read(selectedLocationsProvider.notifier).state = {};
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

// Lightweight pulsing glow — no external dependencies.
// Wraps its child with an animated box-shadow that pulses in and out.
class _PulsingGlow extends StatefulWidget {
  final Widget child;
  final Color glowColor;

  const _PulsingGlow({
    required this.child,
    required this.glowColor,
  });

  @override
  State<_PulsingGlow> createState() => _PulsingGlowState();
}

class _PulsingGlowState extends State<_PulsingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: widget.glowColor
                  .withValues(alpha: 0.25 + _glow.value * 0.45),
              blurRadius: 6 + _glow.value * 18,
              spreadRadius: _glow.value * 3,
            ),
          ],
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// "Start at" row inside the choose-starting-point dialog. Reads the
/// effective start time (override-or-default) from
/// [effectiveTripStartTimeProvider] and writes user picks to
/// [tripStartTimeOverrideProvider]. The dialog passes [onChanged] so its
/// outer StatefulBuilder can repaint with the new label after the user
/// picks a time.
class _StartAtRow extends ConsumerWidget {
  final VoidCallback onChanged;
  const _StartAtRow({required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final start = ref.watch(effectiveTripStartTimeProvider);
    final label =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.schedule_rounded,
          color: theme.colorScheme.primary, size: 22),
      title: const Text('Start at'),
      subtitle: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(Icons.edit_outlined, size: 18),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: start.hour, minute: start.minute),
          helpText: 'Start at',
        );
        if (picked == null) return;
        ref.read(tripStartTimeOverrideProvider.notifier).state = picked;
        onChanged();
      },
    );
  }
}
