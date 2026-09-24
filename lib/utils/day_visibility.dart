/// Which trip days the Entire-trip map shows.
///
/// The All-days overlay draws every day of the trip at once; the day legend
/// lets the traveller hide days to compare or declutter. The state is the
/// set of HIDDEN days (empty = everything shown), so a day added to the trip
/// later shows up by default and a removed day's stale key is harmless.
///
/// One rule runs through all of it: the map never goes blank. The last
/// visible day cannot be hidden — tapping it brings every day back.
library;

/// The hidden set actually applied: [hidden] unless it would hide every one
/// of [days], in which case nothing is hidden. (The only visible day can
/// disappear from the trip — its stops rescheduled, the day removed — and
/// the map must not stay empty because of a stale key.)
Set<DateTime> effectiveHiddenDays(
    Set<DateTime> hidden, Iterable<DateTime> days) {
  if (hidden.isEmpty) return hidden;
  return days.any((d) => !hidden.contains(d)) ? hidden : const <DateTime>{};
}

/// A tap on a legend row: hide a visible day, show a hidden one. Tapping the
/// only visible day shows all days again instead of emptying the map.
Set<DateTime> toggleDayVisibility(
    Set<DateTime> hidden, DateTime day, Iterable<DateTime> days) {
  final effective = effectiveHiddenDays(hidden, days);
  if (effective.contains(day)) return {...effective}..remove(day);
  final visible = days.where((d) => !effective.contains(d)).length;
  if (visible <= 1) return const <DateTime>{};
  return {...effective, day};
}

/// A long-press on a legend row: show only [day]. Long-pressing the day that
/// is already the only one shown restores all days.
Set<DateTime> soloDayVisibility(
    Set<DateTime> hidden, DateTime day, Iterable<DateTime> days) {
  final effective = effectiveHiddenDays(hidden, days);
  final others = days.where((d) => d != day).toList();
  final alreadySolo =
      !effective.contains(day) && others.every(effective.contains);
  if (alreadySolo) return const <DateTime>{};
  return {...others};
}
