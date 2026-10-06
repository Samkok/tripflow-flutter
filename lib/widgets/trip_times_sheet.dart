import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../models/trip.dart';
import '../providers/user_trip_provider.dart';
import '../utils/trip_dates.dart';
import '../utils/trip_day_labels.dart';
import '../utils/trip_times.dart';
import 'app_toast.dart';

/// Opens the sheet where the trip's owner says when they arrive on the
/// first day and when they leave on the last. Each change saves at once;
/// [onChanged] hears the trip as it now stands (also after the sheet has
/// closed, should a save still be on its way).
///
/// With [openClockFor] the clock for that time opens straight away, on top
/// of the sheet — for "Add arrival time" on a day, where the tap already
/// said which time is meant.
///
/// The trip needs a first and a last day (dates, or numbered days).
Future<void> showTripTimesSheet(
  BuildContext context, {
  required Trip trip,
  ValueChanged<Trip>? onChanged,
  TripTimeField? openClockFor,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (_) => TripTimesSheet(
      trip: trip,
      onChanged: onChanged,
      openClockFor: openClockFor,
    ),
  );
}

class TripTimesSheet extends ConsumerStatefulWidget {
  final Trip trip;
  final ValueChanged<Trip>? onChanged;
  final TripTimeField? openClockFor;

  const TripTimesSheet({
    super.key,
    required this.trip,
    this.onChanged,
    this.openClockFor,
  });

  @override
  ConsumerState<TripTimesSheet> createState() => _TripTimesSheetState();
}

class _TripTimesSheetState extends ConsumerState<TripTimesSheet> {
  late Trip _trip = widget.trip;
  bool _saving = false;

  // Where the clock opens when no time is set yet: an afternoon arrival,
  // a midday departure.
  static const _arrivalSuggestion = 14 * 60;
  static const _departureSuggestion = 12 * 60;

  @override
  void initState() {
    super.initState();
    final field = widget.openClockFor;
    if (field != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pick(arrival: field == TripTimeField.arrival);
      });
    }
  }

  Future<void> _pick({required bool arrival}) async {
    if (_saving) return;
    final current = arrival ? _trip.arrivalMinute : _trip.departureMinute;
    final initial =
        current ?? (arrival ? _arrivalSuggestion : _departureSuggestion);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial ~/ 60, minute: initial % 60),
      helpText: arrival ? 'Arrival time' : 'Departure time',
    );
    if (picked == null || !mounted) return;
    await _save(arrival: arrival, minute: picked.hour * 60 + picked.minute);
  }

  /// Stores one of the two times ([minute] null takes it off).
  Future<void> _save({required bool arrival, required int? minute}) async {
    if (_saving) return;
    final before = _trip;
    final arrives = arrival ? minute : before.arrivalMinute;
    final leaves = arrival ? before.departureMinute : minute;
    if (minute != null &&
        tripIsOneDay(before) &&
        arrives != null &&
        leaves != null &&
        leaves <= arrives) {
      AppToast.warning(
          context,
          'This trip is one day long: the departure has to be after the '
          'arrival.');
      return;
    }

    // Read before the wait: the sheet may be gone by the time it ends.
    final trips = ref.read(tripRepositoryProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    final next = arrival
        ? before.copyWith(arrivalMinute: minute)
        : before.copyWith(departureMinute: minute);
    setState(() {
      _saving = true;
      _trip = next;
    });
    try {
      final saved = await trips.updateTrip(
        before.id,
        arrivalMinute: arrival ? minute : null,
        clearArrivalMinute: arrival && minute == null,
        departureMinute: arrival ? null : minute,
        clearDepartureMinute: !arrival && minute == null,
      );
      // The answer is what was stored. Anything else means the time did not
      // save (a server that does not know the field yet drops it quietly).
      final stored = arrival ? saved.arrivalMinute : saved.departureMinute;
      if (stored != minute) throw StateError('the time was not stored');
      container.invalidate(userTripsProvider);
      widget.onChanged?.call(next);
    } catch (e) {
      debugPrint('TripTimesSheet: saving failed: $e');
      if (mounted) {
        setState(() => _trip = before);
        AppToast.error(context, "Couldn't save the time. Try again.");
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = _trip.startDate;
    final end = _trip.endDate;
    final first = dayKey(start ?? end ?? DateTime.now());
    final last = dayKey(end ?? start ?? first);
    final labeler = DayLabeler.forTrip(_trip);
    String dayLine(DateTime day) {
      final number = 'Day ${tripDayNumber(first, day)}';
      return labeler.tbd
          ? number
          : '$number · ${DateFormat('EEE, MMM d').format(day)}';
    }

    String time(int minute) => formatMinuteOfDay(context, minute);
    final arrival = _trip.arrivalMinute;
    final departure = _trip.departureMinute;
    final squeezed =
        tripIsOneDay(_trip) && oneDayTripHasNoTime(arrival, departure);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.sheetBorderColor(context)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Arrival and departure',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Text(
                  'Say when you get in and when you leave. Auto-plan then '
                  'gives your first and last day only what you have time '
                  'for, at places that are open.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
              _TimeField(
                id: 'trip-times-arrival',
                icon: Icons.flight_land_rounded,
                label: 'Arrival',
                day: dayLine(first),
                time: arrival == null ? null : time(arrival),
                note: arrival == null
                    ? 'Not set: Auto-plan treats this as a full day.'
                    : arrivalEffect(arrival, time),
                busy: _saving,
                onTap: () => _pick(arrival: true),
                onRemove: arrival == null
                    ? null
                    : () => _save(arrival: true, minute: null),
              ),
              const SizedBox(height: 8),
              _TimeField(
                id: 'trip-times-departure',
                icon: Icons.flight_takeoff_rounded,
                label: 'Departure',
                day: dayLine(last),
                time: departure == null ? null : time(departure),
                note: departure == null
                    ? 'Not set: Auto-plan treats this as a full day.'
                    : departureEffect(departure, time),
                busy: _saving,
                onTap: () => _pick(arrival: false),
                onRemove: departure == null
                    ? null
                    : () => _save(arrival: false, minute: null),
              ),
              if (squeezed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline_rounded,
                          size: 16, color: Color(0xFFFFB300)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'These two times leave no room for a visit in '
                          'between, so Auto-plan has nothing to plan.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        'Nothing moves until you run Auto-plan.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the two times: the whole card opens the clock; the pill on the
/// right shows the time, or invites to set one.
class _TimeField extends StatelessWidget {
  /// Key of the card; its Remove button is "<id>-remove".
  final String id;
  final IconData icon;
  final String label;
  final String day;
  final String? time;
  final String note;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _TimeField({
    required this.id,
    required this.icon,
    required this.label,
    required this.day,
    required this.time,
    required this.note,
    required this.busy,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final isSet = time != null;
    return Material(
      color: primary.withValues(alpha: isSet ? 0.08 : 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: primary.withValues(alpha: isSet ? 0.35 : 0.2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key(id),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          day,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // The value, or the invitation. Not a button of its own:
                  // the whole card is the target.
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSet ? primary : primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isSet) ...[
                          Icon(Icons.schedule_rounded,
                              size: 16, color: primary),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          time ?? 'Set time',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color:
                                isSet ? theme.colorScheme.onPrimary : primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          note,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isSet
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                    if (onRemove != null)
                      TextButton(
                        key: Key('$id-remove'),
                        onPressed: busy ? null : onRemove,
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: const Text('Remove'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
