import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A utility class for showing a custom date picker with highlighted dates.
class DatePickerUtils {
  /// Shows a custom date picker dialog that highlights specific dates with a
  /// marker dot. [highlightedDates] are the dates that contain locations.
  /// [highlightRange] (the trip's start→end) renders as a soft contiguous
  /// band behind the day cells, so the trip reads as a row on the calendar.
  static Future<DateTime?> showCustomDatePicker({
    required BuildContext context,
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
    required Set<DateTime> highlightedDates,
    DateTimeRange? highlightRange,
  }) async {
    final normalizedHighlights = <DateTime>{
      for (final d in highlightedDates) DateTime(d.year, d.month, d.day),
    };

    return showDialog<DateTime>(
      context: context,
      builder: (ctx) => _MarkedCalendarDialog(
        initialDate: _dateOnly(initialDate),
        firstDate: _dateOnly(firstDate),
        lastDate: _dateOnly(lastDate),
        highlightedDates: normalizedHighlights,
        highlightRange: highlightRange == null
            ? null
            : DateTimeRange(
                start: _dateOnly(highlightRange.start),
                end: _dateOnly(highlightRange.end),
              ),
      ),
    );
  }
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

class _MarkedCalendarDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final Set<DateTime> highlightedDates;
  final DateTimeRange? highlightRange;

  const _MarkedCalendarDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.highlightedDates,
    this.highlightRange,
  });

  @override
  State<_MarkedCalendarDialog> createState() => _MarkedCalendarDialogState();
}

class _MarkedCalendarDialogState extends State<_MarkedCalendarDialog> {
  late DateTime _selectedDate;
  late DateTime _displayedMonth;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate;
    _displayedMonth = DateTime(_selectedDate.year, _selectedDate.month);
  }

  bool get _canGoPrevMonth {
    final firstOfDisplayed =
        DateTime(_displayedMonth.year, _displayedMonth.month);
    final firstAllowed =
        DateTime(widget.firstDate.year, widget.firstDate.month);
    return firstOfDisplayed.isAfter(firstAllowed);
  }

  bool get _canGoNextMonth {
    final firstOfDisplayed =
        DateTime(_displayedMonth.year, _displayedMonth.month);
    final firstAllowed = DateTime(widget.lastDate.year, widget.lastDate.month);
    return firstOfDisplayed.isBefore(firstAllowed);
  }

  void _prevMonth() {
    if (!_canGoPrevMonth) return;
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month - 1);
    });
  }

  void _nextMonth() {
    if (!_canGoNextMonth) return;
    setState(() {
      _displayedMonth =
          DateTime(_displayedMonth.year, _displayedMonth.month + 1);
    });
  }

  bool _isSelectable(DateTime day) {
    return !day.isBefore(widget.firstDate) && !day.isAfter(widget.lastDate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: theme.cardColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme),
              const SizedBox(height: 12),
              _buildMonthNavigation(theme),
              const SizedBox(height: 8),
              _buildWeekdayHeader(theme),
              const SizedBox(height: 4),
              _buildDayGrid(theme, primary),
              const SizedBox(height: 8),
              _buildLegend(theme, primary),
              _buildActions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select date',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          DateFormat.yMMMd().format(_selectedDate),
          style: theme.textTheme.headlineSmall,
        ),
      ],
    );
  }

  Widget _buildMonthNavigation(ThemeData theme) {
    return Row(
      children: [
        IconButton(
          onPressed: _canGoPrevMonth ? _prevMonth : null,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous month',
        ),
        Expanded(
          child: Center(
            child: Text(
              DateFormat.yMMMM().format(_displayedMonth),
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          onPressed: _canGoNextMonth ? _nextMonth : null,
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next month',
        ),
      ],
    );
  }

  Widget _buildWeekdayHeader(ThemeData theme) {
    const labels = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    return Row(
      children: labels
          .map((l) => Expanded(
                child: Center(
                  child: Text(
                    l,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }

  Widget _buildDayGrid(ThemeData theme, Color primary) {
    final year = _displayedMonth.year;
    final month = _displayedMonth.month;
    final firstOfMonth = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    // Sunday=7 in Dart's weekday; we want Sunday=0 leading offset.
    final leading = firstOfMonth.weekday % 7;
    final totalCells = ((leading + daysInMonth) / 7).ceil() * 7;

    final today = _dateOnly(DateTime.now());

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: totalCells,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 1,
      ),
      itemBuilder: (context, index) {
        final dayNum = index - leading + 1;
        if (dayNum < 1 || dayNum > daysInMonth) {
          return const SizedBox.shrink();
        }
        final date = DateTime(year, month, dayNum);
        final selectable = _isSelectable(date);
        final isSelected = date == _selectedDate;
        final isToday = date == today;
        final hasLocations = widget.highlightedDates.contains(date);

        Color? bg;
        Color? fg;
        BoxBorder? border;

        if (isSelected) {
          bg = primary;
          fg = Colors.black;
        } else if (isToday) {
          border = Border.all(color: primary, width: 1.5);
          fg = primary;
        } else if (!selectable) {
          fg = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.3);
        } else {
          fg = theme.textTheme.bodyLarge?.color;
        }

        final dotColor = isSelected ? Colors.black : primary;

        final range = widget.highlightRange;
        final inTripRange = range != null &&
            !date.isBefore(range.start) &&
            !date.isAfter(range.end);
        final isRangeStart = inTripRange && date == range.start;
        final isRangeEnd = inTripRange && date == range.end;

        return InkWell(
          onTap: selectable ? () => setState(() => _selectedDate = date) : null,
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The trip's date range as a continuous row band. Full cell
              // width (outside the circle padding) so neighbors connect;
              // capped only at the range's two ends.
              if (inTripRange)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.horizontal(
                        left: isRangeStart
                            ? const Radius.circular(18)
                            : Radius.zero,
                        right: isRangeEnd
                            ? const Radius.circular(18)
                            : Radius.zero,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(2),
                child: Container(
                  decoration: BoxDecoration(
                    color: bg,
                    shape: BoxShape.circle,
                    border: border,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: Text(
                          '$dayNum',
                          style: TextStyle(
                            color: fg,
                            fontWeight: isSelected || isToday
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (hasLocations)
                        Positioned(
                          bottom: 4,
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: dotColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLegend(ThemeData theme, Color primary) {
    if (widget.highlightedDates.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            'Has locations',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final today = _dateOnly(DateTime.now());
    final canJumpToToday = _isSelectable(today);
    return Row(
      children: [
        TextButton.icon(
          onPressed: canJumpToToday
              ? () {
                  setState(() {
                    _selectedDate = today;
                    _displayedMonth = DateTime(today.year, today.month);
                  });
                }
              : null,
          icon: const Icon(Icons.today, size: 18),
          label: const Text('Today'),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_selectedDate),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
