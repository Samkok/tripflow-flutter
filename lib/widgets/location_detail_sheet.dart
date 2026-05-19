import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart' show OpeningPeriod;
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/services/timing_simulation.dart' show kNeverCloses;
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/external_app_links.dart';
import 'package:voyza/utils/trip_date_validator.dart';

import '../core/theme.dart';
import 'app_toast.dart';

class LocationDetailSheet extends ConsumerWidget {
  final LocationModel location;
  final int number;
  final ScrollController parentScrollController;
  final DraggableScrollableController? parentSheetController;
  final Function(LatLng)? onLocationTap;
  /// When opened from a context that isn't the active map trip (e.g. trip
  /// details screen), pass the sibling locations for the same date here so
  /// the From/To picker shows the correct list instead of the active-trip list.
  final List<LocationModel>? locationsForDate;
  /// When opened from trip details for a non-active trip, pass the trip ID
  /// so the multi-day stay section's permission check and write path target
  /// the right trip (instead of the active-map trip). Null = use the active
  /// trip's permissions (default for the map sheet).
  final String? tripId;

  const LocationDetailSheet({
    super.key,
    required this.location,
    required this.number,
    required this.parentScrollController,
    this.parentSheetController,
    this.onLocationTap,
    this.locationsForDate,
    this.tripId,
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

          // Hours section — Google's hours for the planned day + user override
          // for the closing-time-aware optimizer. Only shown when there's
          // something to show (Google data, user override, or a placeId that
          // makes refresh actionable) so empty manual-coord rows don't get a
          // dead section.
          if (_hasAnyHoursAffordance(updatedLocation)) ...[
            const Divider(height: 32),
            _buildHoursSection(context, ref, updatedLocation, isPastDate),
          ],

          // Multi-day stay section — lets the user mark this location as an
          // accommodation that spans multiple days, with quick actions for
          // single-day / pick-range / entire-trip. Shown for any editable
          // stop (no extra gating; useful for hotels, residencies, etc.).
          const Divider(height: 32),
          _buildMultiDaySection(context, ref, updatedLocation, isPastDate),

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
                  : updatedLocation.isSkipped
                      ? Colors.grey.shade600
                      : Theme.of(context).colorScheme.primary,
              radius: 24,
              child: updatedLocation.isDone
                  ? const Icon(Icons.check, color: Colors.white, size: 24)
                  : updatedLocation.isSkipped
                      // Skipped stops drop out of the optimized route, so
                      // the index number is meaningless — replace it with
                      // a minus glyph and let the label below say just
                      // "Stop" (no number).
                      ? const Icon(Icons.remove,
                          color: Colors.white, size: 24)
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
                  updatedLocation.isDone
                      ? 'Done'
                      : updatedLocation.isSkipped
                          ? 'Stop'
                          : 'Stop $number',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: updatedLocation.isDone
                            ? Colors.green.shade500
                            : updatedLocation.isSkipped
                                ? Colors.grey.shade600
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
            // Skip / Unskip button — when skipped, the location stays
            // pinned but the route optimizer excludes it. Lets the user
            // temporarily pull a stop out of the plan without losing
            // it. Toggle reflects the current state.
            Tooltip(
              message: updatedLocation.isSkipped ? 'Unskip' : 'Skip',
              child: GestureDetector(
                onTap: hasWriteAccess
                    ? () {
                        final notifier = ref.read(tripProvider.notifier);
                        if (updatedLocation.isSkipped) {
                          notifier
                              .unskipMultipleLocations({updatedLocation.id});
                        } else {
                          notifier
                              .skipMultipleLocations({updatedLocation.id});
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
                        : updatedLocation.isSkipped
                            ? Colors.grey[700]
                            : Colors.orange[700],
                  ),
                  child: Icon(
                    updatedLocation.isSkipped
                        ? Icons.refresh_rounded
                        : Icons.remove_circle_outline,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
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
                        if (newDate == null) return;
                        final normalized = DateTime(
                            newDate.year, newDate.month, newDate.day);
                        final activeTrip = ref
                            .read(realtimeActiveTripProvider)
                            .asData
                            ?.value;
                        if (!context.mounted) return;
                        final allowed = await ensureScheduledDateAllowed(
                          context,
                          activeTrip,
                          normalized,
                          actionLabel: 'Save anyway',
                        );
                        if (!allowed) return;
                        ref
                            .read(tripProvider.notifier)
                            .updateLocationScheduledDate(
                                updatedLocation.id, normalized);
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
                onPressed: () => _openGoogleMaps(updatedLocation),
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
        // Route preview row — pick another stop to use as the start ("From")
        // or end ("To") of a single-leg route drawn on the map. Disabled
        // when there's no other location on the selected date to pair with.
        //
        // `locationsForDate` (field) is set by callers outside the active-trip
        // context (e.g. trip details screen) so the picker shows the correct
        // sibling list rather than the active-map-trip list.
        Builder(builder: (context) {
          final List<LocationModel> effectiveLocations = locationsForDate ??
              ref.watch(locationsForSelectedDateProvider);
          final others = effectiveLocations
              .where((l) => l.id != updatedLocation.id)
              .toList();
          final canRoute = others.isNotEmpty;
          final primary = Theme.of(context).colorScheme.primary;
          OutlinedButton btn({
            required IconData icon,
            required String label,
            required VoidCallback? onPressed,
          }) {
            return OutlinedButton.icon(
              icon: Icon(icon,
                  size: 18,
                  color: canRoute ? primary : Colors.grey),
              label: Text(label),
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 8),
                side: BorderSide(
                  color: canRoute
                      ? primary.withValues(alpha: 0.3)
                      : Colors.grey.withValues(alpha: 0.3),
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: btn(
                    icon: Icons.flag_outlined,
                    label: 'From',
                    onPressed: !canRoute
                        ? null
                        : () => _pickAndPreviewRoute(
                              context: context,
                              ref: ref,
                              current: updatedLocation,
                              others: others,
                              role: _RouteEndpoint.from,
                            ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: btn(
                    icon: Icons.place_outlined,
                    label: 'To',
                    onPressed: !canRoute
                        ? null
                        : () => _pickAndPreviewRoute(
                              context: context,
                              ref: ref,
                              current: updatedLocation,
                              others: others,
                              role: _RouteEndpoint.to,
                            ),
                  ),
                ),
              ],
            ),
          );
        }),
        // "Remove from trip" — unlinks the location from its trip (sets
        // trip_id to null) without deleting it. Hidden when the location
        // isn't currently in a trip. The repository write goes through
        // directly (mirroring the delete bypass in trip details) so it
        // works regardless of whether the location's trip is the active
        // map trip — RLS still enforces real permissions.
        if (canEdit && updatedLocation.tripId != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: Icon(Icons.link_off_rounded,
                    size: 18, color: Colors.orange.shade700),
                label: Text(
                  'Remove from trip',
                  style: TextStyle(color: Colors.orange.shade700),
                ),
                onPressed: () => _confirmRemoveFromTrip(
                    context, ref, updatedLocation),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      vertical: 10, horizontal: 8),
                  side: BorderSide(
                    color: Colors.orange.shade700.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Asks for confirmation, then unassigns [loc] from its trip via the
  /// repository (sets `trip_id` to null). Doesn't delete the location.
  Future<void> _confirmRemoveFromTrip(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove from trip?'),
        content: Text(
          '"${loc.name}" will be moved out of its trip but stay in your '
          'saved locations. You can attach it to another trip later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.shade700,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final navigator = Navigator.of(context);
    try {
      await ref
          .read(locationRepositoryProvider)
          .updateLocation(loc.id, {'trip_id': null});
      if (!context.mounted) return;
      // Close the detail sheet — the location no longer belongs to the
      // trip being viewed, so showing it here would be misleading.
      if (navigator.canPop()) navigator.pop();
      if (context.mounted) {
        AppToast.success(context, 'Removed ${loc.name} from trip');
      }
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'Could not remove from trip: $e');
    }
  }

  /// Opens a small picker listing the other locations on the selected date.
  /// On pick: dismiss the picker → dismiss this detail sheet → collapse the
  /// parent trip-plan bottom sheet → scroll its list to the top → render
  /// the From→To route on the map.
  ///
  /// The collapse-then-scroll order (and post-collapse jumpTo) mirrors the
  /// View Route flow in trip_bottom_sheet.dart: animating the inner scroll
  /// while the DraggableScrollableSheet is shrinking fights its physics.
  Future<void> _pickAndPreviewRoute({
    required BuildContext context,
    required WidgetRef ref,
    required LocationModel current,
    required List<LocationModel> others,
    required _RouteEndpoint role,
  }) async {
    final picked = await showModalBottomSheet<LocationModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _RouteEndpointPicker(
        title: role == _RouteEndpoint.from
            ? 'Pick start location'
            : 'Pick destination',
        subtitle: role == _RouteEndpoint.from
            ? 'Route will go from the picked stop to ${current.name}'
            : 'Route will go from ${current.name} to the picked stop',
        candidates: others,
      ),
    );
    if (picked == null) return;

    // Resolve which is from/to.
    final from = role == _RouteEndpoint.from ? picked : current;
    final to = role == _RouteEndpoint.from ? current : picked;

    // 1. Dismiss the detail sheet itself.
    if (context.mounted) Navigator.of(context).pop();

    // 2. Collapse the parent trip-plan sheet, then jump the inner list to
    //    top once the collapse animation lands.
    final collapse = parentSheetController?.animateTo(
      0.12,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    void resetScroll() {
      if (parentScrollController.hasClients) {
        parentScrollController.jumpTo(0);
      }
    }
    if (collapse != null) {
      collapse.then((_) => resetScroll());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => resetScroll());
    }

    // 3. Kick off the route render. previewRouteBetween populates the same
    //    state slots the map overlay reads from, so the polyline appears
    //    without any further wiring here.
    await ref.read(tripProvider.notifier).previewRouteBetween(from, to);
  }

  // ─── Hours section ────────────────────────────────────────────────────

  /// Whether to render the hours block at all. Hidden for manual-coord rows
  /// with no Google data, no user override, and no placeId to refresh from —
  /// otherwise we'd show an empty section the user can't act on.
  bool _hasAnyHoursAffordance(LocationModel loc) {
    return loc.googleOpeningHours != null ||
        loc.userClosingMinuteOverride != null ||
        (loc.placeId != null && loc.placeId!.isNotEmpty);
  }

  static const _weekdayNames = [
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  /// Dart `DateTime.weekday` is 1=Mon..7=Sun; Google's `periods[].open.day`
  /// is 0=Sun..6=Sat. We store rows in Google's convention, so translate at
  /// the boundary.
  int _googleDayFor(DateTime date) =>
      date.weekday == DateTime.sunday ? 0 : date.weekday;

  String _formatMinutes(int minutes) {
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String _formatRelative(DateTime past) {
    final diff = DateTime.now().difference(past);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }

  /// Renders Google's hours for [googleDay] as one or two lines:
  ///   • "Open 24 hours" for an always-open marker.
  ///   • "09:00 – 22:00" for a single period.
  ///   • "09:00 – 13:00, 14:00 – 22:00" for split hours (lunch break, etc).
  ///   • "Closed" when no period covers this day.
  String _formatGoogleHoursForDay(
      List<OpeningPeriod>? hours, int googleDay) {
    if (hours == null || hours.isEmpty) return 'No data';
    if (hours.length == 1 && hours.first.isAlwaysOpen) {
      return 'Open 24 hours';
    }
    final periodsForDay = hours.where((p) => p.openDay == googleDay).toList();
    if (periodsForDay.isEmpty) return 'Closed';
    return periodsForDay.map((p) {
      final open = _formatMinutes(p.openMinutes);
      if (p.closeMinutes == null) return 'Opens $open';
      return '$open – ${_formatMinutes(p.closeMinutes!)}';
    }).join(', ');
  }

  /// Default minutes for the override time picker when the user hasn't set
  /// one yet — pre-fills with Google's first close time on the planned day,
  /// or 22:00 as a sensible neutral fallback.
  int _defaultClosingForDay(List<OpeningPeriod>? hours, int googleDay) {
    if (hours != null) {
      for (final p in hours) {
        if (p.openDay == googleDay && p.closeMinutes != null) {
          return p.closeMinutes!;
        }
      }
    }
    return 22 * 60;
  }

  Widget _buildHoursSection(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
    bool isPastDate,
  ) {
    final theme = Theme.of(context);
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess =
        hasWriteAccessAsync.whenOrNull(data: (v) => v) ?? false;
    final canEdit = !isPastDate && hasWriteAccess;

    final selectedDate = ref.watch(selectedDateProvider);
    final googleDay = _googleDayFor(selectedDate);
    final dayLabel = _weekdayNames[googleDay];

    final googleHours = loc.googleOpeningHours;
    final overrideMin = loc.userClosingMinuteOverride;
    final placeId = loc.placeId;
    final canRefresh = placeId != null && placeId.isNotEmpty;

    final googleSummary = _formatGoogleHoursForDay(googleHours, googleDay);
    final defaultClose = _defaultClosingForDay(googleHours, googleDay);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.access_time_rounded,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Hours',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (canRefresh)
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Refresh from Google',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: canEdit ? () => _refreshHours(context, ref, loc) : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '$dayLabel · $googleSummary',
          style: theme.textTheme.bodyMedium,
        ),
        if (loc.hoursLastRefreshedAt != null) ...[
          const SizedBox(height: 4),
          Text(
            'Updated ${_formatRelative(loc.hoursLastRefreshedAt!)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Close by:', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.schedule_outlined,
                  size: 16,
                  color: canEdit ? theme.colorScheme.primary : Colors.grey),
              label: Text(
                overrideMin == null
                    ? 'Set'
                    : overrideMin == kNeverCloses
                        ? 'Never'
                        : _formatMinutes(overrideMin),
              ),
              onPressed: canEdit
                  ? () => _editClosingOverride(context, ref, loc, defaultClose)
                  : null,
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                side: BorderSide(
                  color: canEdit
                      ? theme.colorScheme.primary.withValues(alpha: 0.4)
                      : Colors.grey.withValues(alpha: 0.3),
                ),
              ),
            ),
            if (overrideMin != null && canEdit)
              TextButton(
                onPressed: () => ref
                    .read(tripProvider.notifier)
                    .setUserClosingMinuteOverride(loc.id, null),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Reset'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _editClosingOverride(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
    int defaultMinutes,
  ) async {
    // Let the user choose between a specific time or "never closes."
    final action = await showDialog<_OverrideAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close by'),
        content: const Text(
          'When should the optimizer treat this place as closed?\n\n'
          '"Never" is useful for accommodations or stops with no closing time.',
        ),
        // Default `actions:` go through OverflowBar, which lays children at
        // their intrinsic width and wraps to a column when they don't fit —
        // with three labels here that always happens. We instead hand back a
        // single Row with Expanded children so the three buttons share the
        // dialog width evenly. FittedBox scales any label down if a
        // longer translation would still bust the constraint.
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(_OverrideAction.never),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Never closes'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(_OverrideAction.pickTime),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Pick a time'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (action == null) return;

    if (action == _OverrideAction.never) {
      await ref
          .read(tripProvider.notifier)
          .setUserClosingMinuteOverride(loc.id, kNeverCloses);
      return;
    }

    if (!context.mounted) return;
    final current = loc.userClosingMinuteOverride;
    final initial = (current != null && current != kNeverCloses)
        ? current
        : defaultMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
      helpText: 'Close by',
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    await ref
        .read(tripProvider.notifier)
        .setUserClosingMinuteOverride(loc.id, minutes);
  }

  Future<void> _refreshHours(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    final placeId = loc.placeId;
    if (placeId == null || placeId.isEmpty) return;

    AppToast.info(
      context,
      'Refreshing hours…',
      duration: const Duration(seconds: 1),
    );
    final ok = await ref
        .read(tripProvider.notifier)
        .refreshLocationHours(loc.id, placeId);
    if (!context.mounted) return;
    if (ok) {
      AppToast.success(context, 'Hours updated');
    } else {
      AppToast.error(context, 'Could not refresh hours — try again later');
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Multi-day stay section
  // ──────────────────────────────────────────────────────────────────────

  Widget _buildMultiDaySection(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
    bool isPastDate,
  ) {
    final theme = Theme.of(context);
    // When the sheet was opened with an explicit [tripId] (trip details
    // screen for a non-active trip), check write access against THAT trip
    // — otherwise the gate uses the active-trip permission and the button
    // gets disabled for any non-active trip even when the user owns it.
    final hasWriteAccessAsync = tripId != null
        ? ref.watch(hasWriteAccessProvider(tripId!))
        : ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess =
        hasWriteAccessAsync.whenOrNull(data: (v) => v) ?? false;
    final canEdit = !isPastDate && hasWriteAccess;

    final start = loc.scheduledDate;
    final end = loc.scheduledEndDate;
    final isMultiDay = loc.isMultiDay;

    // Resolve trip date range for the picker bounds and the "Entire trip"
    // quick-set affordance. Prefer the explicit [tripId]'s trip when set;
    // otherwise fall back to the active trip.
    Trip? scopedTrip;
    if (tripId != null) {
      final all = ref.watch(userTripsProvider).asData?.value ?? const <Trip>[];
      for (final t in all) {
        if (t.id == tripId) {
          scopedTrip = t;
          break;
        }
      }
    }
    scopedTrip ??= ref.watch(realtimeActiveTripProvider).asData?.value;
    final tripStart = scopedTrip?.startDate;
    final tripEnd = scopedTrip?.endDate;
    final tripHasRange = tripStart != null && tripEnd != null;

    String statusLabel;
    if (isMultiDay && start != null && end != null) {
      final df = DateFormat('MMM d');
      statusLabel = '${df.format(start)} – ${df.format(end)}'
          ' · ${_daysBetween(start, end)} days';
    } else if (start != null) {
      statusLabel = 'Single day · ${DateFormat('MMM d, y').format(start)}';
    } else {
      statusLabel = 'Not scheduled';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isMultiDay
                  ? Icons.hotel_outlined
                  : Icons.event_available_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'Multi-day stay',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(statusLabel, style: theme.textTheme.bodyMedium),
        if (isMultiDay) ...[
          const SizedBox(height: 2),
          Text(
            'Appears on every day in this range — useful for hotels and '
            'places you keep coming back to.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range_outlined, size: 16),
              label: Text(isMultiDay ? 'Edit dates' : 'Set range'),
              onPressed: canEdit ? () => _pickStayRange(context, ref, loc) : null,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                side: BorderSide(
                  color: canEdit
                      ? theme.colorScheme.primary.withValues(alpha: 0.4)
                      : Colors.grey.withValues(alpha: 0.3),
                ),
              ),
            ),
            if (tripHasRange)
              OutlinedButton.icon(
                icon: const Icon(Icons.all_inclusive, size: 16),
                label: const Text('Entire trip'),
                onPressed: canEdit
                    ? () => _applyEntireTripRange(
                        context, ref, loc, tripStart, tripEnd)
                    : null,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  side: BorderSide(
                    color: canEdit
                        ? theme.colorScheme.primary.withValues(alpha: 0.4)
                        : Colors.grey.withValues(alpha: 0.3),
                  ),
                ),
              ),
            if (isMultiDay && canEdit)
              TextButton.icon(
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onPressed: () => _clearStayRange(context, ref, loc),
              ),
          ],
        ),
      ],
    );
  }

  int _daysBetween(DateTime a, DateTime b) {
    final s = DateTime(a.year, a.month, a.day);
    final e = DateTime(b.year, b.month, b.day);
    return e.difference(s).inDays + 1;
  }

  DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Resolves the trip whose date range frames the picker. Mirrors the
  /// logic in [_buildMultiDaySection] so the picker bounds and the section
  /// agree on which trip is in scope.
  Trip? _scopedTrip(WidgetRef ref) {
    if (tripId != null) {
      final all = ref.read(userTripsProvider).asData?.value ?? const <Trip>[];
      for (final t in all) {
        if (t.id == tripId) return t;
      }
    }
    return ref.read(realtimeActiveTripProvider).asData?.value;
  }

  /// Pushes the new range to storage. Goes through the [tripProvider]
  /// notifier (which threads through optimistic local state) when no
  /// explicit [tripId] is set — that path's permission check is tied to
  /// the active trip, which is correct in that context. When [tripId] is
  /// set (trip details screen for a non-active trip), call the repository
  /// directly — Supabase RLS still enforces access, but we don't fail
  /// silently against the wrong trip's permission gate.
  Future<void> _writeDateRange(
    WidgetRef ref,
    String locationId,
    DateTime start,
    DateTime? end,
  ) async {
    if (tripId == null) {
      await ref
          .read(tripProvider.notifier)
          .setLocationDateRange(locationId, start, end);
      return;
    }
    final startKey = _dayKey(start);
    DateTime? endKey;
    if (end != null) {
      final candidate = _dayKey(end);
      if (candidate.isAfter(startKey)) endKey = candidate;
    }
    await ref.read(locationRepositoryProvider).updateLocation(
      locationId,
      {
        'scheduled_date': startKey.toIso8601String(),
        'scheduled_end_date': endKey?.toIso8601String(),
      },
    );
  }

  Future<void> _pickStayRange(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    final scopedTrip = _scopedTrip(ref);
    final today = _dayKey(DateTime.now());
    final initialStart = _dayKey(loc.scheduledDate ?? today);
    final initialEnd = _dayKey(loc.scheduledEndDate ?? loc.scheduledDate ?? today);

    // Bounds must always include the existing range — otherwise the picker
    // throws when the location was already scheduled outside the trip's
    // dates. Take the min/max across trip range, current range, and a
    // wide fallback window so the picker always opens.
    final fallbackFirst = today.subtract(const Duration(days: 365));
    final fallbackLast = today.add(const Duration(days: 365 * 5));
    final firstCandidates = <DateTime>[
      if (scopedTrip?.startDate != null) _dayKey(scopedTrip!.startDate!),
      initialStart,
      fallbackFirst,
    ];
    final lastCandidates = <DateTime>[
      if (scopedTrip?.endDate != null) _dayKey(scopedTrip!.endDate!),
      initialEnd,
      fallbackLast,
    ];
    final firstDate =
        firstCandidates.reduce((a, b) => a.isBefore(b) ? a : b);
    final lastDate =
        lastCandidates.reduce((a, b) => a.isAfter(b) ? a : b);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: DateTimeRange(start: initialStart, end: initialEnd),
      helpText: 'Stay range',
      saveText: 'Set',
    );
    if (picked == null) return;
    try {
      await _writeDateRange(ref, loc.id, picked.start, picked.end);
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'Could not save range: $e');
    }
  }

  Future<void> _applyEntireTripRange(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
    DateTime tripStart,
    DateTime tripEnd,
  ) async {
    try {
      await _writeDateRange(ref, loc.id, tripStart, tripEnd);
      if (!context.mounted) return;
      final df = DateFormat('MMM d');
      AppToast.success(
        context,
        'Set to entire trip · ${df.format(tripStart)} – ${df.format(tripEnd)}',
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'Could not apply range: $e');
    }
  }

  Future<void> _clearStayRange(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    final start = loc.scheduledDate ?? DateTime.now();
    try {
      await _writeDateRange(ref, loc.id, start, null);
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'Could not clear range: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────

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

  Future<void> _openGoogleMaps(LocationModel loc) =>
      openLocationInGoogleMaps(loc);

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
                borderSide: const BorderSide(color: AppTheme.primaryColor, width: 2),
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

                if (context.mounted) {
                  AppToast.error(context, 'Deleted ${location.name}');
                }
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

/// Whether the picked stop should be used as the route's start ("from") or
/// end ("to"). The detail sheet's anchor location takes the opposite role.
enum _RouteEndpoint { from, to }

enum _OverrideAction { pickTime, never }

class _RouteEndpointPicker extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<LocationModel> candidates;

  const _RouteEndpointPicker({
    required this.title,
    required this.subtitle,
    required this.candidates,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 12),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Cancel',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                itemCount: candidates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, i) {
                  final loc = candidates[i];
                  return Material(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.of(context).pop(loc),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: theme.colorScheme.primary
                                  .withValues(alpha: 0.15),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loc.name,
                                    style: theme.textTheme.titleSmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (loc.address.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      loc.address,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 22),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
