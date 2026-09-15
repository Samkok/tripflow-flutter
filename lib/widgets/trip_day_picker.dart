import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../utils/trip_day_labels.dart';
import '../utils/trip_dates.dart';

/// Day picker for trips without dates: a list of "Day 1 … Day N" instead
/// of a calendar. [days] is the trip's day list ([contiguousTripDates]);
/// [marked] days show a dot (they already hold places); [selected] is
/// pre-highlighted. Returns the picked day (a date on the anchor) or null
/// when dismissed.
Future<DateTime?> showTripDayPicker(
  BuildContext context, {
  required List<DateTime> days,
  required DayLabeler labeler,
  DateTime? selected,
  Set<DateTime> marked = const {},
  String title = 'Pick a day',
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (ctx) => _DayListSheet(
      days: days,
      labeler: labeler,
      selected: selected == null ? null : dayKey(selected),
      marked: {for (final d in marked) dayKey(d)},
      title: title,
    ),
  );
}

/// Two-step range picker (first day, then last day) for a stay on a trip
/// without dates. Returns null when either step is dismissed.
Future<DateTimeRange?> showTripDayRangePicker(
  BuildContext context, {
  required List<DateTime> days,
  required DayLabeler labeler,
  DateTimeRange? initial,
}) async {
  final first = await showTripDayPicker(
    context,
    days: days,
    labeler: labeler,
    selected: initial?.start,
    title: 'First day of the stay',
  );
  if (first == null || !context.mounted) return null;
  final after = days.where((d) => !dayKey(d).isBefore(first)).toList();
  final initialEnd = initial != null && !dayKey(initial.end).isBefore(first)
      ? initial.end
      : first;
  final last = await showTripDayPicker(
    context,
    days: after,
    labeler: labeler,
    selected: initialEnd,
    title: 'Last day of the stay',
  );
  if (last == null) return null;
  return DateTimeRange(start: first, end: last);
}

class _DayListSheet extends StatelessWidget {
  final List<DateTime> days;
  final DayLabeler labeler;
  final DateTime? selected;
  final Set<DateTime> marked;
  final String title;

  const _DayListSheet({
    required this.days,
    required this.labeler,
    required this.selected,
    required this.marked,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final maxHeight = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.sheetBorderColor(context)),
        ),
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
                title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
              child: Text(
                'This trip has no dates yet — its days are numbered.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: days.length,
                itemBuilder: (context, i) {
                  final day = dayKey(days[i]);
                  final isSelected = selected != null && day == selected;
                  final hasPlaces = marked.contains(day);
                  return ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    selected: isSelected,
                    selectedTileColor: primary.withValues(alpha: 0.10),
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: isSelected
                          ? primary
                          : primary.withValues(alpha: 0.12),
                      foregroundColor:
                          isSelected ? theme.colorScheme.onPrimary : primary,
                      child: Text(
                        '${labeler.dayNumber(day)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    ),
                    title: Text(
                      labeler(day),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: hasPlaces ? const Text('Has places') : null,
                    trailing: isSelected
                        ? Icon(Icons.check_rounded, color: primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(day),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
