import 'package:flutter/material.dart';

import '../services/analytics_consent_service.dart';

/// Shows the one-time analytics opt-in prompt to consent-required (EU/UK/CH)
/// users who haven't chosen yet, then records their choice. No-op otherwise.
/// Safe to call fire-and-forget from a post-frame callback.
Future<void> maybeShowAnalyticsConsent(BuildContext context) async {
  if (!await AnalyticsConsentService.instance.shouldAskForConsent()) return;
  if (!context.mounted) return;

  final granted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.insights_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            const Expanded(child: Text('Help improve VoyZa?')),
          ],
        ),
        content: Text(
          'We use privacy-friendly analytics to understand which features '
          'help travelers most, so we can make VoyZa better. No personal '
          'data is sold. You can change this anytime in Settings.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No thanks'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Allow'),
          ),
        ],
      );
    },
  );

  await AnalyticsConsentService.instance.setConsent(granted ?? false);
}
