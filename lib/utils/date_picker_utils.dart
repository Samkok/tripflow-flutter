import 'package:flutter/material.dart';

/// A utility class for showing a custom date picker with highlighted dates.
class DatePickerUtils {
  /// Shows a custom date picker dialog that can highlight specific dates.
  ///
  /// [context]: The build context.
  /// [initialDate]: The date initially selected.
  /// [firstDate]: The earliest allowable date.
  /// [lastDate]: The latest allowable date.
  /// [highlightedDates]: A set of dates to highlight in the calendar.
  static Future<DateTime?> showCustomDatePicker({
    required BuildContext context,
    required DateTime initialDate,
    required DateTime firstDate,
    required DateTime lastDate,
    required Set<DateTime> highlightedDates,
  }) async {
    return await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate
    );
  }
}