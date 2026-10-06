import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../utils/trip_dates.dart';
import '../utils/trip_times.dart';

/// The trip's arrival and departure times as one line of the trip page's
/// header card: "Arrive 3:00 PM · Leave 2:00 PM", with the way to change
/// them when [canEdit]. With nothing set it invites the owner to add them;
/// anyone else then sees no line at all.
class TripTimesHeaderRow extends StatelessWidget {
  final Trip trip;
  final bool canEdit;
  final VoidCallback onEdit;

  const TripTimesHeaderRow({
    super.key,
    required this.trip,
    required this.canEdit,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final summary =
        tripTimesSummary(trip, (m) => formatMinuteOfDay(context, m));
    if (summary == null && !canEdit) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 14, color: primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              summary ?? 'Arrival and departure times',
              style: theme.textTheme.bodySmall?.copyWith(
                color: summary == null
                    ? theme.colorScheme.onSurfaceVariant
                    : primary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canEdit)
            TextButton.icon(
              key: const Key('trip-times-edit'),
              onPressed: onEdit,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                  summary == null
                      ? Icons.more_time_rounded
                      : Icons.edit_outlined,
                  size: 16),
              label: Text(summary == null ? 'Add' : 'Edit'),
            ),
        ],
      ),
    );
  }
}

/// What goes under a day's header on the trip page: the arrival line on
/// the trip's first day, the departure line on its last (both on a one-day
/// trip), nothing on any other day. A line shows the time once set; until
/// then it is the owner's way to add it, right on the day it belongs to —
/// and absent for everyone else.
class TripDayTimeLines extends StatelessWidget {
  final Trip trip;
  final DateTime day;
  final bool canEdit;

  /// The owner tapped the arrival or the departure line.
  final ValueChanged<TripTimeField> onEdit;

  const TripDayTimeLines({
    super.key,
    required this.trip,
    required this.day,
    required this.canEdit,
    required this.onEdit,
  });

  /// True when [day] is the first or the last day of [trip] — the only
  /// days this widget can show anything on.
  static bool appliesTo(Trip trip, DateTime day) {
    final start = trip.startDate;
    final end = trip.endDate;
    if (start == null || end == null) return false;
    final d = dayKey(day);
    return d == dayKey(start) || d == dayKey(end);
  }

  @override
  Widget build(BuildContext context) {
    final start = trip.startDate;
    final end = trip.endDate;
    if (start == null || end == null) return const SizedBox.shrink();
    final d = dayKey(day);
    final lines = [
      if (d == dayKey(start) && (trip.arrivalMinute != null || canEdit))
        _TimeLine(
          arrival: true,
          minute: trip.arrivalMinute,
          onTap: canEdit ? () => onEdit(TripTimeField.arrival) : null,
        ),
      if (d == dayKey(end) && (trip.departureMinute != null || canEdit))
        _TimeLine(
          arrival: false,
          minute: trip.departureMinute,
          onTap: canEdit ? () => onEdit(TripTimeField.departure) : null,
        ),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(children: lines),
    );
  }
}

class _TimeLine extends StatelessWidget {
  final bool arrival;
  final int? minute;

  /// Null = shown, not editable.
  final VoidCallback? onTap;

  const _TimeLine({
    required this.arrival,
    required this.minute,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final minute = this.minute;
    final String text;
    if (minute == null) {
      text = arrival ? 'Add arrival time' : 'Add departure time';
    } else {
      text = '${arrival ? 'Arrive' : 'Leave'} '
          '${formatMinuteOfDay(context, minute)}';
    }
    return InkWell(
      key: Key(arrival ? 'day-arrival-time' : 'day-departure-time'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(
                arrival
                    ? Icons.flight_land_rounded
                    : Icons.flight_takeoff_rounded,
                size: 16,
                color: primary.withValues(alpha: minute == null ? 0.75 : 1),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: minute == null
                        ? primary.withValues(alpha: 0.85)
                        : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onTap != null && minute != null)
                Icon(Icons.edit_outlined,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}
