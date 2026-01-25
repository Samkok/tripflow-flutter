import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/providers/theme_provider.dart';
import 'package:voyza/screens/terms_screen.dart';

import '../providers/auth_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/user_trip_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/subscription_provider.dart';
import '../widgets/logout_confirmation_dialog.dart';
import '../widgets/delete_account_dialog.dart';
import '../widgets/pro_feature_gate.dart';
import 'login_screen.dart';
import 'signup_screen.dart';
import 'subscription_management_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);
    final subscriptionState = ref.watch(subscriptionProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
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
              ? const ProUpgradeBanner() : const SizedBox.shrink(),
          const SizedBox(height: 16),

          // Profile Section
          _buildSectionHeader(context, 'Profile'),
          _buildProfileCard(context, ref),
          const SizedBox(height: 24),

          // Subscription Section
          _buildSectionHeader(context, 'Subscription'),
          _buildSubscriptionTile(context, ref),
          const SizedBox(height: 24),

          // Preferences Section
          _buildSectionHeader(context, 'Preferences'),
          _buildThemeTile(context, ref, themeMode),
          const SizedBox(height: 24),

          // About Section
          _buildSectionHeader(context, 'About'),
          _buildTermsTile(context),
          const SizedBox(height: 24),

          // Danger Zone - only show for authenticated users
          if (ref.watch(currentUserProvider) != null) ...[
            _buildDangerSection(context, ref),
            const SizedBox(height: 100),
          ] else
            const SizedBox(height: 100),
        ],
      ),
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
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: Theme.of(context).dividerColor.withOpacity(0.1),
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

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: Theme.of(context).dividerColor.withOpacity(0.1),
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
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
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
                  // Clear cached data before signing out
                  ref.invalidate(sharedTripsProvider);
                  ref.invalidate(userTripsProvider);
                  ref.invalidate(activeTripsProvider);
                  ref.invalidate(tripProvider);
                  
                  // Sign out
                  await ref.read(authServiceProvider).signOut();
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeTile(
      BuildContext context, WidgetRef ref, ThemeMode themeMode) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
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
            color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
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
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
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
            debugPrint('SettingsScreen: User returned, refreshing subscription state');
            await ref.read(subscriptionProvider.notifier).refresh();
            debugPrint('SettingsScreen: Current isPro state: ${ref.read(isProProvider)}');
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isPro
                ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                : Theme.of(context).colorScheme.secondary.withOpacity(0.1),
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

  Widget _buildTermsTile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
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
            color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
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
                  Icon(Icons.warning_rounded, color: Colors.red, size: 20),
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

  Future<void> _showDeleteAccountDialog(BuildContext context, WidgetRef ref) async {
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete account: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
