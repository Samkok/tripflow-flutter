import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/trip_provider.dart';

/// Stay-duration picker dialog, shared by the trip-plan location card (its
/// "Stay" text button) and any other surface that needs to edit how long the
/// user plans to spend at a stop. Writes through
/// [TripNotifier.updateLocationStayDuration] on confirm — nothing is
/// committed until the user taps "Set".
void showStayDurationDialog(
    BuildContext context, WidgetRef ref, LocationModel location) {
  final List<Duration> presets = [
    const Duration(minutes: 15),
    const Duration(minutes: 30),
    const Duration(hours: 1),
    const Duration(hours: 2),
    const Duration(hours: 3),
    const Duration(hours: 4),
  ];

  final customController = TextEditingController();
  // Staged selection — NOTHING is written until the user confirms with
  // "Set". Hoisted outside the StatefulBuilder so setLocalState rebuilds
  // don't reset it.
  Duration selected = location.stayDuration;
  // Whether the staged value comes from the custom field (true) or a
  // quick-select preset (false).
  var customActive = false;
  // Custom-field unit: minutes or hours.
  var customUnitHours = false;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocalState) {
        // The staged custom duration, or null while the field is invalid.
        Duration? customDuration() {
          final raw = int.tryParse(customController.text.trim());
          if (raw == null || raw <= 0) return null;
          return customUnitHours
              ? Duration(hours: raw)
              : Duration(minutes: raw);
        }

        final staged = customActive ? customDuration() : selected;

        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.timer_outlined,
                    color: Theme.of(context).colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              const Text('Set Stay Duration'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(
                'Quick select',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Colors.grey[500],
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(height: 10),
              ...[
                [presets[0], presets[1], presets[2]],
                [presets[3], presets[4], presets[5]],
              ].map((rowPresets) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: rowPresets.expand((duration) {
                        final isSelected =
                            !customActive && selected == duration;
                        return [
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                // Stage only — "Set" below commits.
                                setLocalState(() {
                                  selected = duration;
                                  customActive = false;
                                  customController.clear();
                                });
                              },
                              borderRadius: BorderRadius.circular(10),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.2),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    _formatDuration(duration),
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.black
                                          : Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.color,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (duration != rowPresets.last)
                            const SizedBox(width: 8),
                        ];
                      }).toList(),
                    ),
                  )),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 14),
              // Custom duration — framed + labeled with an icon so it
              // reads as a real, tappable option rather than fine print.
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                decoration: BoxDecoration(
                  color: customActive
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.08)
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: customActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.25),
                    width: customActive ? 1.5 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.edit_rounded,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'Or type a custom duration',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: customController,
                            keyboardType: TextInputType.number,
                            onTap: () =>
                                setLocalState(() => customActive = true),
                            onChanged: (_) =>
                                setLocalState(() => customActive = true),
                            decoration: InputDecoration(
                              hintText: customUnitHours ? 'e.g. 2' : 'e.g. 45',
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surface,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 1.5,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Unit toggle: minutes | hours.
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('min')),
                            ButtonSegment(value: true, label: Text('hr')),
                          ],
                          selected: {customUnitHours},
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            textStyle: WidgetStatePropertyAll(
                              Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          onSelectionChanged: (sel) => setLocalState(() {
                            customUnitHours = sel.first;
                            if (customController.text.trim().isNotEmpty) {
                              customActive = true;
                            }
                          }),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      // The ONLY commit path — quick-selects and custom
                      // input both just stage until this confirms.
                      onPressed: staged == null
                          ? null
                          : () {
                              ref
                                  .read(tripProvider.notifier)
                                  .updateLocationStayDuration(
                                      location.id, staged);
                              Navigator.of(ctx).pop();
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(
                        staged == null
                            ? 'Set'
                            : 'Set ${_formatDuration(staged)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
          actions: const [],
        );
      },
    ),
  );
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
