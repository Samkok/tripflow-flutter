import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/detail_sheet_ui_provider.dart';
import 'package:voyza/widgets/stay_duration_dialog.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart'
    show OpeningPeriod, SavedLocation;
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/services/country_match_service.dart';
import 'package:voyza/services/place_photo_refresh_service.dart';
import 'package:voyza/services/timing_simulation.dart' show kNeverCloses;
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/utils/place_tags.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/search_text.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/place_photo_refresh_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/place_floor_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/external_app_links.dart';
import 'package:voyza/utils/trip_date_validator.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/widgets/trip_day_picker.dart';
import 'package:voyza/widgets/trip_collaborators_row.dart';

import '../core/theme.dart';
import 'accommodation_prompts.dart';
import 'add_to_trip_sheet.dart';
import 'app_toast.dart';
import 'location_photo_gallery.dart';
import 'place_tag_sheet.dart';

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

    // One access answer for the whole sheet: the row's trip when the sheet
    // was opened for one, else the map trip's. Retained through reloads.
    final hasWriteAccess = tripId != null
        ? ref.watch(hasWriteAccessProvider(tripId!)
            .select((a) => a.valueOrNull ?? false))
        : ref.watch(hasActiveTripWriteAccessProvider
            .select((a) => a.valueOrNull ?? false));

    // The gating day: the row's own day when the sheet knows its trip (a
    // bucket row — no day — is never past); the map's selected day for a
    // loose place on the map.
    final selectedDate = ref.watch(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final DateTime gateDay;
    final bool isPastDate;
    if (tripId != null) {
      final own = updatedLocation.scheduledDate;
      gateDay = own ?? selectedDate;
      isPastDate =
          own != null && DateTime(own.year, own.month, own.day).isBefore(today);
    } else {
      gateDay = selectedDate;
      isPastDate = selectedDate.isBefore(today);
    }
    final canEdit = hasWriteAccess && !isPastDate;
    final detailsOpen = ref.watch(detailSheetDetailsOpenProvider);
    final photosOpen = ref.watch(detailSheetPhotosOpenProvider);
    final hoursOpen = ref.watch(detailSheetHoursOpenProvider);

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
      // The sheet has no fixed height — it sizes to its content. Wrapping in
      // a scroll view keeps every section reachable (and constraint-safe) on
      // small screens now that the photo strip adds height; when the content
      // fits, MainAxisSize.min keeps the sheet hugging it exactly as before.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // DRAG ZONE — deliberately OUTSIDE the scroll view below. A
          // vertical drag here isn't consumed by a scrollable, so it reaches
          // showModalBottomSheet's own drag handling and dismisses the sheet
          // with the native follow-and-spring. Spans the top of the modal
          // down through the location name.
          _buildHeader(context, ref, updatedLocation,
              hasWriteAccess: hasWriteAccess, canEdit: canEdit),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeaderBody(context, ref, updatedLocation),

                  // The rest, folded: what a place IS (tag, stay, hotel,
                  // range, floor) under one row, photos and hours under
                  // theirs. Opened sections stay open for the session.
                  const SizedBox(height: 8),
                  _SectionExpander(
                    icon: Icons.tune_rounded,
                    title: 'Details',
                    subtitle: _detailsSummary(updatedLocation),
                    open: detailsOpen,
                    onToggle: () => ref
                        .read(detailSheetDetailsOpenProvider.notifier)
                        .state = !detailsOpen,
                    children: [
                      _buildTagSection(context, ref, updatedLocation,
                          hasWriteAccess: hasWriteAccess),
                      const Divider(height: 28),
                      _buildStayDurationRow(context, ref, updatedLocation,
                          canEdit: canEdit),
                      const Divider(height: 28),
                      _buildAccommodationSection(context, ref, updatedLocation,
                          hasWriteAccess: hasWriteAccess),
                      const Divider(height: 28),
                      _buildMultiDaySection(context, ref, updatedLocation,
                          hasWriteAccess: hasWriteAccess,
                          isPastDate: isPastDate),
                      _buildFloorLine(context, ref, updatedLocation),
                    ],
                  ),
                  if (updatedLocation.photoReferences.isNotEmpty)
                    _SectionExpander(
                      icon: Icons.photo_library_outlined,
                      title: 'Photos',
                      subtitle:
                          '${updatedLocation.photoReferences.length} from Google',
                      open: photosOpen,
                      onToggle: () => ref
                          .read(detailSheetPhotosOpenProvider.notifier)
                          .state = !photosOpen,
                      children: [
                        _buildPhotosSection(context, ref, updatedLocation),
                      ],
                    ),
                  if (_hasAnyHoursAffordance(updatedLocation))
                    _SectionExpander(
                      icon: Icons.schedule_rounded,
                      title: 'Hours',
                      open: hoursOpen,
                      onToggle: () => ref
                          .read(detailSheetHoursOpenProvider.notifier)
                          .state = !hoursOpen,
                      children: [
                        _buildHoursSection(context, ref, updatedLocation,
                            hasWriteAccess: hasWriteAccess,
                            isPastDate: isPastDate,
                            gateDay: gateDay),
                      ],
                    ),

                  // Travel info (if available)
                  if (updatedLocation.travelTimeFromPrevious != null &&
                      updatedLocation.distanceFromPrevious != null) ...[
                    const Divider(height: 32),
                    _buildTravelInfo(context, ref, updatedLocation),
                  ],

                  // Who put this place in the trip (signed-in, trip places).
                  ..._buildAddedBySection(context, ref, updatedLocation),

                  const Divider(height: 32),
                  _buildDangerZone(context, ref, updatedLocation,
                      hasWriteAccess: hasWriteAccess, canEdit: canEdit),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Accommodation ───────────────────────────────────────────────────────
  // (Trip scoping reuses the existing [_scopedTrip] helper below.)

  /// The trip's EFFECTIVE day range: its declared start/end dates AND every
  /// day its locations are scheduled on, gap-filled ([contiguousTripDates]).
  /// A trip with no declared dates but scheduled places still has a real
  /// range — the scheduled days ARE the range. Empty only when nothing is
  /// dated anywhere. Falls back to the active map content when [trip] is
  /// null (anonymous / no active trip).
  List<DateTime> _effectiveTripDays(WidgetRef ref, Trip? trip) {
    final marks = <DateTime?>[trip?.startDate, trip?.endDate];
    if (trip != null) {
      final all = ref.read(savedLocationsProvider).asData?.value ??
          const <SavedLocation>[];
      for (final l in all) {
        if (l.tripId != trip.id) continue;
        marks.add(l.scheduledDate); // null (unscheduled) doesn't stretch axis
        marks.add(l.scheduledEndDate);
      }
    } else {
      for (final l in ref.read(tripProvider).pinnedLocations) {
        marks.add(l.scheduledDate); // null (unscheduled) doesn't stretch axis
        marks.add(l.scheduledEndDate);
      }
    }
    return contiguousTripDates(marks);
  }

  /// Tag chips: the current tag is filled, the Google-type suggestion (for
  /// an untagged stop) is outlined; tapping the current tag clears it.
  Widget _buildTagSection(
      BuildContext context, WidgetRef ref, LocationModel loc,
      {required bool hasWriteAccess}) {
    final theme = Theme.of(context);
    final current = placeTagFromKey(loc.tag);
    final suggested = current == null ? suggestPlaceTag(loc.placeTypes) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.label_outline_rounded,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Tag',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (suggested != null) ...[
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Suggested: ${placeTagLabel(suggested, loc.placeTypes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in PlaceTag.values)
              PlaceTagChip(
                tag: t,
                selected: t == current,
                highlighted: t == suggested,
                placeTypes: loc.placeTypes,
                onTap: hasWriteAccess
                    ? () => _setTag(ref, loc, t == current ? null : t)
                    : null,
              ),
          ],
        ),
        if (current == PlaceTag.transport)
          _buildTransportModeRow(context, ref, loc, hasWriteAccess),
      ],
    );
  }

  /// Under a Transport tag: what kind of transport this is. Google's place
  /// type decides on its own; tapping a chip overrides it (kept with the
  /// place, so it syncs), and tapping the chosen chip again hands the
  /// decision back to Google.
  Widget _buildTransportModeRow(BuildContext context, WidgetRef ref,
      LocationModel loc, bool hasWriteAccess) {
    final theme = Theme.of(context);
    final shown = transportModeFor(loc.placeTypes);
    final chosen = transportModeOverride(loc.placeTypes);
    final String hint;
    if (chosen != null) {
      hint = 'Set by you — tap it again to use Google\'s type.';
    } else if (shown != TransportMode.other) {
      hint = 'From Google\'s place type — tap another to correct it.';
    } else {
      hint = 'Google didn\'t say what kind of transport this is — pick one.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in TransportMode.values)
              if (m != TransportMode.other)
                TransportModeChip(
                  mode: m,
                  selected: m == shown,
                  onTap: hasWriteAccess
                      ? () =>
                          _setTransportMode(ref, loc, m == chosen ? null : m)
                      : null,
                ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _setTransportMode(
      WidgetRef ref, LocationModel loc, TransportMode? mode) async {
    final types = placeTypesWithModeOverride(loc.placeTypes, mode);
    if (tripId == null) {
      await ref
          .read(tripProvider.notifier)
          .updateLocationPlaceTypes(loc.id, types);
      return;
    }
    await ref
        .read(locationRepositoryProvider)
        .updateLocation(loc.id, {'place_types': types});
  }

  Future<void> _setTag(WidgetRef ref, LocationModel loc, PlaceTag? tag) async {
    if (tripId == null) {
      await ref.read(tripProvider.notifier).updateLocationTag(loc.id, tag?.key);
      return;
    }
    await ref
        .read(locationRepositoryProvider)
        .updateLocation(loc.id, {'tag': tag?.key});
  }

  Widget _buildAccommodationSection(
      BuildContext context, WidgetRef ref, LocationModel loc,
      {required bool hasWriteAccess}) {
    final theme = Theme.of(context);

    String rangeLabel = '';
    if (loc.isAccommodation) {
      final start = loc.scheduledDate;
      final end = loc.scheduledEndDate ?? start;
      if (start != null && end != null) {
        final lab = _labelerOf(ref);
        rangeLabel = start.year == end.year &&
                start.month == end.month &&
                start.day == end.day
            ? lab(start)
            : lab.range(start, end);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.hotel_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Accommodation',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (loc.isAccommodation)
          Row(
            children: [
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.night_shelter_outlined,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rangeLabel.isEmpty
                              ? 'Your stay for this trip'
                              : 'Your stay · $rangeLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasWriteAccess) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await ref
                        .read(tripProvider.notifier)
                        .clearAccommodation(loc.id);
                    if (context.mounted) {
                      AppToast.info(context,
                          '${loc.name} is no longer an accommodation.');
                    }
                  },
                  child: const Text('Remove'),
                ),
              ],
            ],
          )
        else
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: hasWriteAccess
                  ? () => _showAccommodationScopeDialog(context, ref, loc)
                  : null,
              icon: const Icon(Icons.hotel_outlined, size: 18),
              label: const Text('Set as accommodation'),
            ),
          ),
      ],
    );
  }

  /// Step 1: entire trip or just this day?
  Future<void> _showAccommodationScopeDialog(
      BuildContext context, WidgetRef ref, LocationModel loc) async {
    final trip = _scopedTrip(ref);
    final lab = DayLabeler.forTrip(trip);
    final day = _sheetDayKey(ref, loc);
    // "Entire trip" spans the EFFECTIVE range — the declared dates and/or
    // the days locations are scheduled on (scheduling places IS the range).
    final effectiveDays = _effectiveTripDays(ref, trip);
    final hasRange = effectiveDays.isNotEmpty;
    final tripStart = hasRange ? effectiveDays.first : null;
    final tripEnd = hasRange ? effectiveDays.last : null;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Set as accommodation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.luggage_outlined),
              title: const Text('Entire trip'),
              subtitle: Text(hasRange
                  ? '${lab.range(tripStart!, tripEnd!)}, every night'
                  : 'Add trip dates or schedule some places first'),
              enabled: hasRange,
              onTap: hasRange ? () => Navigator.of(ctx).pop('trip') : null,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.today_outlined),
              title: const Text('Just this day'),
              subtitle: Text(
                  lab.tbd ? lab(day) : DateFormat('EEE, MMM d').format(day)),
              onTap: () => Navigator.of(ctx).pop('day'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;

    final DateTime start;
    final DateTime end;
    if (choice == 'trip') {
      start = tripStart!;
      end = tripEnd!;
    } else {
      start = day;
      end = day;
    }
    await _applyAccommodation(context, ref, loc, start: start, end: end);
  }

  /// Step 2: one-per-day conflict check (+replace confirm) then persist.
  Future<void> _applyAccommodation(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc, {
    required DateTime start,
    required DateTime end,
  }) async {
    final notifier = ref.read(tripProvider.notifier);
    final conflicts = notifier.accommodationConflicts(loc.id, start, end);

    var replaceIds = const <String>[];
    if (conflicts.isNotEmpty) {
      final names = conflicts.map((c) => c.name).join(', ');
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Replace existing accommodation?'),
          content: Text(
              'Only one accommodation is allowed per day. These days already '
              'have $names — replace with ${loc.name}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true || !context.mounted) return;
      replaceIds = conflicts.map((c) => c.id).toList();
    }

    final ok = await notifier.setAccommodation(
      loc.id,
      start: start,
      end: end,
      replaceIds: replaceIds,
    );
    if (!context.mounted) return;
    if (ok) {
      AppToast.success(context, '${loc.name} set as your accommodation.');
    } else {
      AppToast.error(
          context, 'Couldn\'t set the accommodation. Please try again.');
    }
  }

  /// The calendar day this sheet's location belongs to (its own schedule,
  /// else the map's selected date).
  DateTime _sheetDayKey(WidgetRef ref, LocationModel loc) {
    final DateTime raw = loc.scheduledDate ?? ref.read(selectedDateProvider);
    return DateTime(raw.year, raw.month, raw.day);
  }

  /// Horizontal strip of the place's Google photos. Reuses the same
  /// [LocationPhotoGallery] as the expanded trip cards; the hero prefix is
  /// namespaced to this sheet so it can't collide with a card gallery for
  /// the same location still visible behind the modal.
  Widget _buildPhotosSection(
      BuildContext context, WidgetRef ref, LocationModel loc) {
    final theme = Theme.of(context);
    // Renew old Google photo references while they're on screen; a tile
    // that fails to load asks for a renewal right away. The refresh button
    // does the same on demand — that is how photos added on Google Maps
    // arrive before the 30-day background renewal would fetch them.
    final photoRefresh = ref.read(placePhotoRefreshProvider);
    final photoTarget = PhotoRefreshTarget.fromModel(loc);
    photoRefresh.noteShown(photoTarget);
    final placeId = loc.placeId;
    final canRefresh = placeId != null && placeId.isNotEmpty;
    final renewedAt = photoRefresh.lastRenewedAt(placeId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.photo_library_outlined,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              'Photos',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${loc.photoReferences.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            // Same control as the Hours section. Not gated on write access:
            // a read-only member's refresh lands as a device-local update.
            if (canRefresh)
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Refresh photos from Google',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: () => _refreshPhotos(context, ref, loc),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LocationPhotoGallery(
          photoRefs: loc.photoReferences,
          heroTagPrefix: '${loc.id}_sheet_photo',
          title: loc.name,
          padding: EdgeInsets.zero,
          tileWidth: 132,
          tileHeight: 96,
          onLoadFailed: () => photoRefresh.noteLoadFailed(photoTarget),
        ),
        if (renewedAt != null) ...[
          const SizedBox(height: 6),
          Text(
            'Updated ${_formatRelative(renewedAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _refreshPhotos(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    AppToast.info(
      context,
      'Refreshing photos…',
      duration: const Duration(seconds: 1),
    );
    final result = await ref
        .read(placePhotoRefreshProvider)
        .refreshNow(PhotoRefreshTarget.fromModel(loc));
    if (!context.mounted) return;
    switch (result.outcome) {
      case PhotoRefreshOutcome.updated:
        AppToast.success(
            context, 'Photos updated — ${result.photoCount} from Google');
      case PhotoRefreshOutcome.unchanged:
        AppToast.info(context, 'Photos are already up to date');
      case PhotoRefreshOutcome.noPhotos:
        AppToast.info(context, 'Google has no photos for this place');
      case PhotoRefreshOutcome.placeGone:
        AppToast.error(context, 'Google no longer lists this place');
      case PhotoRefreshOutcome.failed:
      case PhotoRefreshOutcome.noPlaceId:
        AppToast.error(context, 'Could not refresh photos — try again later');
    }
  }

  Widget _buildHeader(
      BuildContext context, WidgetRef ref, LocationModel updatedLocation,
      {required bool hasWriteAccess, required bool canEdit}) {
    final accent = updatedLocation.isDone
        ? Colors.green.shade500
        : updatedLocation.isSkipped
            ? Colors.grey.shade600
            : Theme.of(context).colorScheme.primary;
    final titleStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.bold,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The top row: what a traveller does to a place on the road. Done
        // and Skip act at once; Route and Schedule open their small sheets.
        // Equal widths so the four never overflow at large text scales.
        Row(
          children: [
            Expanded(
              child: _LabeledAction(
                icon: updatedLocation.isDone ? Icons.close : Icons.check,
                label: updatedLocation.isDone ? 'Undo' : 'Done',
                color: updatedLocation.isDone
                    ? Colors.grey[700]!
                    : Colors.green[600]!,
                enabled: hasWriteAccess,
                onTap: () {
                  final notifier = ref.read(tripProvider.notifier);
                  if (updatedLocation.isDone) {
                    notifier.unmarkLocationsAsDone({updatedLocation.id});
                  } else {
                    notifier.markLocationsAsDone({updatedLocation.id});
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LabeledAction(
                icon: updatedLocation.isSkipped
                    ? Icons.refresh_rounded
                    : Icons.remove_circle_outline,
                label: updatedLocation.isSkipped ? 'Unskip' : 'Skip',
                color: updatedLocation.isSkipped
                    ? Colors.grey[700]!
                    : Colors.orange[700]!,
                enabled: hasWriteAccess,
                onTap: () {
                  final notifier = ref.read(tripProvider.notifier);
                  if (updatedLocation.isSkipped) {
                    notifier.unskipMultipleLocations({updatedLocation.id});
                  } else {
                    notifier.skipMultipleLocations({updatedLocation.id});
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LabeledAction(
                icon: Icons.alt_route_rounded,
                label: 'Route',
                color: Theme.of(context).colorScheme.primary,
                enabled: true,
                onTap: () => _showRouteActions(context, ref, updatedLocation),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _LabeledAction(
                icon: Icons.calendar_today_outlined,
                label: 'Schedule',
                color: Theme.of(context).colorScheme.primary,
                enabled: canEdit,
                onTap: () => _reschedule(context, ref, updatedLocation),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Name row: "N. Location name" (index as text, same glyph rules as
        // the trip-plan card: done → check, skipped → minus, 0 → start flag)
        // with a plain edit icon pushed to the right edge.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (updatedLocation.isDone)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.check_circle_rounded,
                              size: 20, color: accent),
                        ),
                      )
                    else if (updatedLocation.isSkipped)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.remove_circle_outline_rounded,
                              size: 20, color: accent),
                        ),
                      )
                    else if (number == 0)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child:
                              Icon(Icons.flag_rounded, size: 20, color: accent),
                        ),
                      ),
                    // No "N." prefix: the number is a route position, and
                    // this sheet is about the place itself.
                    TextSpan(text: updatedLocation.name),
                  ],
                ),
                style: titleStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Copy the name — for pasting into a taxi app, a chat, a
            // booking site. Everyone gets it (no edit permission needed).
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Copy name',
              icon: Icon(Icons.copy_rounded,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: updatedLocation.name));
                if (context.mounted) {
                  AppToast.success(context, 'Name copied');
                }
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: 'Edit name',
              icon: Icon(Icons.edit_outlined,
                  size: 20,
                  color: canEdit
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey),
              onPressed: canEdit
                  ? () =>
                      _showEditLocationNameDialog(context, ref, updatedLocation)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  /// "23/F · Shop 2301" under the name: where the place sits inside its
  /// building, from Google's address components. Stored on the row when
  /// the place was saved; for older rows looked up once here and, when
  /// this person may write, kept on the row so nobody asks again. Nothing
  /// is shown while unknown or when Google lists no floor.
  Widget _buildFloorLine(
      BuildContext context, WidgetRef ref, LocationModel loc) {
    String? floor = loc.floor;
    if (floor == null) {
      final placeId = loc.placeId;
      if (placeId == null || placeId.isEmpty) return const SizedBox.shrink();
      final looked = ref.watch(placeFloorLookupProvider(placeId)).valueOrNull;
      if (looked == null) return const SizedBox.shrink();
      floor = looked;
      if (_floorPersisted.add(loc.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(tripProvider.notifier).updateLocationFloor(loc.id, looked);
        });
      }
    }
    if (floor.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.layers_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              floor,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Rows whose looked-up floor was handed to the repository this run.
  static final Set<String> _floorPersisted = {};

  /// Below the drag zone, inside the scroll view: only the step that leads
  /// for a LOOSE place (not in any trip) — adding it to one.
  Widget _buildHeaderBody(
      BuildContext context, WidgetRef ref, LocationModel updatedLocation) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        // Loose saved location (not attached to any trip): adding it to a
        // trip is THE next step, so it leads the actions. Same AddToTripSheet
        // (write-access + country guard live inside), scoped to this one
        // location and preselected.
        if (updatedLocation.tripId == null) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.add_location_alt_rounded, size: 18),
              label: const Text('Add to trip'),
              onPressed: () {
                final saved = (ref.read(savedLocationsProvider).valueOrNull ??
                        const <SavedLocation>[])
                    .where((l) => l.id == updatedLocation.id)
                    .toList();
                if (saved.isEmpty) {
                  AppToast.warning(
                      context, 'Location not found — try refreshing.');
                  return;
                }
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => AddToTripSheet(
                    availableLocations: saved,
                    // The location just joined a trip — this sheet's
                    // "loose location" actions are stale; close it.
                    onSuccess: () => Navigator.of(context).maybePop(),
                  ),
                );
              },
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// "Schedule": move this stop to another day of its trip (past days of
  /// the trip stay pickable — logging where you actually went).
  Future<void> _reschedule(BuildContext context, WidgetRef ref,
      LocationModel updatedLocation) async {
    final datesWithLocations = ref.read(datesWithLocationsProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final pickerTrip = _scopedTrip(ref);
    final lab = DayLabeler.forTrip(pickerTrip);
    // Past days of the trip stay pickable (logging
    // where you actually went).
    final tripStart = pickerTrip?.startDate;
    final firstPickable = tripStart != null && tripStart.isBefore(today)
        ? DateTime(tripStart.year, tripStart.month, tripStart.day)
        : today;
    final DateTime? newDate;
    if (lab.tbd) {
      newDate = await showTripDayPicker(
        context,
        days: _effectiveTripDays(ref, pickerTrip),
        labeler: lab,
        selected: updatedLocation.scheduledDate,
        marked: datesWithLocations,
      );
    } else {
      newDate = await DatePickerUtils.showCustomDatePicker(
        context: context,
        initialDate: updatedLocation.scheduledDate ?? now,
        firstDate: firstPickable,
        lastDate: DateTime(now.year + 5),
        highlightedDates: datesWithLocations,
      );
    }
    if (newDate == null) return;
    final normalized = DateTime(newDate.year, newDate.month, newDate.day);
    final activeTrip = ref.read(realtimeActiveTripProvider).valueOrNull;
    if (!context.mounted) return;
    final allowed = await ensureScheduledDateAllowed(
      context,
      activeTrip,
      normalized,
      actionLabel: 'Save anyway',
    );
    if (!allowed) return;
    // The confirm dialog above awaited — the sheet may
    // have been popped/replaced from under it.
    if (!context.mounted) return;
    // Shared same-day duplicate rule. Occupants come
    // from THIS location's trip: pinned state only
    // covers the ACTIVE trip, and checking another
    // trip's day both false-blocks and false-passes.
    final sheetTripId = tripId;
    final Iterable<PlaceKey> occupants;
    if (sheetTripId == null) {
      occupants = ref
          .read(tripProvider)
          .pinnedLocations
          .where((l) =>
              l.id != updatedLocation.id &&
              l.scheduledDate != null &&
              l.isActiveOnDate(normalized))
          .map(placeKeyOfModel);
    } else {
      occupants = (ref.read(savedLocationsProvider).valueOrNull ??
              const <SavedLocation>[])
          .where((l) =>
              l.tripId == sheetTripId &&
              l.id != updatedLocation.id &&
              l.scheduledDate != null &&
              l.isActiveOnDate(normalized))
          .map(placeKeyOfSaved);
    }
    final dup = filterSameDayDuplicates(
      moving: [placeKeyOfModel(updatedLocation)],
      occupantsOnDay: occupants,
    );
    if (dup.allowedIds.isEmpty) {
      AppToast.warning(context,
          '"${updatedLocation.name}" is already on ${_labelerOf(ref)(normalized)}');
      return;
    }
    final dayWasEmpty = !ref
        .read(tripProvider)
        .pinnedLocations
        .any((l) => l.isActiveOnDate(normalized));
    await ref
        .read(tripProvider.notifier)
        .updateLocationScheduledDate(updatedLocation.id, normalized);
    final scoped = _scopedTrip(ref);
    if (dayWasEmpty && scoped != null && context.mounted) {
      await maybePromptAccommodationForNewDays(
        context,
        ref,
        trip: scoped,
        newDays: [normalized],
      );
    }
  }

  /// "Route": the ways to draw a leg to or from this stop, in one small
  /// sheet — from where the device is (map context only), from or to
  /// another stop of the day, or hand off to Google Maps.
  Future<void> _showRouteActions(
      BuildContext context, WidgetRef ref, LocationModel loc) {
    final theme = Theme.of(context);
    final List<LocationModel> siblings =
        locationsForDate ?? ref.read(locationsForSelectedDateProvider);
    final others = siblings.where((l) => l.id != loc.id).toList();
    final canRoute = others.isNotEmpty;
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Route · ${loc.name}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (locationsForDate == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: _RouteFromHereButton(
                    location: loc,
                    knownCountry: _knownCountryOf(ref, loc),
                    device: ref.read(tripProvider).currentLocation,
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _previewFromCurrentLocation(context, ref, loc);
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('From here to another stop'),
                subtitle:
                    canRoute ? null : const Text('No other stop that day'),
                enabled: canRoute,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pickAndPreviewRoute(
                    context: context,
                    ref: ref,
                    current: loc,
                    others: others,
                    role: _RouteEndpoint.from,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: const Text('From another stop to here'),
                enabled: canRoute,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pickAndPreviewRoute(
                    context: context,
                    ref: ref,
                    current: loc,
                    others: others,
                    role: _RouteEndpoint.to,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: const Text('Open in Google Maps'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openGoogleMaps(loc);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// How long the traveller plans to spend here; edited in the same dialog
  /// the plan card's "Stay" button opens.
  Widget _buildStayDurationRow(
      BuildContext context, WidgetRef ref, LocationModel loc,
      {required bool canEdit}) {
    final theme = Theme.of(context);
    final d = loc.stayDuration;
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final text = h > 0 ? '${h}h ${m}m' : '${m}m';
    return Row(
      children: [
        Icon(Icons.timer_outlined,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Stay · $text',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        TextButton(
          onPressed:
              canEdit ? () => showStayDurationDialog(context, ref, loc) : null,
          child: const Text('Edit'),
        ),
      ],
    );
  }

  /// One line under "Details" while it is folded: the tag, the stay, the
  /// hotel flag — so the fold hides nothing a glance needs.
  String? _detailsSummary(LocationModel loc) {
    final parts = <String>[];
    final tag = placeTagFromKey(loc.tag);
    if (tag != null) parts.add(placeTagLabel(tag, loc.placeTypes));
    final d = loc.stayDuration;
    parts.add(d.inHours > 0
        ? 'Stay ${d.inHours}h ${d.inMinutes % 60}m'
        : 'Stay ${d.inMinutes}m');
    if (loc.isAccommodation) parts.add('Accommodation');
    if (loc.isMultiDay) parts.add('Multi-day');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The destructive actions, last: leave the trip (keeps the place), or
  /// delete it.
  Widget _buildDangerZone(
      BuildContext context, WidgetRef ref, LocationModel updatedLocation,
      {required bool hasWriteAccess, required bool canEdit}) {
    final removable = canEdit && updatedLocation.tripId != null;
    return Row(
      children: [
        if (removable) ...[
          Expanded(
            child: OutlinedButton.icon(
              icon: Icon(Icons.link_off_rounded,
                  size: 18, color: Colors.orange.shade700),
              label: Text('Remove from trip',
                  style: TextStyle(color: Colors.orange.shade700)),
              onPressed: () =>
                  _confirmRemoveFromTrip(context, ref, updatedLocation),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                side: BorderSide(
                    color: Colors.orange.shade700.withValues(alpha: 0.4)),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: OutlinedButton.icon(
            icon: Icon(Icons.delete_outline,
                size: 18,
                color: hasWriteAccess ? Colors.red[600] : Colors.grey),
            label: Text('Delete',
                style: TextStyle(
                    color: hasWriteAccess ? Colors.red[600] : Colors.grey)),
            onPressed: hasWriteAccess
                ? () =>
                    _showDeleteConfirmationDialog(context, ref, updatedLocation)
                : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              side: BorderSide(
                  color: (hasWriteAccess ? Colors.red[600]! : Colors.grey)
                      .withValues(alpha: 0.4)),
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

  /// In-app "take me there": draws the route from the device's current
  /// position to [target] on the map instead of handing off to Google Maps.
  /// Same dismiss → collapse → scroll-reset choreography as
  /// [_pickAndPreviewRoute]; the map's zoom listener then frames the leg.
  /// The country the place is known to sit in without a lookup: its trip's
  /// tag. Loose places, and places on an untagged trip, return null — the
  /// button then geocodes the pin once instead.
  String? _knownCountryOf(WidgetRef ref, LocationModel loc) {
    final id = loc.tripId;
    if (id == null) return null;
    final active = ref.read(realtimeActiveTripProvider).valueOrNull;
    if (active != null && active.id == id) return active.countryCode;
    final all = ref.read(userTripsProvider).asData?.value ?? const <Trip>[];
    for (final t in all) {
      if (t.id == id) return t.countryCode;
    }
    return null;
  }

  Future<void> _previewFromCurrentLocation(
    BuildContext context,
    WidgetRef ref,
    LocationModel target,
  ) async {
    if (ref.read(tripProvider).currentLocation == null) {
      AppToast.warning(
          context, 'Waiting for your location — try again in a moment.');
      return;
    }

    Navigator.of(context).pop();

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

    await ref
        .read(tripProvider.notifier)
        .previewRouteFromCurrentLocation(target);
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

  // ── Added by ────────────────────────────────────────────────────────────
  /// Who put this place in the trip, and when. The saved row's user id is
  /// the adder — except for a place handed to the owner when its adder left
  /// the trip, which says so instead of naming the owner. Names come from
  /// the public-profile lookup (answers only for people who share a trip
  /// with the viewer); the member list's email is the fallback. Returns the
  /// divider and the section, or nothing for guests and loose places.
  List<Widget> _buildAddedBySection(
      BuildContext context, WidgetRef ref, LocationModel loc) {
    final me = ref.watch(currentUserIdProvider);
    final tripId = loc.tripId;
    if (me == null || tripId == null) return const [];
    final rows = (ref.watch(savedLocationsProvider).valueOrNull ??
            const <SavedLocation>[])
        .where((l) => l.id == loc.id);
    if (rows.isEmpty) return const [];
    final row = rows.first;
    if (row.userId.isEmpty) return const [];
    final theme = Theme.of(context);

    String name;
    String? email;
    String? note;
    if (row.handedOver) {
      name = 'A former trip member';
      note = 'Kept in the trip when they left';
    } else if (row.userId == me) {
      name = 'You';
      email = Supabase.instance.client.auth.currentUser?.email;
    } else {
      final profile =
          ref.watch(userProfileByIdProvider(row.userId)).valueOrNull;
      final members =
          ref.watch(tripCollaboratorsProvider(tripId)).valueOrNull ?? const [];
      final member = members.where((c) => c.userId == row.userId);
      email = profile?.email ?? (member.isEmpty ? null : member.first.email);
      final full = [profile?.firstName, profile?.lastName]
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join(' ');
      name = full.isNotEmpty ? full : (email ?? 'A trip member');
      if (full.isNotEmpty && email != null) note = email;
    }
    final avatarSeed = email ?? name;
    final when = DateFormat('MMM d, yyyy').format(loc.addedAt);

    return [
      const Divider(height: 32),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'Added by',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: TripCollaboratorsRow.colorFor(avatarSeed),
                child: Text(
                  TripCollaboratorsRow.initialFor(avatarSeed),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      note == null ? 'Added $when' : '$note · added $when',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ];
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
  String _formatGoogleHoursForDay(List<OpeningPeriod>? hours, int googleDay) {
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
    LocationModel loc, {
    required bool hasWriteAccess,
    required bool isPastDate,
    required DateTime gateDay,
  }) {
    final theme = Theme.of(context);
    final canEdit = !isPastDate && hasWriteAccess;

    // The row's own day (the map's selected day for a loose place).
    final selectedDate = gateDay;
    final googleDay = _googleDayFor(selectedDate);
    // No dates yet → no weekday to look up.
    final undated = _labelerOf(ref).tbd;
    final dayLabel = undated ? 'Hours' : _weekdayNames[googleDay];

    final googleHours = loc.googleOpeningHours;
    final overrideMin = loc.userClosingMinuteOverride;
    final placeId = loc.placeId;
    final canRefresh = placeId != null && placeId.isNotEmpty;

    final googleSummary = undated
        ? 'set trip dates to see this day\'s hours'
        : _formatGoogleHoursForDay(googleHours, googleDay);
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Refresh from Google',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed:
                    canEdit ? () => _refreshHours(context, ref, loc) : null,
              ),
          ],
        ),
        const SizedBox(height: 4),
        // One line: "Tuesday: 10:00 – 18:00" followed by the closing-override
        // control as a plain text button (opens the same "Close by" dialog).
        // Once set it reads "Close by 22:00" / "Never closes", with a small
        // Reset beside it to clear. Wrap keeps split-hours strings and the
        // buttons from ever overflowing the row.
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$dayLabel: $googleSummary',
              style: theme.textTheme.bodyMedium,
            ),
            TextButton(
              onPressed: canEdit
                  ? () => _editClosingOverride(context, ref, loc, defaultClose)
                  : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              child: Text(
                overrideMin == null
                    ? 'Set'
                    : overrideMin == kNeverCloses
                        ? 'Never closes'
                        : 'Close by ${_formatMinutes(overrideMin)}',
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
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Reset'),
              ),
          ],
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
                  onPressed: () => Navigator.of(ctx).pop(_OverrideAction.never),
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
    final initial =
        (current != null && current != kNeverCloses) ? current : defaultMinutes;
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
    LocationModel loc, {
    required bool hasWriteAccess,
    required bool isPastDate,
  }) {
    final theme = Theme.of(context);
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
    scopedTrip ??= ref.watch(realtimeActiveTripProvider).valueOrNull;
    // Effective range: declared dates and/or scheduled-location days — a
    // trip whose places are dated has a range even without explicit dates.
    final effectiveDays = _effectiveTripDays(ref, scopedTrip);
    final tripStart = effectiveDays.isNotEmpty ? effectiveDays.first : null;
    final tripEnd = effectiveDays.isNotEmpty ? effectiveDays.last : null;
    final tripHasRange = tripStart != null && tripEnd != null;

    final lab = DayLabeler.forTrip(scopedTrip);
    String statusLabel;
    if (isMultiDay && start != null && end != null) {
      statusLabel =
          '${lab.range(start, end)} · ${_daysBetween(start, end)} days';
    } else if (start != null) {
      statusLabel = 'Single day · '
          '${lab.tbd ? lab(start) : DateFormat('MMM d, y').format(start)}';
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
              onPressed:
                  canEdit ? () => _pickStayRange(context, ref, loc) : null,
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
  /// Day labels for the trip this sheet is scoped to ("Day N" while it
  /// has no dates yet).
  DayLabeler _labelerOf(WidgetRef ref) => DayLabeler.forTrip(_scopedTrip(ref));

  Trip? _scopedTrip(WidgetRef ref) {
    if (tripId != null) {
      final all = ref.read(userTripsProvider).asData?.value ?? const <Trip>[];
      for (final t in all) {
        if (t.id == tripId) return t;
      }
    }
    return ref.read(realtimeActiveTripProvider).valueOrNull;
  }

  /// Pushes the new range to storage. Goes through the [tripProvider]
  /// notifier (which threads through optimistic local state) when no
  /// explicit [tripId] is set — that path's permission check is tied to
  /// the active trip, which is correct in that context. When [tripId] is
  /// set (trip details screen for a non-active trip), call the repository
  /// directly — Supabase RLS still enforces access, but we don't fail
  /// silently against the wrong trip's permission gate.
  /// Returns false (with a toast) when the shared same-day duplicate rule
  /// blocks the range: another row of the SAME place active on any day of
  /// [start..end].
  Future<bool> _writeDateRange(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
    DateTime start,
    DateTime? end,
  ) async {
    final startKey = _dayKey(start);
    DateTime? endKey;
    if (end != null) {
      final candidate = _dayKey(end);
      if (candidate.isAfter(startKey)) endKey = candidate;
    }

    final movingKey = placeKeyOfModel(loc);
    final pinnedOthers = tripId == null
        ? ref
            .read(tripProvider)
            .pinnedLocations
            .where((l) => l.id != loc.id)
            .toList()
        : const <LocationModel>[];
    final savedOthers = tripId == null
        ? const <SavedLocation>[]
        : (ref.read(savedLocationsProvider).valueOrNull ??
                const <SavedLocation>[])
            .where((l) => l.tripId == tripId && l.id != loc.id)
            .toList();
    for (var d = startKey;
        !d.isAfter(endKey ?? startKey);
        d = DateTime(d.year, d.month, d.day + 1)) {
      final keys = tripId == null
          ? pinnedOthers
              .where((l) => l.scheduledDate != null && l.isActiveOnDate(d))
              .map(placeKeyOfModel)
          : savedOthers
              .where((l) => l.scheduledDate != null && l.isActiveOnDate(d))
              .map(placeKeyOfSaved);
      final dup =
          filterSameDayDuplicates(moving: [movingKey], occupantsOnDay: keys);
      if (dup.allowedIds.isEmpty) {
        if (context.mounted) {
          AppToast.warning(
              context, '"${loc.name}" is already on ${_labelerOf(ref)(d)}');
        }
        return false;
      }
    }

    if (tripId == null) {
      await ref
          .read(tripProvider.notifier)
          .setLocationDateRange(loc.id, start, end);
      return true;
    }
    await ref.read(locationRepositoryProvider).updateLocation(
      loc.id,
      {
        'scheduled_date': startKey.toIso8601String(),
        'scheduled_end_date': endKey?.toIso8601String(),
      },
    );
    return true;
  }

  Future<void> _pickStayRange(
    BuildContext context,
    WidgetRef ref,
    LocationModel loc,
  ) async {
    final scopedTrip = _scopedTrip(ref);
    final today = _dayKey(DateTime.now());
    final initialStart = _dayKey(loc.scheduledDate ?? today);
    final initialEnd =
        _dayKey(loc.scheduledEndDate ?? loc.scheduledDate ?? today);

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
    final firstDate = firstCandidates.reduce((a, b) => a.isBefore(b) ? a : b);
    final lastDate = lastCandidates.reduce((a, b) => a.isAfter(b) ? a : b);

    final lab = DayLabeler.forTrip(scopedTrip);
    final DateTimeRange? picked;
    if (lab.tbd) {
      picked = await showTripDayRangePicker(
        context,
        days: _effectiveTripDays(ref, scopedTrip),
        labeler: lab,
        initial: DateTimeRange(start: initialStart, end: initialEnd),
      );
    } else {
      picked = await showDateRangePicker(
        context: context,
        firstDate: firstDate,
        lastDate: lastDate,
        initialDateRange: DateTimeRange(start: initialStart, end: initialEnd),
        helpText: 'Stay range',
        saveText: 'Set',
      );
    }
    if (picked == null) return;
    try {
      await _writeDateRange(context, ref, loc, picked.start, picked.end);
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
      final ok = await _writeDateRange(context, ref, loc, tripStart, tripEnd);
      if (!ok || !context.mounted) return;
      AppToast.success(
        context,
        'Set to entire trip · ${_labelerOf(ref).range(tripStart, tripEnd)}',
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
      await _writeDateRange(context, ref, loc, start, null);
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

                    // 4. Scroll the main list back to the top. hasClients
                    // guard: the map-pin path hands us a dummy controller
                    // that is never attached (and is disposed early), so
                    // animating it unguarded would throw.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (parentScrollController.hasClients) {
                        parentScrollController.animateTo(0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut);
                      }
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
            cursorOpacityAnimates: false,
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
                borderSide:
                    const BorderSide(color: AppTheme.primaryColor, width: 2),
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

  void _showDeleteConfirmationDialog(
      BuildContext context, WidgetRef ref, LocationModel location) {
    // Multi-day rows viewed on one of their days (active-trip context only —
    // the day-aware shrink/split goes through tripProvider, whose access
    // check is tied to the active trip): offer "remove from this day" so a
    // spanning accommodation isn't wiped from the whole trip.
    final day = _sheetDayKey(ref, location);
    final startRaw = location.scheduledDate ?? location.addedAt;
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = location.scheduledEndDate ?? startRaw;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    final isActiveTripContext = tripId == null ||
        ref.read(realtimeActiveTripProvider).valueOrNull?.id == tripId;
    final spansHere = isActiveTripContext &&
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
                  '${_labelerOf(ref).range(start, end)}. '
                  'Remove it from this day only, or delete it from every day?'
              : 'Are you sure you want to delete "${location.name}"? This action cannot be undone.'),
          // Three actions don't fit across an AlertDialog's default
          // OverflowBar, which silently stacks them vertically. An explicit
          // equal-width Row keeps them on one line; the dialog body carries
          // the full wording, so the buttons can stay short.
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            if (spansHere)
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(
                        'Cancel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color:
                                Theme.of(context).textTheme.bodyMedium?.color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).pop();
                        ref
                            .read(locationRepositoryProvider)
                            .deleteLocation(location.id);
                        if (context.mounted) {
                          AppToast.error(context, 'Deleted ${location.name}');
                        }
                      },
                      child: Text(
                        'All days',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        Navigator.of(context).pop();
                        ref
                            .read(tripProvider.notifier)
                            .removeLocationFromDay(location.id, day);
                        if (context.mounted) {
                          AppToast.success(context,
                              '${location.name} removed from ${_labelerOf(ref)(day)}');
                        }
                      },
                      child: const Text(
                        'This day',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              )
            else ...[
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
                  ref
                      .read(locationRepositoryProvider)
                      .deleteLocation(location.id);

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

class _RouteEndpointPicker extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<LocationModel> candidates;

  const _RouteEndpointPicker({
    required this.title,
    required this.subtitle,
    required this.candidates,
  });

  @override
  State<_RouteEndpointPicker> createState() => _RouteEndpointPickerState();
}

class _RouteEndpointPickerState extends State<_RouteEndpointPicker> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = widget.candidates;
    // Same forgiving match as every other "find my place" box: case- and
    // accent-insensitive, any word order (see matchesSearchQuery).
    final visible = _query.trim().isEmpty
        ? candidates
        : candidates
            .where((l) => matchesSearchQuery('${l.name} ${l.address}', _query))
            .toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
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
                          widget.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
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
            // Search — long days have too many stops to scan by eye.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: TextField(
                cursorOpacityAnimates: false,
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search these stops…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No stops match "$_query".',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, i) {
                        final loc = visible[i];
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
                                    child: Icon(Icons.place_outlined,
                                        size: 18,
                                        color: theme.colorScheme.primary),
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

/// One of the three primary stop actions (Delete / Skip / Done) in the
/// detail sheet header. Icon + word label, sized to fill an [Expanded] slot
/// so all three stay on one row at any text scale.
/// A folded section: one tappable row (icon, title, a one-line summary
/// while closed, a chevron) and its content when open. Plain conditional
/// child — no AnimatedSize in this intrinsically sized column.
class _SectionExpander extends StatelessWidget {
  const _SectionExpander({
    required this.icon,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (!open && subtitle != null)
                        Text(subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
      ],
    );
  }
}

class _LabeledAction extends StatelessWidget {
  const _LabeledAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final background = enabled ? color : Colors.grey[400]!;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          // Icon over label: four of these share one row, so side by side
          // the labels truncated ("Sc…").
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Route from my location", gated on the device being in the SAME COUNTRY
/// as the place: an in-app leg from another country is never what the user
/// meant. [CountryMatchService] answers from cache whenever it can, so the
/// button usually opens in its final state; while a lookup runs it is
/// disabled with a spinner, and an unknown answer (lookup failed) leaves it
/// usable rather than locking it on a flaky geocode. No device fix at all
/// also leaves it usable — tapping then explains that the location is
/// unknown, as before.
class _RouteFromHereButton extends StatefulWidget {
  final LocationModel location;

  /// ISO-2 of the place's trip, when tagged; null means "geocode the pin".
  final String? knownCountry;
  final LatLng? device;
  final VoidCallback onPressed;

  const _RouteFromHereButton({
    required this.location,
    required this.knownCountry,
    required this.device,
    required this.onPressed,
  });

  @override
  State<_RouteFromHereButton> createState() => _RouteFromHereButtonState();
}

class _RouteFromHereButtonState extends State<_RouteFromHereButton> {
  bool? _sameCountry; // null = unknown
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(covariant _RouteFromHereButton old) {
    super.didUpdateWidget(old);
    if (old.location.id != widget.location.id ||
        old.knownCountry != widget.knownCountry ||
        old.device != widget.device) {
      _check();
    }
  }

  Future<void> _check() async {
    final device = widget.device;
    if (device == null) {
      _sameCountry = null;
      _checking = false;
      return;
    }
    final svc = CountryMatchService.instance;
    final cached = svc.cachedVerdict(
      device: device,
      placeKey: widget.location.id,
      knownPlaceCountry: widget.knownCountry,
    );
    if (cached != null) {
      _sameCountry = cached;
      _checking = false;
      return;
    }
    _checking = true;
    final verdict = await svc.verdict(
      device: device,
      place: widget.location.coordinates,
      placeKey: widget.location.id,
      knownPlaceCountry: widget.knownCountry,
    );
    if (!mounted) return;
    setState(() {
      _sameCountry = verdict;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = _sameCountry == false;
    final enabled = !_checking && !blocked;
    final tint = enabled ? theme.colorScheme.primary : theme.disabledColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: _checking
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: tint),
                  )
                : Icon(Icons.navigation_rounded, size: 18, color: tint),
            label: const Text('Route from my location'),
            onPressed: enabled ? widget.onPressed : null,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              side: BorderSide(color: tint.withValues(alpha: 0.3)),
            ),
          ),
        ),
        if (blocked)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              'Unavailable — you\'re in a different country from this place.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
