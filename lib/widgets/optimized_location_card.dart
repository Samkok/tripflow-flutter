import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/trip_date_validator.dart';

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
                          padding:
                              const EdgeInsets.fromLTRB(10, 12, 4, 12),
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
                                  padding: const EdgeInsets.fromLTRB(
                                      10, 0, 10, 12),
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
      content =
          const Icon(Icons.check_rounded, color: Colors.white, size: 16);
    } else if (location.isSkipped) {
      content =
          const Icon(Icons.remove_rounded, color: Colors.white, size: 16);
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
            constraints:
                const BoxConstraints(minWidth: 32, minHeight: 32),
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
        Text(
          location.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            decoration: location.isSkipped ? TextDecoration.lineThrough : null,
            color: location.isSkipped ? mutedColor : null,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
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
      ],
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

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, size: 22),
      onSelected: (value) {
        if (!hasWriteAccess && value != 'copy') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'You don\'t have permission to modify locations in this trip.'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
        _handleMenuSelection(context, value, ref);
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
                style:
                    TextStyle(color: hasWriteAccess ? Colors.green : Colors.grey),
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

  void _handleMenuSelection(BuildContext context, String value, WidgetRef ref) {
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
    }
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

      final selectedIds = {location.id};
      if (isCopy) {
        await ref
            .read(tripProvider.notifier)
            .copyMultipleLocationsToDate(selectedIds, newDate);
      } else {
        await ref
            .read(tripProvider.notifier)
            .updateMultipleLocationsScheduledDate(selectedIds, newDate);
      }
      ref.read(selectedDateProvider.notifier).state = newDate;
    }
  }

  void _showDeleteConfirmationDialog(BuildContext context, WidgetRef ref) {
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
                Navigator.of(dialogContext).pop();
                ref.read(tripProvider.notifier).removeLocation(location.id);
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
