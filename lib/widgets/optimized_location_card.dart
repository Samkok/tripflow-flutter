import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_simulation_provider.dart';
import 'package:voyza/services/timing_simulation.dart';
import 'package:voyza/widgets/accommodation_prompts.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/trip_date_validator.dart';
import 'package:voyza/widgets/app_toast.dart';

/// Location card displayed inside the trip-plan bottom sheet.
///
/// Visual structure (collapsed):
///   [accent bar] [number badge] [title + address + travel chips] [cover thumb] [chevron + menu]
/// When expanded a horizontal photo strip is revealed below.
class OptimizedLocationCard extends ConsumerStatefulWidget {
  final LocationModel location;
  final int number;
  final ScrollController scrollController;
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;

  const OptimizedLocationCard({
    super.key,
    required this.location,
    required this.number,
    required this.scrollController,
    required this.sheetController,
    required this.onLocationTap,
  });

  @override
  ConsumerState<OptimizedLocationCard> createState() =>
      _OptimizedLocationCardState();
}

class _OptimizedLocationCardState extends ConsumerState<OptimizedLocationCard> {
  bool _isExpanded = false;

  LocationModel get location => widget.location;
  int get number => widget.number;

  @override
  Widget build(BuildContext context) {
    final pinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final index = pinnedLocations.indexOf(location);

    final isHighlighted = ref.watch(highlightedLocationIndexProvider) == index;
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final isSelected = ref.watch(
        selectedLocationsProvider.select((s) => s.contains(location.id)));

    final photoRefs = location.photoReferences;
    final hasPhotos = photoRefs.isNotEmpty;

    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final accent = _accentColor(primary);

    final cardColor = isSelected
        ? primary.withValues(alpha: 0.18)
        : (isHighlighted ? primary.withValues(alpha: 0.10) : theme.cardColor);

    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isHighlighted
                ? primary
                : theme.dividerColor.withValues(alpha: 0.08),
            width: isHighlighted ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () =>
                  _handleTap(context, ref, isSelectionMode, isSelected),
              onLongPress: () => _handleLongPress(ref, isSelectionMode),
              // Stack instead of IntrinsicHeight: the bar is positioned to
              // fill the card vertically, so it naturally extends with the
              // photo gallery. IntrinsicHeight here would query the new
              // (collapsed) child's height while AnimatedSize is still
              // rendering at the old size, causing a transient overflow.
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 12, 4, 12),
                          child: _buildHeaderRow(
                            context,
                            hasPhotos: hasPhotos,
                            photoRefs: photoRefs,
                            isSelectionMode: isSelectionMode,
                            isSelected: isSelected,
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                          alignment: Alignment.topCenter,
                          child: hasPhotos && _isExpanded
                              ? LocationPhotoGallery(
                                  photoRefs: photoRefs,
                                  heroTagPrefix: '${location.id}_photo',
                                  title: location.name,
                                  padding:
                                      const EdgeInsets.fromLTRB(10, 0, 10, 12),
                                )
                              : const SizedBox(
                                  width: double.infinity, height: 0),
                        ),
                      ],
                    ),
                  ),
                  PositionedDirectional(
                    start: 0,
                    top: 0,
                    bottom: 0,
                    width: 30,
                    child: _buildAccentBar(context, accent),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _accentColor(Color primary) {
    if (location.isDone) return Colors.green.shade500;
    if (location.isSkipped) return Colors.grey.shade500;
    return primary;
  }

  /// Wider vertical accent bar that doubles as the index/status indicator.
  /// Stretches to full card height (including the expanded gallery) thanks
  /// to the surrounding `IntrinsicHeight` + `crossAxisAlignment.stretch`.
  Widget _buildAccentBar(BuildContext context, Color accent) {
    Widget content;
    if (location.isDone) {
      content = const Icon(Icons.check_rounded, color: Colors.white, size: 16);
    } else if (location.isSkipped) {
      content = const Icon(Icons.remove_rounded, color: Colors.white, size: 16);
    } else {
      content = Text(
        '$number',
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w800,
          fontSize: 14,
        ),
      );
    }

    return Container(
      color: accent,
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: 14),
      child: content,
    );
  }

  Widget _buildHeaderRow(
    BuildContext context, {
    required bool hasPhotos,
    required List<String> photoRefs,
    required bool isSelectionMode,
    required bool isSelected,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPhotos) ...[
          LocationPhotoThumbnail(
            photoRef: photoRefs.first,
            size: 52,
            extraCount: photoRefs.length > 1 ? photoRefs.length - 1 : null,
            onTap: () => setState(() => _isExpanded = !_isExpanded),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(child: _buildTitleBlock(context)),
        const SizedBox(width: 4),
        if (isSelectionMode)
          _buildCheckbox(ref, isSelected)
        else
          _buildActions(context, hasPhotos),
      ],
    );
  }

  Widget _buildActions(BuildContext context, bool hasPhotos) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasPhotos)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: _isExpanded ? 'Hide photos' : 'Show photos',
            icon: AnimatedRotation(
              turns: _isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more, size: 22),
            ),
            onPressed: () => setState(() => _isExpanded = !_isExpanded),
          ),
        _buildPopupMenu(context, ref),
      ],
    );
  }

  Widget _buildTitleBlock(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor =
        theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                location.name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  decoration:
                      location.isSkipped ? TextDecoration.lineThrough : null,
                  color: location.isSkipped ? mutedColor : null,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (location.isMultiDay) ...[
              const SizedBox(width: 6),
              _buildStayChip(context),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          location.address,
          style: theme.textTheme.bodySmall?.copyWith(color: mutedColor),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (location.travelTimeFromPrevious != null &&
            location.distanceFromPrevious != null) ...[
          const SizedBox(height: 8),
          _buildTravelChips(context),
        ],
        _buildWarningBadge(context),
      ],
    );
  }

  /// Compact hotel chip surfaced next to the title when this location is a
  /// multi-day stay. Reads `scheduledDate`/`scheduledEndDate` directly —
  /// guarded by [LocationModel.isMultiDay] at the call site, so both are
  /// non-null here.
  Widget _buildStayChip(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('MMM d');
    final start = location.scheduledDate!;
    final end = location.scheduledEndDate!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hotel_rounded, size: 12, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            '${df.format(start)} – ${df.format(end)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// Reads the latest closing-time-aware simulation result for this stop and
  /// renders a single most-severe warning chip when present. Hidden when the
  /// simulation hasn't run, this stop is feasible, or the location is
  /// skipped/done (warnings would be misleading on a stop the user already
  /// decided not to visit).
  Widget _buildWarningBadge(BuildContext context) {
    if (location.isSkipped || location.isDone) return const SizedBox.shrink();
    final warnings = ref.watch(stopWarningsProvider
        .select((m) => m[location.id] ?? const <TimingWarning>[]));
    if (warnings.isEmpty) return const SizedBox.shrink();

    final w = warnings.reduce((a, b) => a.kind.index >= b.kind.index ? a : b);
    final theme = Theme.of(context);
    Color fg;
    IconData icon;
    switch (w.kind) {
      case WarningKind.willOverrunClose:
        fg = Colors.orange.shade700;
        icon = Icons.timer_outlined;
        break;
      case WarningKind.notOpenYet:
        fg = Colors.blue.shade700;
        icon = Icons.schedule_outlined;
        break;
      case WarningKind.closedOnArrival:
      case WarningKind.closedAllDay:
        fg = theme.colorScheme.error;
        icon = Icons.do_not_disturb_on_outlined;
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                w.message,
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTravelChips(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _chip(
          context,
          icon: Icons.access_time_rounded,
          label: _formatDuration(location.travelTimeFromPrevious!),
        ),
        _chip(
          context,
          icon: Icons.straighten_rounded,
          label: _formatDistance(location.distanceFromPrevious!),
        ),
      ],
    );
  }

  Widget _chip(BuildContext context,
      {required IconData icon, required String label}) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _handleTap(BuildContext context, WidgetRef ref, bool isSelectionMode,
      bool isSelected) {
    if (isSelectionMode) {
      final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
      if (isSelected) {
        selectedNotifier.update((state) => state.difference({location.id}));
      } else {
        selectedNotifier.update((state) => state.union({location.id}));
      }
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        // Keep a full-height sheet (photos + hours + multi-day on small
        // screens) from rendering its header under the status bar/notch.
        useSafeArea: true,
        builder: (modalContext) => LocationDetailSheet(
          location: location,
          number: number,
          parentScrollController: widget.scrollController,
          parentSheetController: widget.sheetController,
          onLocationTap: widget.onLocationTap,
        ),
      );
    }
  }

  void _handleLongPress(WidgetRef ref, bool isSelectionMode) {
    if (!isSelectionMode) {
      ref.read(isSelectionModeProvider.notifier).state = true;
      ref
          .read(selectedLocationsProvider.notifier)
          .update((state) => state.union({location.id}));
    }
  }

  Widget _buildCheckbox(WidgetRef ref, bool isSelected) {
    return Checkbox(
      value: isSelected,
      onChanged: (bool? value) {
        final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
        if (value == true) {
          selectedNotifier.update((state) => state.union({location.id}));
        } else {
          selectedNotifier.update((state) => state.difference({location.id}));
        }
      },
    );
  }

  Widget _buildPopupMenu(BuildContext context, WidgetRef ref) {
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.asData?.value ?? false;
    // "Remove from trip" only makes sense when this location is actually
    // attached to a trip — i.e. there's an active trip in this view. When
    // there isn't (loose locations on the map), the option is hidden.
    final activeTrip = ref.watch(realtimeActiveTripProvider).asData?.value;
    final canRemoveFromTrip = activeTrip != null && hasWriteAccess;

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 22),
      onSelected: (value) {
        if (!hasWriteAccess && value != 'copy') {
          AppToast.warning(
            context,
            'You don\'t have permission to modify locations in this trip.',
          );
          return;
        }
        _handleMenuSelection(context, value, ref, activeTrip?.id);
      },
      itemBuilder: (context) {
        final isPastDate = ref.read(selectedDateProvider).isBefore(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day));
        final canEdit = !isPastDate && hasWriteAccess;

        return [
          if (location.isSkipped)
            PopupMenuItem<String>(
              value: 'unskip',
              enabled: canEdit,
              child: ListTile(
                  leading: Icon(Icons.add_circle_outline,
                      color: canEdit ? null : Colors.grey),
                  title: Text('Un-skip',
                      style: TextStyle(color: canEdit ? null : Colors.grey))),
            )
          else
            PopupMenuItem<String>(
              value: 'skip',
              enabled: canEdit,
              child: ListTile(
                  leading: Icon(Icons.remove_circle_outline,
                      color: canEdit ? null : Colors.grey),
                  title: Text('Skip',
                      style: TextStyle(color: canEdit ? null : Colors.grey))),
            ),
          PopupMenuItem<String>(
            value: location.isDone ? 'undone' : 'done',
            enabled: hasWriteAccess,
            child: ListTile(
              leading: Icon(
                location.isDone
                    ? Icons.cancel_outlined
                    : Icons.check_circle_outline,
                color: hasWriteAccess ? Colors.green : Colors.grey,
              ),
              title: Text(
                location.isDone ? 'Unmark as Done' : 'Mark as Done',
                style: TextStyle(
                    color: hasWriteAccess ? Colors.green : Colors.grey),
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
                    style: TextStyle(color: canEdit ? null : Colors.grey))),
          ),
          const PopupMenuItem<String>(
            value: 'copy',
            child:
                ListTile(leading: Icon(Icons.copy), title: Text('Copy to...')),
          ),
          if (canRemoveFromTrip)
            PopupMenuItem<String>(
              value: 'remove_from_trip',
              child: ListTile(
                leading: Icon(Icons.link_off,
                    color: Theme.of(context).colorScheme.primary),
                title: const Text('Remove from trip'),
              ),
            ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
              value: 'delete',
              enabled: hasWriteAccess,
              child: ListTile(
                  leading: Icon(Icons.delete_outline,
                      color: hasWriteAccess ? Colors.red : Colors.grey),
                  title: Text('Delete',
                      style: TextStyle(
                          color: hasWriteAccess ? Colors.red : Colors.grey)))),
        ];
      },
    );
  }

  void _handleMenuSelection(
      BuildContext context, String value, WidgetRef ref, String? activeTripId) {
    final selectedIds = {location.id};

    if (value == 'delete') {
      _showDeleteConfirmationDialog(context, ref);
    } else if (value == 'skip') {
      ref.read(tripProvider.notifier).skipMultipleLocations(selectedIds);
    } else if (value == 'unskip') {
      ref.read(tripProvider.notifier).unskipMultipleLocations(selectedIds);
    } else if (value == 'move') {
      _showMoveCopyDialog(context, ref, isCopy: false);
    } else if (value == 'copy') {
      _showMoveCopyDialog(context, ref, isCopy: true);
    } else if (value == 'done') {
      ref.read(tripProvider.notifier).markLocationsAsDone({location.id});
    } else if (value == 'undone') {
      ref.read(tripProvider.notifier).unmarkLocationsAsDone({location.id});
    } else if (value == 'remove_from_trip') {
      _showRemoveFromTripDialog(context, ref, activeTripId);
    }
  }

  /// Confirms and detaches this location from its current trip — the
  /// location itself is preserved, only its `trip_id` is cleared, after
  /// which it shows up in the "Add Locations to Trip" picker as
  /// unassigned. The Undo snackbar action re-attaches it to the trip it
  /// just left.
  void _showRemoveFromTripDialog(
      BuildContext context, WidgetRef ref, String? activeTripId) {
    if (activeTripId == null) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Remove from trip'),
          content: Text(
              'Remove "${location.name}" from this trip? The location will '
              'still be saved — you can add it back from "Add Locations to Trip" later.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await ref
                    .read(tripProvider.notifier)
                    .removeLocationsFromTrip([location.id]);
                if (!context.mounted) return;
                AppToast.success(context, 'Removed ${location.name} from trip');
              },
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
  }

  void _showMoveCopyDialog(BuildContext context, WidgetRef ref,
      {required bool isCopy}) async {
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
        actionLabel: isCopy ? 'Copy anyway' : 'Move anyway',
      );
      if (!allowed) return;

      // Moving/copying onto a previously-empty day materializes a new trip
      // day → ask about accommodation. Asked BEFORE the write on this
      // surface: a MOVE removes this card from the current date's list and
      // unmounts it, so its context/ref wouldn't survive to prompt after.
      // The notifiers are captured up-front for the same reason — the
      // prompt's "add a different place" branch switches the selected date,
      // which can unmount this card mid-flow, and the user's move/copy must
      // still complete.
      final tripNotifier = ref.read(tripProvider.notifier);
      final dateNotifier = ref.read(selectedDateProvider.notifier);
      final dayKey = DateTime(newDate.year, newDate.month, newDate.day);
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      if (dayWasEmpty && activeTrip != null && context.mounted) {
        await maybePromptAccommodationForNewDays(
          context,
          ref,
          trip: activeTrip,
          newDays: [dayKey],
        );
      }

      final selectedIds = {location.id};
      if (isCopy) {
        await tripNotifier.copyMultipleLocationsToDate(selectedIds, newDate);
      } else {
        await tripNotifier.updateMultipleLocationsScheduledDate(
            selectedIds, newDate);
      }
      dateNotifier.state = newDate;
    }
  }

  void _showDeleteConfirmationDialog(BuildContext context, WidgetRef ref) {
    // A multi-day row (e.g. an accommodation spanning the trip) viewed on
    // one of its days: deleting must NOT wipe the whole span. Offer
    // "remove from this day" (shrinks/splits the range) as the primary
    // action, with delete-everywhere as the explicit destructive choice.
    final selectedDate = ref.read(selectedDateProvider);
    final day =
        DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final startRaw = location.scheduledDate ?? location.addedAt;
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = location.scheduledEndDate ?? startRaw;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    final spansHere =
        end.isAfter(start) && !day.isBefore(start) && !day.isAfter(end);

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(spansHere ? 'Remove Location' : 'Delete Location'),
          content: Text(spansHere
              ? '"${location.name}" spans '
                  '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d').format(end)}. '
                  'Remove it from this day only, or delete it from every day?'
              : 'Are you sure you want to delete "${location.name}"? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            if (spansHere) ...[
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ref.read(tripProvider.notifier).removeLocation(location.id);
                  AppToast.error(context, 'Deleted ${location.name}');
                },
                child: Text('Delete everywhere',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ref
                      .read(tripProvider.notifier)
                      .removeLocationFromDay(location.id, day);
                  AppToast.success(context,
                      '${location.name} removed from ${DateFormat('MMM d').format(day)}');
                },
                child: const Text('Remove from this day'),
              ),
            ] else
              ElevatedButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ref.read(tripProvider.notifier).removeLocation(location.id);
                  AppToast.error(context, 'Deleted ${location.name}');
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

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    }
    return '${(distanceInMeters / 1000).toStringAsFixed(1)}km';
  }
}
