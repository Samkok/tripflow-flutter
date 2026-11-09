import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../providers/auth_provider.dart';
import '../providers/user_trip_provider.dart';
import '../screens/login_screen.dart';
import '../screens/signup_screen.dart';

/// "Save your trips with an account": the soft ask that replaced the
/// Sign-up screen after onboarding. Guests only, once a trip exists,
/// dismissible for good. Truthful: local trips merge into the account at
/// sign-in (TripRepository.syncLocalTripsToAccount).
class SaveTripsAccountCard extends ConsumerStatefulWidget {
  const SaveTripsAccountCard({super.key});

  static const prefsKey = 'save_trips_card_dismissed_v1';

  @override
  ConsumerState<SaveTripsAccountCard> createState() =>
      _SaveTripsAccountCardState();
}

class _SaveTripsAccountCardState extends ConsumerState<SaveTripsAccountCard> {
  late bool _dismissed =
      SharedPrefsCache.maybeInstance?.getBool(SaveTripsAccountCard.prefsKey) ??
          false;

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final prefs =
        SharedPrefsCache.maybeInstance ?? await SharedPreferences.getInstance();
    await prefs.setBool(SaveTripsAccountCard.prefsKey, true);
  }

  void _push(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    if (ref.watch(currentUserIdProvider) != null)
      return const SizedBox.shrink();
    final hasTrip = ref.watch(
        userTripsProvider.select((a) => a.valueOrNull?.isNotEmpty ?? false));
    if (!hasTrip) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        decoration: BoxDecoration(
          color: theme.cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_upload_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Save your trips with an account',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('They stay on this phone until you do.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: muted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: _dismiss,
                  icon: Icon(Icons.close_rounded, size: 18, color: muted),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonal(
                    onPressed: () => _push(const SignupScreen()),
                    child: const Text('Create account'),
                  ),
                  TextButton(
                    onPressed: () => _push(const LoginScreen()),
                    child: const Text('Sign in'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
