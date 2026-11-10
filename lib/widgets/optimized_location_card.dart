import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart' show OpeningPeriod;
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_day_labeler_provider.dart';
import 'package:voyza/widgets/trip_day_picker.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/providers/place_photo_refresh_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/services/place_photo_refresh_service.dart';
import 'package:voyza/widgets/accommodation_prompts.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/widgets/move_to_trip_sheet.dart';
import 'package:voyza/widgets/photo_gallery_viewer.dart';
import 'package:voyza/widgets/stay_duration_dialog.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/trip_date_validator.dart';
import 'package:voyza/widgets/app_toast.dart';
import '../services/subscription_limit_service.dart';
import 'package:voyza/core/theme.dart';

/// The place card — one widget for the map's plan sheet and the trip page.
///
/// Visual structure (collapsed):
///   [cover thumb] [index-led title + hours + "Stay" text button + actions row]
/// When expanded a horizontal photo strip is revealed below. The action row
/// is Done · Options · Map; the Options menu holds what the row lacks.
class OptimizedLocationCard extends ConsumerStatefulWidget {
  final LocationModel location;
  final int number;
  final ScrollController scrollController;
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;

  /// false = the day has no optimized route yet, so the "N." prefix (a
  /// visit order) is withheld; the start flag and done/skipped glyphs
  /// still show.
  final bool showNumber;

  /// The trip this row belongs to; gating reads THAT trip's write access.
  /// Null = the map's loose places (the map trip's access, as before).
  final String? tripId;

  /// The day the row is shown under; past days are read-only. Null with a
  /// [tripId] = a bucket row (Unscheduled, Not visited): never past.
  final DateTime? day;

  /// Day labels; defaults to the map trip's.
  final DayLabeler? labeler;

  /// Long-press and the checkbox take part in multi-select.
  final bool selectable;

  /// Inline gallery open from the start (the trip page's habit).
  final bool photosExpandedInitially;

  /// One quiet line under the hours ("Added 5 Nov 2026, 3:12 PM").
  final String? footnote;

  /// Trailing slot in the header row (the trip page's drag handle).
  final Widget? trailing;

  /// The other stops of the same day, for the detail sheet's From / To.
  final List<LocationModel>? siblings;

  /// Replaces the map button's default (zoom the map to this stop).
  final VoidCallback? onMapPressed;

  /// Awaited before any action (opening the sheet, Done, a menu item): the
  /// trip page makes its trip the map trip here.
  final Future<void> Function()? beforeAction;

  const OptimizedLocationCard({
    super.key,
    required this.location,
    required this.number,
    required this.scrollController,
    required this.sheetController,
    required this.onLocationTap,
    this.showNumber = true,
    this.tripId,
    this.day,
    this.labeler,
    this.selectable = true,
    this.photosExpandedInitially = false,
    this.footnote,
    this.trailing,
    this.siblings,
    this.onMapPressed,
    this.beforeAction,
  });

  @override
  ConsumerState<OptimizedLocationCard> createState() =>
      _OptimizedLocationCardState();
}

class _OptimizedLocationCardState extends ConsumerState<OptimizedLocationCard> {
  late bool _isExpanded = widget.photosExpandedInitially;

  LocationModel get location => widget.location;
  int get number => widget.number;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = ref
        .watch(highlightedLocationIdProvider.select((id) => id == location.id));
    final selectable = widget.selectable;
    final isSelectionMode = selectable && ref.watch(isSelectionModeProvider);
    final isSelected = selectable &&
        ref.watch(
            selectedLocationsProvider.select((s) => s.contains(location.id)));
    final hasWriteAccess = _watchWriteAccess();
    final canEdit = hasWriteAccess && !_isPastDay();

    final photoRefs = location.photoReferences;
    final hasPhotos = photoRefs.isNotEmpty;
    // Photos on screen: renew the Google references when they're old (that
    // is how photos added on Google Maps arrive) — failed tiles report
    // through _onPhotoLoadFailed.
    if (hasPhotos) {
      ref.read(placePhotoRefreshProvider).noteShown(_photoRefreshTarget);
    }

    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final accent = _accentColor(primary);

    // A quiet solid tint: the trip-plan sheet is opaque (2026-10-12), so
    // the card needs its own contrast against the sheet's surface.
    final cardColor = isSelected
        ? primary.withValues(alpha: 0.18)
        : (isHighlighted
            ? primary.withValues(alpha: 0.10)
            : AppTheme.planSheetCardColor(context));

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
              onLongPress: selectable
                  ? () => _handleLongPress(ref, isSelectionMode)
                  : null,
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
                      hasWriteAccess: hasWriteAccess,
                      canEdit: canEdit,
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
                            onLoadFailed: _onPhotoLoadFailed,
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

  /// One bool select: this trip's write access, or the map trip's for a
  /// loose place. Retained through reloads (`valueOrNull`), so a refresh
  /// never blinks the controls.
  bool _watchWriteAccess() {
    final tripId = widget.tripId;
    if (tripId != null) {
      return ref.watch(
          hasWriteAccessProvider(tripId).select((a) => a.valueOrNull ?? false));
    }
    return ref.watch(
        hasActiveTripWriteAccessProvider.select((a) => a.valueOrNull ?? false));
  }

  /// The gating day: the row's own; the map's selected day for a loose
  /// place; none (never past) for a trip's bucket row.
  DateTime? _gateDay() {
    if (widget.day != null) return widget.day;
    if (widget.tripId != null) return null;
    return ref.watch(selectedDateProvider);
  }

  bool _isPastDay() {
    final day = _gateDay();
    if (day == null) return false;
    final now = DateTime.now();
    return day.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Every action first waits for [OptimizedLocationCard.beforeAction].
  Future<void> _run(FutureOr<void> Function() action) async {
    final before = widget.beforeAction;
    if (before != null) await before();
    if (!mounted) return;
    await action();
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Hours-line text for a weekday Google lists no opening period on.
  static const String kMightBeClosedLabel = 'Might be closed on this date';

  /// Opening–closing hours for the day this stop is planned on. Falls back
  /// to an explicit "not found" line rather than an empty subtitle, so the
  /// card always reads the same shape.
  String _hoursSubtitle() {
    const notFound = 'Opening and closing time not found';
    final hours = location.googleOpeningHours;
    if (hours == null || hours.isEmpty) return notFound;
    if (hours.length == 1 && hours.first.isAlwaysOpen) return 'Open 24 hours';

    // A trip without dates has no weekday to look up: show the hours when
    // they're the same every day, otherwise say they vary.
    if (_labeler.tbd) return _undatedHoursSubtitle(hours);

    // Google's weekday numbering: Sunday = 0 … Saturday = 6 (Dart's
    // DateTime.weekday is Monday = 1 … Sunday = 7).
    final day = location.scheduledDate ?? DateTime.now();
    final googleDay = day.weekday % 7;

    final periods = hours.where((p) => p.openDay == googleDay).toList();
    // A "might": Google's hours are often stale or incomplete, so this is
    // a prompt to double-check, never a verdict. Rendered in amber.
    if (periods.isEmpty) return kMightBeClosedLabel;
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

  PhotoRefreshTarget get _photoRefreshTarget =>
      PhotoRefreshTarget.fromModel(location);

  void _onPhotoLoadFailed() =>
      ref.read(placePhotoRefreshProvider).noteLoadFailed(_photoRefreshTarget);

  Widget _buildHeaderRow(
    BuildContext context, {
    required bool hasPhotos,
    required List<String> photoRefs,
    required bool isSelectionMode,
    required bool isSelected,
    required Color accent,
    required bool hasWriteAccess,
    required bool canEdit,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasPhotos) ...[
          LocationPhotoThumbnail(
            photoRef: photoRefs.first,
            size: 108,
            extraCount: photoRefs.length > 1 ? photoRefs.length - 1 : null,
            onLoadFailed: _onPhotoLoadFailed,
            // The image IS the photos affordance: tapping it opens the
            // full-screen carousel. The rest of the card still opens the
            // location detail modal (selection mode keeps its toggle).
            onTap: () => isSelectionMode
                ? _handleTap(context, ref, isSelectionMode, isSelected)
                : showPhotoGalleryViewer(
                    context: context,
                    photoUrls: photoRefs.map(resolveLocationPhotoUrl).toList(),
                    initialIndex: 0,
                    title: location.name,
                  ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTitleBlock(context, accent, hasPhotos: hasPhotos),
              if (!isSelectionMode) ...[
                const SizedBox(height: 2),
                _buildStayButton(context, canEdit),
                const SizedBox(height: 6),
                _buildActions(context, hasWriteAccess, canEdit),
              ],
            ],
          ),
        ),
        if (widget.trailing != null) ...[
          const SizedBox(width: 2),
          widget.trailing!,
        ],
        if (isSelectionMode) ...[
          const SizedBox(width: 4),
          _buildCheckbox(ref, isSelected),
        ],
      ],
    );
  }

  /// Done · Options · Map. Done is the one-tap action on the road; the
  /// menu holds the rest; the square flies the map to this stop.
  Widget _buildActions(
      BuildContext context, bool hasWriteAccess, bool canEdit) {
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

    final done = location.isDone;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: !hasWriteAccess
                ? null
                : () => _run(() {
                      final notifier = ref.read(tripProvider.notifier);
                      return done
                          ? notifier.unmarkLocationsAsDone({location.id})
                          : notifier.markLocationsAsDone({location.id});
                    }),
            style: style(done
                ? theme.colorScheme.onSurface.withValues(alpha: 0.10)
                : Colors.green.withValues(alpha: 0.22)),
            icon: Icon(done ? Icons.undo_rounded : Icons.check_rounded,
                size: 18,
                color: done ? theme.colorScheme.onSurface : Colors.green),
            label: Text(done ? 'Undo' : 'Done',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildOptionsButton(
            context,
            ref,
            style(theme.colorScheme.onSurface.withValues(alpha: 0.10)),
            hasWriteAccess: hasWriteAccess,
            canEdit: canEdit,
          ),
        ),
        const SizedBox(width: 10),
        // Square map button: collapses the plan sheet and flies the camera
        // to this stop (request consumed by MapScreen); the trip page
        // hands in its own.
        SizedBox(
          width: 44,
          child: FilledButton(
            onPressed: widget.onMapPressed ??
                () {
                  // The camera must land on a day where this stop's pin exists.
                  // If the selected day doesn't include it (and we're not in
                  // All-days view, which shows everything), jump the day strip
                  // to the stop's scheduled day first.
                  final sched = widget.location.scheduledDate;
                  if (sched != null &&
                      !ref.read(allDaysModeProvider) &&
                      !widget.location
                          .isActiveOnDate(ref.read(selectedDateProvider))) {
                    ref.read(selectedDateProvider.notifier).state =
                        DateTime(sched.year, sched.month, sched.day);
                  }
                  ref.read(mapZoomToLocationRequestProvider.notifier).state =
                      MapZoomToLocationRequest(widget.location.coordinates);
                },
            style: style(primary.withValues(alpha: 0.18)).copyWith(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            child: Icon(Icons.map_rounded, size: 20, color: primary),
          ),
        ),
      ],
    );
  }

  Widget _buildTitleBlock(BuildContext context, Color accent,
      {required bool hasPhotos}) {
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
                    else if (number == 0)
                      // Number 0 = this stop is the route's START anchor —
                      // mirror the map's flag pin instead of a misleading
                      // "0." (map stop 1 == list stop 1 from here on).
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child:
                              Icon(Icons.flag_rounded, size: 18, color: accent),
                        ),
                      )
                    else if (widget.showNumber)
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
            if (hasPhotos) ...[
              const SizedBox(width: 2),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  tooltip: _isExpanded ? 'Hide photos' : 'Show photos',
                  icon: AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, size: 20),
                  ),
                  onPressed: () => setState(() => _isExpanded = !_isExpanded),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(builder: (context) {
              final hoursText = _hoursSubtitle();
              final caution = hoursText == kMightBeClosedLabel;
              const amber = Color(0xFFFFB300);
              return Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                        caution
                            ? Icons.warning_amber_rounded
                            : Icons.access_time_rounded,
                        size: 13,
                        color: caution ? amber : mutedColor),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        hoursText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: caution ? amber : mutedColor,
                          fontWeight: caution ? FontWeight.w600 : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
        if (widget.footnote != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.footnote!,
            style: theme.textTheme.labelSmall?.copyWith(color: mutedColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// "Stay: 1h 30m" — borderless text button in the primary color, the
  /// affordance for editing how long the user plans to spend at this stop
  /// (the detail modal's old "Set Stay" button now lives here, visible at a
  /// glance in the plan list).
  Widget _buildStayButton(BuildContext context, bool canEdit) {
    final theme = Theme.of(context);

    return TextButton.icon(
      onPressed: canEdit
          ? () => _run(() => showStayDurationDialog(context, ref, location))
          : null,
      icon: const Icon(Icons.timer_outlined, size: 14),
      label: Text('Stay: ${_formatDuration(location.stayDuration)}'),
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.primary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle:
            theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  /// Day labels for this row's trip ("Day N" while it has no dates).
  DayLabeler get _labeler =>
      widget.labeler ?? ref.read(activeTripDayLabelerProvider);

  /// Hours line when the trip has no weekday to look up: one line when
  /// every weekday shares the same periods, otherwise a nudge to set dates.
  String _undatedHoursSubtitle(List<OpeningPeriod> hours) {
    String? common;
    for (var day = 0; day < 7; day++) {
      final periods = hours.where((p) => p.openDay == day).map((p) {
        final open = _formatClockMinutes(p.openMinutes);
        final close = p.closeMinutes;
        return close == null
            ? 'Opens $open'
            : '$open – ${_formatClockMinutes(close)}';
      }).join(', ');
      if (periods.isEmpty) return 'Hours vary by day — set trip dates to check';
      if (common == null) {
        common = periods;
      } else if (common != periods) {
        return 'Hours vary by day — set trip dates to check';
      }
    }
    return common ?? 'Opening and closing time not found';
  }

  /// Compact hotel chip surfaced next to the title when this location is a
  /// multi-day stay. Reads `scheduledDate`/`scheduledEndDate` directly —
  /// guarded by [LocationModel.isMultiDay] at the call site, so both are
  /// non-null here.
  Widget _buildStayChip(BuildContext context) {
    final theme = Theme.of(context);
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
            _labeler.range(start, end),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleTap(BuildContext context, WidgetRef ref,
      bool isSelectionMode, bool isSelected) async {
    if (isSelectionMode) {
      final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
      if (isSelected) {
        selectedNotifier.update((state) => state.difference({location.id}));
      } else {
        selectedNotifier.update((state) => state.union({location.id}));
      }
      return;
    }
    await _run(() {
      if (!context.mounted) return;
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
          locationsForDate: widget.siblings,
          tripId: widget.tripId,
        ),
      );
    });
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
    BuildContext context,
    WidgetRef ref,
    ButtonStyle style, {
    required bool hasWriteAccess,
    required bool canEdit,
  }) {
    return _buildPopupMenu(
      context,
      ref,
      hasWriteAccess: hasWriteAccess,
      canEdit: canEdit,
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

  Widget _buildPopupMenu(
    BuildContext context,
    WidgetRef ref, {
    required bool hasWriteAccess,
    required bool canEdit,
    Widget? child,
  }) {
    // "Move to another trip" and "Remove from trip" only make sense for a
    // place that is IN a trip; loose places on the map use the detail
    // sheet's "Add to trip" instead.
    final tripId = widget.tripId;
    final canRemoveFromTrip = tripId != null && hasWriteAccess;

    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      // Rounded corners must clip the ListTile ink of the first/last items.
      clipBehavior: Clip.antiAlias,
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
        _run(() => _handleMenuSelection(context, value, ref, tripId));
      },
      itemBuilder: (context) {
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
            value: 'move',
            enabled: canEdit,
            child: ListTile(
                leading: Icon(Icons.calendar_today_outlined,
                    color: canEdit ? null : Colors.grey),
                title: Text('Move to another day',
                    style: TextStyle(color: canEdit ? null : Colors.grey))),
          ),
          // Only a place that is IN a trip can move to another one; loose
          // places use "Add to trip" from the detail sheet instead.
          if (tripId != null)
            PopupMenuItem<String>(
              value: 'move_trip',
              enabled: hasWriteAccess,
              child: ListTile(
                  leading: Icon(Icons.luggage_outlined,
                      color: hasWriteAccess ? null : Colors.grey),
                  title: Text('Move to another trip',
                      style: TextStyle(
                          color: hasWriteAccess ? null : Colors.grey))),
            ),
          const PopupMenuItem<String>(
            value: 'copy',
            child: ListTile(
                leading: Icon(Icons.copy), title: Text('Copy to another day')),
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
    } else if (value == 'move_trip') {
      showMoveToTripSheet(context, ref, [location]);
    } else if (value == 'copy') {
      _showMoveCopyDialog(context, ref, isCopy: true);
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
    // A copy creates a new place row: an add like any other, so it is Pro.
    if (isCopy && !await SubscriptionLimitService(ref).canAddPlace(context)) {
      return;
    }
    if (!context.mounted) return;
    final highlightedDates = ref.read(datesWithLocationsProvider);
    final earliestDate = highlightedDates.isNotEmpty
        ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
        : DateTime.now();

    final labeler = ref.read(activeTripDayLabelerProvider);
    final DateTime? newDate;
    if (labeler.tbd) {
      newDate = await showTripDayPicker(
        context,
        days: ref.read(activeTripDayAxisProvider),
        labeler: labeler,
        selected: widget.day ?? ref.read(selectedDateProvider),
        marked: highlightedDates,
      );
    } else {
      newDate = await DatePickerUtils.showCustomDatePicker(
        context: context,
        initialDate: widget.day ?? ref.read(selectedDateProvider),
        firstDate: earliestDate,
        lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
        highlightedDates: highlightedDates,
        highlightRange: activeTripDateRange(ref),
      );
    }

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
      // The plan sheet follows the move to its new day; the trip page shows
      // every day and never yanks the map's day. Decided now: the card may
      // be gone by the time the write lands.
      final followsDay = widget.day == null ||
          _sameDay(widget.day!, ref.read(selectedDateProvider));
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
          AppToast.warning(
              context, '"${location.name}" is already on ${_labeler(dayKey)}');
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
      if (followsDay) dateNotifier.state = newDate;
    }
  }

  void _showDeleteConfirmationDialog(BuildContext context, WidgetRef ref) {
    // A multi-day row (e.g. an accommodation spanning the trip) viewed on
    // one of its days: deleting must NOT wipe the whole span. Offer
    // "remove from this day" (shrinks/splits the range) as the primary
    // action, with delete-everywhere as the explicit destructive choice.
    final DateTime selectedDate = widget.day ?? ref.read(selectedDateProvider);
    final day =
        DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    // Unscheduled rows have no span; a plain delete is the only option.
    final startRaw = location.scheduledDate;
    final start = startRaw == null
        ? null
        : DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = location.scheduledEndDate ?? startRaw;
    final end =
        endRaw == null ? null : DateTime(endRaw.year, endRaw.month, endRaw.day);
    final spansHere = start != null &&
        end != null &&
        end.isAfter(start) &&
        !day.isBefore(start) &&
        !day.isAfter(end);

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
                  '${_labeler.range(start, end)}. '
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
                      '${location.name} removed from ${_labeler(day)}');
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
}
