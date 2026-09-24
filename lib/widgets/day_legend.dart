import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../providers/all_days_route_provider.dart';
import '../utils/day_visibility.dart';

/// Colour key for the Entire-trip map: one row per day that has stops, in
/// the day's route colour — the counterpart of [TagLegend], which serves the
/// single-day map (each hides in the other's mode, so they share the slot
/// under the search column).
///
/// Every row is a switch. Tap a day to hide or show its pins and route;
/// hold a day to show only that day (hold again to bring the others back).
/// The last visible day can't be hidden — tapping it shows all days — so the
/// map never goes blank. "Show all" appears in the title row while anything
/// is hidden. Collapsible like the tag legend; the choice is remembered.
///
/// Unlike the tag legend it sits IN the chrome's layout flow, not overflowing
/// it: a widget can't be tapped outside its parent's bounds, and an
/// overflowing legend had dead rows. Long trips scroll inside a height cap
/// instead of pushing the map's fit window down the screen.
class DayLegend extends ConsumerStatefulWidget {
  const DayLegend({super.key});

  @override
  ConsumerState<DayLegend> createState() => _DayLegendState();
}

class _DayLegendState extends ConsumerState<DayLegend> {
  static const _prefsKey = 'map_day_legend_collapsed';

  late bool _collapsed =
      SharedPrefsCache.maybeInstance?.getBool(_prefsKey) ?? false;

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    SharedPrefsCache.maybeInstance?.setBool(_prefsKey, _collapsed);
  }

  List<DateTime> _days(List<DayLegendEntry> entries) =>
      [for (final e in entries) e.day];

  void _tap(DayLegendEntry entry, List<DayLegendEntry> entries) {
    final hidden = ref.read(hiddenTripDaysProvider.notifier);
    hidden.state = toggleDayVisibility(hidden.state, entry.day, _days(entries));
  }

  void _hold(DayLegendEntry entry, List<DayLegendEntry> entries) {
    HapticFeedback.selectionClick();
    final hidden = ref.read(hiddenTripDaysProvider.notifier);
    hidden.state = soloDayVisibility(hidden.state, entry.day, _days(entries));
  }

  void _showAll() {
    ref.read(hiddenTripDaysProvider.notifier).state = const <DateTime>{};
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(allDaysModeProvider)) return const SizedBox.shrink();
    final entries = ref.watch(tripDayLegendProvider);
    if (entries.isEmpty) return const SizedBox.shrink();
    final hiddenCount = entries.where((e) => !e.visible).length;

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final textColor = dark ? Colors.white : Colors.black87;
    final halo = <Shadow>[
      Shadow(
        color: dark
            ? Colors.black.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.95),
        blurRadius: 3,
      ),
      Shadow(
        color: dark
            ? Colors.black.withValues(alpha: 0.7)
            : Colors.white.withValues(alpha: 0.8),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
    ];
    final rowStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: textColor,
      shadows: halo,
      height: 1.2,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title doubles as the collapse toggle.
                InkWell(
                  onTap: _toggleCollapsed,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _collapsed
                              ? Icons.chevron_right_rounded
                              : Icons.expand_more_rounded,
                          size: 16,
                          color: textColor,
                          shadows: halo,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          hiddenCount == 0
                              ? 'Days'
                              : 'Days · ${entries.length - hiddenCount} of '
                                  '${entries.length}',
                          style: rowStyle,
                        ),
                      ],
                    ),
                  ),
                ),
                if (hiddenCount > 0) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _showAll,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        'Show all',
                        style: rowStyle.copyWith(
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                          decorationColor: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (!_collapsed)
              // Capped so a 20-day trip can't push the map's fit window
              // off the screen; ClampingScrollPhysics only takes drags once
              // there is something to scroll, so a short list never steals
              // a map pan.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                ),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in entries)
                        _row(entry, entries, rowStyle, textColor),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(DayLegendEntry entry, List<DayLegendEntry> entries,
      TextStyle rowStyle, Color textColor) {
    return InkWell(
      onTap: () => _tap(entry, entries),
      onLongPress: () => _hold(entry, entries),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 3, 6, 1),
        child: Opacity(
          opacity: entry.visible ? 1 : 0.45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Filled dot = drawn on the map; hollow = hidden.
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: entry.visible ? entry.color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: entry.visible ? Colors.white : entry.color,
                    width: entry.visible ? 1 : 2,
                  ),
                  boxShadow: const [
                    BoxShadow(color: Colors.black45, blurRadius: 2),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                entry.label,
                style: entry.visible
                    ? rowStyle
                    : rowStyle.copyWith(
                        decoration: TextDecoration.lineThrough,
                        decorationColor: textColor,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
