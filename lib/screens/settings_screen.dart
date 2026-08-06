import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:url_launcher/url_launcher.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/providers/theme_provider.dart';
import 'package:voyza/providers/onboarding_provider.dart';
import 'package:voyza/screens/terms_screen.dart';
import 'package:voyza/services/review_prompt_service.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

import '../providers/auth_provider.dart';
import '../providers/nearby_radius_provider.dart';
import '../providers/zoom_fit_settings_provider.dart';
import '../services/notification_service.dart';
import '../services/analytics_consent_service.dart';
import '../providers/referral_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/user_trip_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart';
import '../widgets/logout_confirmation_dialog.dart';
import '../widgets/delete_account_dialog.dart';
import '../widgets/pro_feature_gate.dart';
import '../services/time_saved_ledger_service.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'referral_screen.dart';
import 'security_screen.dart';
import 'signup_screen.dart';
import 'subscription_management_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final subscriptionState = ref.watch(subscriptionProvider);

    return Stack(
      children: [
        // Ambient rotating globe behind the whole page (the translucent
        // cards let it show through). Paused while this tab is offstage.
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: RotatingGlobeBackground(
              animate: ref.watch(selectedTabIndexProvider) == 2,
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Settings'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              // Pro upgrade banner for non-Pro users
              !subscriptionState.isPro
                  ? const ProUpgradeBanner()
                  : const SizedBox.shrink(),
              const SizedBox(height: 16),

              // Profile Section
              _buildSectionHeader(context, 'Profile'),
              _buildProfileCard(context, ref),
              const SizedBox(height: 24),

              // Invite friends — referral program (signed-in users only).
              // Top of the page (owner call): the growth surface leads.
              if (ref.watch(currentUserProvider) != null) ...[
                _buildSectionHeader(context, 'Invite friends'),
                _buildInviteFriendsTile(context, ref),
                const SizedBox(height: 24),
              ],

              // Free Trial Section — visible only while a native intro free
              // trial is active (RevenueCat reports periodType == trial).
              if (ref.watch(isInTrialProvider)) ...[
                _buildSectionHeader(context, 'Free Trial'),
                const _TrialStatusTile(),
                const SizedBox(height: 24),
              ],

              // Subscription Section
              _buildSectionHeader(context, 'Subscription'),
              _buildSubscriptionTile(context, ref),
              const SizedBox(height: 24),

              // Security Section (only for signed-in users)
              if (ref.watch(currentUserProvider) != null) ...[
                _buildSectionHeader(context, 'Security'),
                _buildSecurityTile(context),
                const SizedBox(height: 24),
              ],

              // Preferences Section
              // Social currency: the compounding lifetime stat. Renders nothing
              // until the user has actually saved time (no "0m" flex).
              const _TimeSavedStatTile(),

              _buildSectionHeader(context, 'Preferences'),
              _buildThemeTile(context, ref, themeMode),
              const SizedBox(height: 12),
              const _NotificationTile(),
              const SizedBox(height: 12),
              const _LocationTile(),
              const SizedBox(height: 12),
              const _NearbyRadiusTile(),
              const SizedBox(height: 12),
              const _IncludeCurrentInFitTile(),
              const SizedBox(height: 12),
              const _AnalyticsTile(),
              const SizedBox(height: 24),

              // About Section
              _buildSectionHeader(context, 'About'),
              _buildTermsTile(context),
              const SizedBox(height: 12),
              _buildPrivacyTile(context),
              const SizedBox(height: 12),
              _buildRateTile(context),
              const SizedBox(height: 12),
              _buildFeedbackTile(context),
              const SizedBox(height: 24),

              // Danger Zone - only show for authenticated users
              if (ref.watch(currentUserProvider) != null) ...[
                _buildDangerSection(context, ref),
                const SizedBox(height: 100),
              ] else
                const SizedBox(height: 100),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0, left: 4.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context, WidgetRef ref) {
    final currentUser = ref.watch(currentUserProvider);

    if (currentUser == null) {
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              'Sign in to sync your trips',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (context) => const LoginScreen()),
                      );
                    },
                    child: const Text('Sign In'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (context) => const SignupScreen()),
                      );
                    },
                    child: const Text('Sign Up'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ProfileScreen()),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: AppTheme.primaryColor,
                  child: Text(
                    currentUser.email?.substring(0, 1).toUpperCase() ?? 'U',
                    style: const TextStyle(
                      fontSize: 24,
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentUser.email ?? 'User',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Account Sync Active',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Colors.green,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final shouldLogout = await showDialog<bool>(
                    context: context,
                    builder: (context) => const LogoutConfirmationDialog(),
                  );

                  if (shouldLogout == true) {
                    // Clear cached data BEFORE signing out so the brief
                    // window between auth tear-down and navigator swap
                    // doesn't re-render stale trip/location data.
                    ref.invalidate(sharedTripsProvider);
                    ref.invalidate(userTripsProvider);
                    ref.invalidate(activeTripsProvider);
                    ref.invalidate(tripProvider);

                    // Kick off subscription reinit in parallel — it
                    // doesn't gate navigation, so awaiting it just adds
                    // perceived sign-out latency.
                    ref.read(subscriptionProvider.notifier).reinitialize();

                    // signOut now finishes in ~100–300 ms (local clears
                    // only; network cleanups fire-and-forget). The
                    // `signedOut` event triggers main.dart's listener
                    // which swaps to LoginScreen.
                    await ref.read(authServiceProvider).signOut();
                  }
                },
                icon: const Icon(Icons.logout),
                label: const Text('Sign Out'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThemeTile(
      BuildContext context, WidgetRef ref, ThemeMode themeMode) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        title: const Text('Dark Mode'),
        subtitle: const Text('Toggle app appearance'),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            themeMode == ThemeMode.dark ? Icons.dark_mode : Icons.light_mode,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        value: themeMode == ThemeMode.dark,
        onChanged: (value) {
          ref.read(themeProvider.notifier).toggleTheme();
        },
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildSubscriptionTile(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () async {
          // Navigate to subscription management and wait for return
          await navigateToSubscriptionManagement(context);

          // Refresh subscription state when user returns
          if (context.mounted) {
            debugPrint(
                'SettingsScreen: User returned, refreshing subscription state');
            await ref.read(subscriptionProvider.notifier).refresh();
            debugPrint(
                'SettingsScreen: Current isPro state: ${ref.read(isProProvider)}');
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isPro
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                : Theme.of(context)
                    .colorScheme
                    .secondary
                    .withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            isPro ? Icons.star_rounded : Icons.star_outline_rounded,
            color: isPro
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.secondary,
          ),
        ),
        title: Text(isPro ? 'VoyZa Pro' : 'Upgrade to Pro'),
        subtitle: Text(
          isPro ? 'Manage your subscription' : 'Unlock all premium features',
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildSecurityTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SecurityScreen()),
          );
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.lock_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Change Password'),
        subtitle: const Text('Update your account password'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildInviteFriendsTile(BuildContext context, WidgetRef ref) {
    // Mirror the referral screen's banked-months card: when the user has
    // earned months parked behind an active paid plan, this tile says so
    // instead of the generic pitch.
    final monthsBanked = ref.watch(referralMonthsBankedProvider);
    const bankedColor = Color(0xFF38BDF8);
    final banked = monthsBanked > 0;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const ReferralScreen()),
          );
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: banked
                ? bankedColor.withValues(alpha: 0.12)
                : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            banked ? Icons.savings_rounded : Icons.card_giftcard_rounded,
            color: banked ? bankedColor : Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Invite friends'),
        subtitle: Text(
          banked
              ? (monthsBanked == 1
                  ? '1 free month banked — starts when your plan ends'
                  : '$monthsBanked free months banked — start when your plan ends')
              : 'Give a month of Pro, get a month free',
          style: banked
              ? const TextStyle(color: bankedColor, fontWeight: FontWeight.w600)
              : null,
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      ),
    );
  }

  Widget _buildTermsTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const TermsScreen()),
          );
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.description_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Terms & Conditions'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildPrivacyTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () async {
          final uri = Uri.parse('https://voyza.xtremon.com/privacy');
          if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            if (context.mounted) {
              AppToast.error(context, 'Could not open the privacy policy.');
            }
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.privacy_tip_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Privacy Policy'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildRateTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () async {
          final shown =
              await ReviewPromptService.instance.requestReviewManually();
          if (!shown && context.mounted) {
            // The OS may silently no-op (e.g. Apple annual cap, Simulator,
            // sideloaded build). Surface a small hint so the tap doesn't
            // look broken.
            AppToast.info(
              context,
              'Thanks! The rating prompt is unavailable right now — '
              'please try again later.',
            );
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.star_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Rate VoyZa'),
        subtitle: const Text('Enjoying the app? Leave a quick review'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildFeedbackTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        onTap: () async {
          final uri = Uri(
            scheme: 'mailto',
            path: 'hengsamkok76@gmail.com',
            queryParameters: {'subject': 'VoyZa Feedback'},
          );
          try {
            final ok = await launchUrl(uri);
            if (!ok && context.mounted) {
              AppToast.warning(
                context,
                'No mail app available. Email us at hengsamkok76@gmail.com',
              );
            }
          } catch (_) {
            if (context.mounted) {
              AppToast.error(
                context,
                'Could not open mail. Email us at hengsamkok76@gmail.com',
              );
            }
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.mail_outline_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: const Text('Send Feedback'),
        subtitle: const Text('Report a bug or suggest a feature'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }

  Widget _buildDangerSection(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12.0, left: 4.0),
          child: Text(
            'Danger Zone',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.red,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.05),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.warning_rounded,
                      color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Delete Account',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Permanently delete your account and all associated data. This action cannot be undone.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _showDeleteAccountDialog(context, ref),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Delete My Account'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showDeleteAccountDialog(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const DeleteAccountDialog(),
    );

    if (confirmed == true && context.mounted) {
      // Show loading and proceed with deletion
      _deleteAccount(context, ref);
    }
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Deleting your account...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final authService = ref.read(authServiceProvider);
      await authService.deleteAccount();

      // Account deleted successfully - navigation will be handled by auth state change
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        AppToast.error(context, 'Failed to delete account: ${e.toString()}');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Location permission tile — manages its own async state
// ---------------------------------------------------------------------------

class _LocationTile extends StatefulWidget {
  const _LocationTile();

  @override
  State<_LocationTile> createState() => _LocationTileState();
}

class _LocationTileState extends State<_LocationTile>
    with WidgetsBindingObserver {
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check when user returns from system Settings app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadState();
  }

  Future<void> _loadState() async {
    try {
      final permission = await Geolocator.checkPermission();
      final granted = permission == LocationPermission.whileInUse;
      if (mounted)
        setState(() {
          _enabled = granted;
          _loading = false;
        });
    } catch (e) {
      debugPrint('_LocationTile: _loadState failed: $e');
      if (mounted)
        setState(() {
          _enabled = false;
          _loading = false;
        });
    }
  }

  Future<void> _onToggle(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        var permission = await Geolocator.checkPermission();

        // Permanently denied — dialog suppressed, must go to settings
        if (permission == LocationPermission.deniedForever) {
          await ph.openAppSettings();
          if (mounted) setState(() => _loading = false);
          return;
        }

        // Request shows the OS permission dialog
        permission = await Geolocator.requestPermission();

        if (permission == LocationPermission.whileInUse) {
          if (mounted)
            setState(() {
              _enabled = true;
              _loading = false;
            });
        } else if (permission == LocationPermission.deniedForever) {
          // "Don't ask again" was selected — open settings
          await ph.openAppSettings();
          if (mounted)
            setState(() {
              _enabled = false;
              _loading = false;
            });
        } else {
          // User tapped Deny on the dialog
          if (mounted) {
            AppToast.warning(
              context,
              'Location permission denied. Enable it in System Settings.',
            );
            setState(() {
              _enabled = false;
              _loading = false;
            });
          }
        }
      } else {
        // Cannot revoke programmatically — direct user to system settings
        await ph.openAppSettings();
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('_LocationTile: _onToggle failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        title: const Text('Location Access'),
        subtitle: const Text('Used for map and nearby search'),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _enabled ? Icons.location_on_rounded : Icons.location_off_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        value: _enabled,
        onChanged: _loading ? null : _onToggle,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notification toggle tile — manages its own async state
// ---------------------------------------------------------------------------

class _NotificationTile extends StatefulWidget {
  const _NotificationTile();

  @override
  State<_NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<_NotificationTile>
    with WidgetsBindingObserver {
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check when user returns from system Settings app
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadState();
  }

  Future<void> _loadState() async {
    try {
      final svc = NotificationService();
      final pref = await svc.getPreference();
      final granted = await svc.isSystemPermissionGranted();

      final effective = pref && granted;
      if (pref && !granted) {
        await NotificationService().disableNotifications();
      }

      if (mounted)
        setState(() {
          _enabled = effective;
          _loading = false;
        });
    } catch (e) {
      debugPrint('_NotificationTile: _loadState failed: $e');
      if (mounted)
        setState(() {
          _enabled = false;
          _loading = false;
        });
    }
  }

  Future<void> _onToggle(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        final granted = await NotificationService().enableNotifications();
        if (!granted && mounted) {
          AppToast.warning(
            context,
            'Permission denied. Enable notifications in System Settings.',
          );
        }
        if (mounted)
          setState(() {
            _enabled = granted;
            _loading = false;
          });
      } else {
        await NotificationService().disableNotifications();
        if (mounted)
          setState(() {
            _enabled = false;
            _loading = false;
          });
      }
    } catch (e) {
      debugPrint('_NotificationTile: _onToggle failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        title: const Text('Push Notifications'),
        subtitle: const Text('Trip invites and activity alerts'),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _enabled
                ? Icons.notifications_rounded
                : Icons.notifications_off_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        value: _enabled,
        onChanged: _loading ? null : _onToggle,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Nearby radius tile — slider that controls how far the long-press POI
// search reaches around the tapped coordinate on the map screen. Persisted
// via [nearbyRadiusProvider]; default 300m.
// ---------------------------------------------------------------------------

class _NearbyRadiusTile extends ConsumerWidget {
  const _NearbyRadiusTile();

  String _format(double meters) {
    final m = meters.round();
    if (m < 1000) return '${m}m';
    return '${(m / 1000).toStringAsFixed(m % 1000 == 0 ? 0 : 1)}km';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(nearbyRadiusProvider);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.radar_outlined,
                  color: theme.colorScheme.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nearby places radius',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'When you long-press the map, places within this distance show up.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _format(value),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: NearbyRadiusNotifier.minRadius,
            max: NearbyRadiusNotifier.maxRadius,
            divisions: 19,
            label: _format(value),
            onChanged: (v) => ref.read(nearbyRadiusProvider.notifier).set(v),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Include current location in zoom-to-fit — toggles whether the map's
// "zoom to fit" FAB also fits the device's current position into the
// camera bounds. Defaults to on; persisted via [includeCurrentInFitProvider].
// ---------------------------------------------------------------------------

/// Settings toggle for analytics consent. Reflects the effective state
/// (EU/UK/CH default OFF; elsewhere ON) and lets the user opt in/out anytime.
class _AnalyticsTile extends StatefulWidget {
  const _AnalyticsTile();

  @override
  State<_AnalyticsTile> createState() => _AnalyticsTileState();
}

class _AnalyticsTileState extends State<_AnalyticsTile> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    AnalyticsConsentService.instance.isEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        value: _enabled ?? false,
        onChanged: _enabled == null
            ? null
            : (v) async {
                setState(() => _enabled = v);
                await AnalyticsConsentService.instance.setConsent(v);
              },
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.insights_rounded, color: theme.colorScheme.primary),
        ),
        title: const Text('Share usage analytics'),
        subtitle: const Text('Privacy-friendly. Helps us improve VoyZa.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

class _IncludeCurrentInFitTile extends ConsumerWidget {
  const _IncludeCurrentInFitTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(includeCurrentInFitProvider);
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary:
            Icon(Icons.my_location, color: theme.colorScheme.primary, size: 22),
        title: Text(
          'Include current location in fit',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          'When you tap the zoom-to-fit button, also frame your current location alongside your stops.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value: value,
        onChanged: (v) => ref.read(includeCurrentInFitProvider.notifier).set(v),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Trial status tile — countdown card for the settings page. Visible only
// while the user is in the store-managed introductory free trial; outside
// that window the entire "Free Trial" section is hidden by the parent.
// ---------------------------------------------------------------------------

class _TrialStatusTile extends ConsumerStatefulWidget {
  const _TrialStatusTile();

  @override
  ConsumerState<_TrialStatusTile> createState() => _TrialStatusTileState();
}

class _TrialStatusTileState extends ConsumerState<_TrialStatusTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-render once a minute so the "X hours left" copy stays accurate
    // without depending on provider invalidation.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final days = d.inDays;
    if (days >= 1) {
      final hours = d.inHours.remainder(24);
      return hours > 0
          ? '$days day${days == 1 ? '' : 's'}, $hours hr left'
          : '$days day${days == 1 ? '' : 's'} left';
    }
    if (d.inHours >= 1) {
      final hours = d.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} left';
    }
    final minutes = d.inMinutes;
    return '$minutes min${minutes == 1 ? '' : 's'} left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entitlement = ref.watch(activeTrialEntitlementProvider);

    // Parent's `if (isInTrialProvider)` guard usually prevents this, but
    // keep the defensive null-return in case state flips between frames.
    if (entitlement == null) return const SizedBox.shrink();
    final expiresAt = DateTime.tryParse(entitlement.expirationDate ?? '');
    if (expiresAt == null) return const SizedBox.shrink();
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining <= Duration.zero) return const SizedBox.shrink();

    final isUrgent = remaining < const Duration(hours: 24);
    final accent =
        isUrgent ? theme.colorScheme.error : theme.colorScheme.primary;
    final progress = 1 -
        (remaining.inSeconds / const Duration(days: 3).inSeconds)
            .clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isUrgent ? Icons.access_time_filled : Icons.access_time,
                  color: accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Free trial active',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _format(remaining),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: accent.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => showPaywall(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text(
                'Manage subscription',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lifetime "time saved with VoyZa" stat — the user's compounding win.
/// Hidden entirely until at least 5 minutes have accrued, so a fresh install
/// never shows an empty brag.
class _TimeSavedStatTile extends StatelessWidget {
  const _TimeSavedStatTile();

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Duration>(
      future: TimeSavedLedgerService.instance.total(),
      builder: (context, snap) {
        final total = snap.data ?? Duration.zero;
        if (total < const Duration(minutes: 5)) {
          return const SizedBox.shrink();
        }
        final primary = Theme.of(context).colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primary.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, color: primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Time saved with VoyZa',
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '~${_format(total)}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: primary,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
