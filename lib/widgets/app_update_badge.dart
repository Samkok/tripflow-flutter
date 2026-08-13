import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_update_provider.dart';
import '../providers/onboarding_checklist_provider.dart';

/// Floating "Update" pill for the home page's top-right corner.
///
/// Design constraints it satisfies (owner-specified):
///   • an OVERLAY, not in-flow — its async arrival can never shift the page
///     or the checklist spotlight targets below;
///   • positioned by the caller under the status bar / Dynamic Island inset;
///   • dismissible per release (the X hides THIS version's badge; the next
///     release brings it back);
///   • suppressed while the onboarding checklist is still running, so it
///     never competes with the tutorial.
///
/// Tap → the platform's store listing. Copy is deliberately minimal
/// ("Update available" — no version, no store name; owner call).
class AppUpdateBadge extends ConsumerWidget {
  const AppUpdateBadge({super.key});

  static const _appStoreUrl = 'https://apps.apple.com/app/id6758559163';
  static const _playMarketUrl = 'market://details?id=com.superiordev.voyza';
  static const _playWebUrl =
      'https://play.google.com/store/apps/details?id=com.superiordev.voyza';

  Future<void> _openStore() async {
    if (Platform.isAndroid) {
      // Prefer the Play app; fall back to the web listing.
      if (await launchUrl(Uri.parse(_playMarketUrl),
          mode: LaunchMode.externalApplication)) {
        return;
      }
      await launchUrl(Uri.parse(_playWebUrl),
          mode: LaunchMode.externalApplication);
      return;
    }
    await launchUrl(Uri.parse(_appStoreUrl),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tutorial first: while the checklist is neither finished nor skipped,
    // the user is still inside the guided flow — stay out of it.
    final checklist = ref.watch(checklistProvider);
    if (!checklist.isComplete && !checklist.skipped) {
      return const SizedBox.shrink();
    }

    final update = ref.watch(appUpdateProvider).valueOrNull;
    final dismissed = ref.watch(updateBadgeDismissedProvider);
    if (update == null || update.versionKey == dismissed) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: primary.withValues(alpha: 0.55)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(20)),
              onTap: _openStore,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.system_update_alt_rounded,
                        size: 14, color: primary),
                    const SizedBox(width: 6),
                    Text(
                      'Update available',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              borderRadius:
                  const BorderRadius.horizontal(right: Radius.circular(20)),
              onTap: () => dismissUpdateBadge(ref, update.versionKey),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 7, 10, 7),
                child: Icon(Icons.close_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.8)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
