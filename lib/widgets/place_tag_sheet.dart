import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../utils/place_tags.dart';

/// A tag as a small pill: colour dot + label. Selected = tinted with the
/// tag's colour; [highlighted] draws the suggestion outline on an
/// unselected chip; [onTap] null = read-only.
class PlaceTagChip extends StatelessWidget {
  final PlaceTag tag;
  final bool selected;
  final bool highlighted;
  final bool dense;
  final VoidCallback? onTap;

  const PlaceTagChip({
    super.key,
    required this.tag,
    this.selected = false,
    this.highlighted = false,
    this.dense = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tag.color;
    final fg = selected ? color : theme.colorScheme.onSurface;
    final border = selected
        ? color
        : highlighted
            ? color.withValues(alpha: 0.7)
            : theme.dividerColor.withValues(alpha: 0.6);
    return Material(
      color: selected ? color.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 8 : 12,
            vertical: dense ? 4 : 7,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border, width: selected ? 1.4 : 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: dense ? 8 : 10,
                height: dense ? 8 : 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1),
                ),
              ),
              SizedBox(width: dense ? 5 : 7),
              Text(
                tag.label,
                style: (dense
                        ? theme.textTheme.labelSmall
                        : theme.textTheme.labelMedium)
                    ?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the tag sheet returned: [tag] null means "no tag". A dismissed
/// sheet returns no [PlaceTagPick] at all, so callers can tell "chose
/// nothing" from "chose no tag" where that matters.
class PlaceTagPick {
  final PlaceTag? tag;
  const PlaceTagPick(this.tag);
}

/// Lets the user confirm, change or decline a tag for [placeName]. The
/// [suggested] tag (from Google's place types) starts selected — tapping
/// Confirm keeps it, tapping another chip swaps it, "No tag" drops it.
/// [current] wins over the suggestion when editing an already-tagged stop.
Future<PlaceTagPick?> showPlaceTagSheet(
  BuildContext context, {
  required String placeName,
  PlaceTag? suggested,
  PlaceTag? current,
  String confirmLabel = 'Confirm',
}) {
  return showModalBottomSheet<PlaceTagPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (ctx) => _PlaceTagSheet(
      placeName: placeName,
      suggested: suggested,
      initial: current ?? suggested,
      confirmLabel: confirmLabel,
    ),
  );
}

class _PlaceTagSheet extends StatefulWidget {
  final String placeName;
  final PlaceTag? suggested;
  final PlaceTag? initial;
  final String confirmLabel;

  const _PlaceTagSheet({
    required this.placeName,
    required this.suggested,
    required this.initial,
    required this.confirmLabel,
  });

  @override
  State<_PlaceTagSheet> createState() => _PlaceTagSheetState();
}

class _PlaceTagSheetState extends State<_PlaceTagSheet> {
  late PlaceTag? _selected = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggested = widget.suggested;
    final hint = suggested == null
        ? 'Pick a tag, or add it without one.'
        : 'Suggested from the place type — change it if it\'s wrong.';
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
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
            Text(
              'Tag this place',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              widget.placeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in PlaceTag.values)
                  PlaceTagChip(
                    tag: t,
                    selected: t == _selected,
                    highlighted: t == suggested,
                    onTap: () =>
                        setState(() => _selected = (_selected == t) ? null : t),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        Navigator.of(context).pop(const PlaceTagPick(null)),
                    child: const Text('No tag'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(PlaceTagPick(_selected)),
                    icon: Icon(
                      _selected?.icon ?? Icons.label_off_outlined,
                      size: 18,
                    ),
                    label: Text(_selected == null
                        ? 'Add without a tag'
                        : '${widget.confirmLabel}: ${_selected!.label}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
