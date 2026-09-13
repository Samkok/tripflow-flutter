import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../providers/all_days_route_provider.dart';
import '../providers/trip_provider.dart';
import '../utils/place_tags.dart';

/// Colour key for the tagged pins on the single-day map: one row per tag
/// present on the selected day, dot + label, no background — the text
/// carries the same halo the pin names use so it reads over any tile.
/// Collapsible (the chevron folds it to its title; the choice is
/// remembered). Hidden in Entire-trip mode, where pins are coloured by
/// day, and when the day has no tagged pin.
///
/// Sits under the search column on the left, outside the map's measured
/// chrome, so the fit window keeps its full height — pins can pass behind
/// it, which is the price of having no background.
class TagLegend extends ConsumerStatefulWidget {
  const TagLegend({super.key});

  @override
  ConsumerState<TagLegend> createState() => _TagLegendState();
}

class _TagLegendState extends ConsumerState<TagLegend> {
  static const _prefsKey = 'map_tag_legend_collapsed';

  late bool _collapsed =
      SharedPrefsCache.maybeInstance?.getBool(_prefsKey) ?? false;

  void _toggle() {
    setState(() => _collapsed = !_collapsed);
    SharedPrefsCache.maybeInstance?.setBool(_prefsKey, _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(allDaysModeProvider)) return const SizedBox.shrink();
    final locations = ref.watch(locationsForSelectedDateProvider);
    // Only tags that are actually painted: done and skipped pins keep their
    // status colour, so they don't make a tag "present".
    final present = <PlaceTag>{
      for (final l in locations)
        if (!l.isDone && !l.isSkipped)
          if (placeTagFromKey(l.tag) case final t?) t,
    };
    if (present.isEmpty) return const SizedBox.shrink();
    final tags = PlaceTag.values.where(present.contains).toList();

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
            // Title doubles as the collapse toggle.
            InkWell(
              onTap: _toggle,
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
                    Text('Tags', style: rowStyle),
                  ],
                ),
              ),
            ),
            if (!_collapsed)
              for (final tag in tags)
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: tag.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                          boxShadow: const [
                            BoxShadow(color: Colors.black45, blurRadius: 2),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(tag.label, style: rowStyle),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
