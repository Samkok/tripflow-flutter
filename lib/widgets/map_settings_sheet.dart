import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/debounced_settings_provider.dart';
import '../providers/map_ui_state_provider.dart';

/// The map's settings in one sheet: the zone distance (slider + a tappable
/// value for typing it) and whether pins carry their names. Opened from the
/// plan sheet's tune icon.
Future<void> showMapSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const MapSettingsSheetBody(),
  );
}

class MapSettingsSheetBody extends ConsumerWidget {
  const MapSettingsSheetBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final threshold = ref.watch(proximityThresholdPreviewProvider);
    final showNames = ref.watch(showPlaceNamesProvider);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
        border: Border.all(color: primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, color: primary, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Map settings',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(color: primary, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text('Zone distance',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              // The value, tappable to type an exact distance.
              InkWell(
                key: const Key('map-settings-zone-value'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => showManualZoneDistanceDialog(context, ref),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primary),
                  ),
                  child: Text(
                    formatZoneDistance(threshold),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: primary, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: primary,
              inactiveTrackColor: primary.withValues(alpha: 0.3),
              thumbColor: primary,
              overlayColor: primary.withValues(alpha: 0.2),
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
            ),
            child: Slider(
              key: const Key('map-settings-zone-slider'),
              value: threshold.clamp(100.0, 5000.0),
              min: 100.0,
              max: 5000.0,
              divisions: 49,
              onChanged: (value) => ref
                  .read(debouncedProximityThresholdProvider.notifier)
                  .updatePreviewValue(value),
              onChangeEnd: (value) => ref
                  .read(debouncedProximityThresholdProvider.notifier)
                  .setValueImmediately(value),
            ),
          ),
          Text(
            'How close places must be to count as one zone. Smaller keeps '
            'zones tight; larger groups places that are further apart.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.5)),
          SwitchListTile.adaptive(
            key: const Key('map-settings-place-names'),
            value: showNames,
            onChanged: (v) =>
                ref.read(showPlaceNamesProvider.notifier).state = v,
            contentPadding: EdgeInsets.zero,
            activeTrackColor: primary,
            title: Text('Show place names',
                style: theme.textTheme.bodyLarge
                    ?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text('Labels next to the pins',
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

/// "850m" / "1.5km".
String formatZoneDistance(double meters) {
  if (meters < 1000) return '${meters.toInt()}m';
  return '${(meters / 1000).toStringAsFixed(1)}km';
}

/// Type the zone distance in metres (100–5000); anything else is ignored.
Future<void> showManualZoneDistanceDialog(
    BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController(
      text: ref.read(proximityThresholdPreviewProvider).toInt().toString());
  void apply(String raw) {
    final distance = double.tryParse(raw.trim());
    if (distance != null && distance >= 100 && distance <= 5000) {
      ref
          .read(debouncedProximityThresholdProvider.notifier)
          .setValueImmediately(distance);
    }
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Zone distance'),
      content: TextField(
        cursorOpacityAnimates: false,
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: const InputDecoration(
          hintText: 'Metres, 100 to 5000',
          suffixText: 'm',
        ),
        onSubmitted: (value) {
          apply(value);
          Navigator.of(dialogContext).pop();
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            apply(controller.text);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('Set'),
        ),
      ],
    ),
  );
  controller.dispose();
}
