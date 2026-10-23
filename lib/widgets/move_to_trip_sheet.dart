import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../models/trip.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/location_add_service.dart';
import '../utils/countries.dart';
import '../utils/move_to_trip_rules.dart';
import '../utils/trip_date_validator.dart';
import '../utils/trip_day_labels.dart';
import 'app_toast.dart';

/// "Move to another trip" for one or many planned places: pick a trip the
/// user can write to, pass the country guard, pick a day there (or leave
/// the places unscheduled), move. Resolves to true once the places moved.
Future<bool> showMoveToTripSheet(
  BuildContext context,
  WidgetRef ref,
  List<LocationModel> picks, {
  Trip? sourceTrip,
}) async {
  if (picks.isEmpty) return false;
  final moved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => MoveToTripSheet(picks: picks, sourceTrip: sourceTrip),
  );
  return moved == true;
}

class MoveToTripSheet extends ConsumerStatefulWidget {
  const MoveToTripSheet({super.key, required this.picks, this.sourceTrip});

  final List<LocationModel> picks;

  /// The trip the places leave. Null = the active trip (the plan on
  /// screen); an ended trip reviewed from its own page passes itself.
  final Trip? sourceTrip;

  @override
  ConsumerState<MoveToTripSheet> createState() => _MoveToTripSheetState();
}

class _MoveToTripSheetState extends ConsumerState<MoveToTripSheet> {
  /// The trip chosen in step one; null while the list is showing.
  Trip? _target;
  bool _busy = false;

  int get _count => widget.picks.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source =
        widget.sourceTrip ?? ref.watch(realtimeActiveTripProvider).valueOrNull;
    final target = _target;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                child: Row(
                  children: [
                    if (target != null)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Back to trips',
                        onPressed:
                            _busy ? null : () => setState(() => _target = null),
                      )
                    else
                      const SizedBox(width: 48),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            target == null
                                ? 'Move to another trip'
                                : 'Pick a day in ${target.name}',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$_count place${_count == 1 ? '' : 's'}'
                            '${source == null ? '' : ' from "${source.name}"'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const LinearProgressIndicator(minHeight: 2)
              else
                const Divider(height: 1),
              Expanded(
                child: IgnorePointer(
                  ignoring: _busy,
                  child: target == null
                      ? _tripList(context, scrollController, source)
                      : _dayList(context, scrollController, target),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Step one: which trip ─────────────────────────────────────────────

  Widget _tripList(
      BuildContext context, ScrollController controller, Trip? source) {
    final theme = Theme.of(context);
    final own = ref.watch(userTripsProvider);
    final shared = ref.watch(sharedTripsProvider);
    if (own.isLoading && !own.hasValue) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    // Trips the user may write to: their own, plus the ones shared with
    // write permission (a read-only share cannot take places).
    final candidates = <Trip>[...?own.valueOrNull];
    for (final row in shared.valueOrNull ?? const <Map<String, dynamic>>[]) {
      if (row['permission'] != 'write') continue;
      final raw = row['trips'];
      if (raw is! Map) continue;
      try {
        candidates.add(Trip.fromJson(Map<String, dynamic>.from(raw)));
      } catch (_) {
        // An incomplete embed row is not offered rather than crashing the list.
      }
    }
    final trips = moveTargetTrips(candidates, exceptTripId: source?.id);

    if (trips.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No other trip to move to yet. Create one first, then come back.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: trips.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, i) {
        final trip = trips[i];
        return ListTile(
          leading:
              Icon(Icons.luggage_outlined, color: theme.colorScheme.primary),
          title: Text(trip.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_tripSubtitle(trip),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _chooseTrip(trip, source),
        );
      },
    );
  }

  /// "Japan · Nov 5 – Nov 9", "No dates yet", or just the dates.
  String _tripSubtitle(Trip trip) {
    final parts = <String>[];
    final country = findCountryByCode(trip.countryCode)?.name;
    if (country != null) parts.add(country);
    if (trip.isUndated) {
      parts.add('No dates yet');
    } else if (trip.startDate != null && trip.endDate != null) {
      final fmt = DateFormat('MMM d');
      parts
          .add('${fmt.format(trip.startDate!)} – ${fmt.format(trip.endDate!)}');
    } else {
      parts.add('No dates');
    }
    return parts.join(' · ');
  }

  Future<void> _chooseTrip(Trip trip, Trip? source) async {
    setState(() => _busy = true);
    final mismatch = await LocationAddService(ref)
        .countryMismatchForMove(widget.picks, trip, source: source);
    if (!mounted) return;
    setState(() => _busy = false);
    if (mismatch != null) {
      // The same single-button refusal the add paths show: the move is
      // forbidden outright, there is no "move anyway".
      await assertLocationInTripCountry(context, trip, mismatch);
      return;
    }
    setState(() => _target = trip);
  }

  // ── Step two: which day there ────────────────────────────────────────

  Widget _dayList(
      BuildContext context, ScrollController controller, Trip target) {
    final theme = Theme.of(context);
    final days = moveTargetDays(target);
    final label = DayLabeler.forTrip(target);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        ListTile(
          leading: Icon(Icons.inbox_outlined,
              color: theme.colorScheme.onSurfaceVariant),
          title: const Text('Unscheduled'),
          subtitle: const Text('Decide the day later'),
          onTap: () => _move(target, null),
        ),
        if (days.isNotEmpty) const Divider(height: 1, indent: 56),
        for (final day in days)
          ListTile(
            leading: Icon(Icons.calendar_today_outlined,
                color: theme.colorScheme.primary),
            title: Text(label(day, pattern: 'EEE, MMM d')),
            onTap: () => _move(target, day),
          ),
      ],
    );
  }

  Future<void> _move(Trip target, DateTime? day) async {
    setState(() => _busy = true);
    // Fresh permission read right before the write — the list came from
    // cached trip rows, and a share can be downgraded meanwhile.
    final canWrite = await ref.read(hasWriteAccessProvider(target.id).future);
    if (!mounted) return;
    if (!canWrite) {
      setState(() => _busy = false);
      AppToast.warning(context,
          'You don\'t have permission to add locations to "${target.name}".');
      return;
    }
    final source =
        widget.sourceTrip ?? ref.read(realtimeActiveTripProvider).valueOrNull;
    final moved = await ref.read(tripProvider.notifier).moveLocationsToTrip(
        widget.picks, target.id, day,
        sourceTripId: source?.id);
    if (!mounted) return;
    if (!moved) {
      setState(() => _busy = false);
      AppToast.error(context, 'Could not move to "${target.name}".');
      return;
    }
    final where = day == null
        ? 'unscheduled'
        : DayLabeler.forTrip(target)(day, pattern: 'MMM d');
    // Overlay toast: it outlives this sheet's pop below.
    AppToast.success(context,
        'Moved $_count place${_count == 1 ? '' : 's'} to ${target.name} · $where');
    Navigator.of(context).pop(true);
  }
}
