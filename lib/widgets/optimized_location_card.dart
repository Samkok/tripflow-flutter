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
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/trip_date_validator.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/core/theme.dart';

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

    // Translucent: these cards live inside the glass trip-plan sheet, so the
    // map behind should read through them too.
    final cardColor = isSelected
        ? primary.withValues(alpha: 0.18)
        : (isHighlighted
            ? primary.withValues(alpha: 0.10)
            : theme.cardColor
                .withValues(alpha: AppTheme.sheetCardAlpha(context)));

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _buildHeaderRow(
                      context,
                      hasPhotos: hasPhotos,
                      photoRefs: photoRefs,
                      isSelectionMode: isSelectionMode,
                      isSelected: isSelected,
                      accent: accent,
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
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          )
                        : const SizedBox(width: double.infinity, height: 0),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Opening–closing hours for the day this stop is planned on. Falls back
  /// to an explicit "not found" line rather than an empty subtitle, so the
  /// card always reads the same shape.
  String _hoursSubtitle() {
    const notFound = 'Opening and closing time not found';
    final hours = location.googleOpeningHours;
    if (hours == null || hours.isEmpty) return notFound;
    if (hours.length == 1 && hours.first.isAlwaysOpen) return 'Open 24 hours';

    // Google's weekday numbering: Sunday = 0 … Saturday = 6 (Dart's
    // DateTime.weekday is Monday = 1 … Sunday = 7).
    final day = location.scheduledDate ?? DateTime.now();
    final googleDay = day.weekday % 7;

    final periods = hours.where((p) => p.openDay == googleDay).toList();
    if (periods.isEmpty) return 'Closed on this day';
    return periods.map((p) {
      final open = _formatClockMinutes(p.openMinutes);
      final close = p.closeMinutes;
      if (close == null) return 'Opens $open';
      return '$open – ${_formatClockMinutes(close)}';
    }).join(', ');
  }

  String _formatClockMinutes(int minutes) {
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Color _accentColor(Color primary) {
    if (location.isDone) return Colors.green.shade500;
    if (location.isSkipped) return Colors.grey.shade500;
    return primary;
  }

  Widget _buildHeaderRow(
    BuildContext context, {
    required bool hasPhotos,
    required List<String> photoRefs,
    required bool isSelectionMode,
    required bool isSelected,
    required Color accent,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPhotos) ...[
          LocationPhotoThumbnail(
            photoRef: photoRefs.first,
            size: 108,
            extraCount: photoRefs.length > 1 ? photoRefs.length - 1 : null,
            onTap: () => _handleTap(context, ref, isSelectionMode, isSelected),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitleBlock(context, accent),
              if (!isSelectionMode) ...[
                const SizedBox(height: 12),
                _buildActions(context, hasPhotos),
              ],
            ],
          ),
        ),
        if (isSelectionMode) ...[
          const SizedBox(width: 4),
          _buildCheckbox(ref, isSelected),
        ],
      ],
    );
  }

  /// The attachment's two-button row. Labels follow this app's FUNCTIONS:
  /// the left button expands the inline photo gallery, the right one opens
  /// the per-stop menu that used to hide behind a three-dot icon.
  Widget _buildActions(BuildContext context, bool hasPhotos) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    ButtonStyle style(Color bg) => FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: bg,
          foregroundColor: theme.colorScheme.onSurface,
          minimumSize: const Size(0, 40),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle:
              theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        );

    return Row(
      children: [
        if (hasPhotos) ...[
          Expanded(
            child: FilledButton(
              onPressed: () => setState(() => _isExpanded = !_isExpanded),
              style: style(primary.withValues(alpha: 0.30)),
              child: Text(
                _isExpanded ? 'Hide photos' : 'More photos',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: _buildOptionsButton(
            context,
            ref,
            style(theme.colorScheme.onSurface.withValues(alpha: 0.10)),
          ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock(BuildContext context, Color accent) {
    final theme = Theme.of(context);
    final mutedColor =
        theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7);
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      decoration: location.isSkipped ? TextDecoration.lineThrough : null,
      color: location.isSkipped ? mutedColor : null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // "1. A Symphony of Lights" — the index leads the name (it
              // used to live in a separate accent bar). Done/skipped stops
              // swap the number for their status glyph, keeping the
              // information the bar carried.
              child: Text.rich(
                TextSpan(
                  children: [
                    if (location.isDone)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.check_circle_rounded,
                              size: 18, color: accent),
                        ),
                      )
                    else if (location.isSkipped)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.remove_circle_outline_rounded,
                              size: 18, color: accent),
                        ),
                      )
                    else
                      TextSpan(
                        text: '$number. ',
                        style: titleStyle?.copyWith(color: accent),
                      ),
                    TextSpan(text: location.name),
                  ],
                ),
                style: titleStyle,
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.access_time_rounded, size: 13, color: mutedColor),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _hoursSubtitle(),
                style: theme.textTheme.bodySmall?.copyWith(color: mutedColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        // if (location.travelTimeFromPrevious != null &&
        //     location.distanceFromPrevious != null) ...[
        //   const SizedBox(height: 8),
        //   _buildTravelChips(context),
        // ],
        // _buildWarningBadge(context),
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

  /// "Options" — the SAME menu the three-dot icon used to open, presented
  /// as the mockup's labeled button. [style] comes from the actions row so
  /// both buttons share one shape.
  Widget _buildOptionsButton(
      BuildContext context, WidgetRef ref, ButtonStyle style) {
    return _buildPopupMenu(
      context,
      ref,
      child: FilledButton(
        // The PopupMenuButton wrapper owns the gesture; this button just
        // draws and forwards the tap to it.
        onPressed: null,
        style: style.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
              (_) => style.backgroundColor?.resolve({}) ?? Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((_) =>
              style.foregroundColor?.resolve({}) ??
              Theme.of(context).colorScheme.onSurface),
        ),
        child: const Text('Options', maxLines: 1),
      ),
    );
  }

  Widget _buildPopupMenu(BuildContext context, WidgetRef ref, {Widget? child}) {
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.asData?.value ?? false;
    // "Remove from trip" only makes sense when this location is actually
    // attached to a trip — i.e. there's an active trip in this view. When
    // there isn't (loose locations on the map), the option is hidden.
    final activeTrip = ref.watch(realtimeActiveTripProvider).valueOrNull;
    final canRemoveFromTrip = activeTrip != null && hasWriteAccess;

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      // With [child] the button renders as the labeled "Options" control;
      // without it, the classic three-dot icon (other call sites).
      icon: child == null ? const Icon(Icons.more_vert, size: 22) : null,
      child: child,
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
      highlightRange: activeTripDateRange(ref),
    );

    if (newDate != null) {
      final activeTrip = ref.read(realtimeActiveTripProvider).valueOrNull;
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
      // Shared same-day duplicate rule: the place may repeat across days,
      // never within one day. COPY keeps the source row as an occupant
      // (copying onto its own day duplicates); MOVE excludes it (no-op).
      final occupants = ref
          .read(tripProvider)
          .pinnedLocations
          .where((l) =>
              (isCopy || l.id != location.id) &&
              l.scheduledDate != null &&
              l.isActiveOnDate(dayKey))
          .map(placeKeyOfModel);
      final dup = filterSameDayDuplicates(
        moving: [placeKeyOfModel(location)],
        occupantsOnDay: occupants,
      );
      if (dup.allowedIds.isEmpty) {
        if (context.mounted) {
          AppToast.warning(context,
              '"${location.name}" is already on ${DateFormat('MMM d').format(dayKey)}');
        }
        return;
      }
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
