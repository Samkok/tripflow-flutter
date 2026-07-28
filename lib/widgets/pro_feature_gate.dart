import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/subscription_provider.dart';
import '../screens/paywall_screen.dart';

/// Widget that gates content behind the VoyZa Pro subscription
/// Shows the child if user has Pro, otherwise shows upgrade prompt
class ProFeatureGate extends ConsumerWidget {
  /// The content to show when user has Pro
  final Widget child;

  /// Optional widget to show when user doesn't have Pro
  /// If not provided, shows default upgrade prompt
  final Widget? lockedContent;

  /// Feature name to display in the upgrade prompt
  final String featureName;

  /// Optional description for the upgrade prompt
  final String? description;

  /// Whether to show inline upgrade button
  final bool showUpgradeButton;

  /// Callback when user upgrades successfully
  final VoidCallback? onUpgrade;

  const ProFeatureGate({
    super.key,
    required this.child,
    required this.featureName,
    this.lockedContent,
    this.description,
    this.showUpgradeButton = true,
    this.onUpgrade,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);

    if (isPro) {
      return child;
    }

    return lockedContent ?? _buildDefaultLockedContent(context, ref);
  }

  Widget _buildDefaultLockedContent(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.lock_outline,
              size: 32,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Pro Feature',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            featureName,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (showUpgradeButton) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showPaywall(context, ref),
              icon: const Icon(Icons.star_rounded, size: 18),
              label: const Text('Upgrade to Pro'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showPaywall(BuildContext context, WidgetRef ref) async {
    final result = await showPaywall(context);
    if (result) {
      onUpgrade?.call();
    }
  }
}

/// A simple lock icon button that shows paywall when tapped
/// Use this for features that should show a lock icon when not Pro
class ProLockButton extends ConsumerWidget {
  /// The action to perform when user is Pro
  final VoidCallback onUnlocked;

  /// Optional tooltip for the button
  final String? tooltip;

  /// Icon to show when unlocked
  final IconData unlockedIcon;

  /// Size of the icon
  final double iconSize;

  /// Color of the icon when locked
  final Color? lockedColor;

  const ProLockButton({
    super.key,
    required this.onUnlocked,
    this.tooltip,
    this.unlockedIcon = Icons.star_rounded,
    this.iconSize = 24,
    this.lockedColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final theme = Theme.of(context);

    return IconButton(
      onPressed: () {
        if (isPro) {
          onUnlocked();
        } else {
          showPaywall(context);
        }
      },
      icon: Icon(
        isPro ? unlockedIcon : Icons.lock_outline,
        size: iconSize,
        color: isPro ? null : (lockedColor ?? theme.colorScheme.outline),
      ),
      tooltip: isPro ? tooltip : 'Pro feature - Tap to upgrade',
    );
  }
}

/// Extension for easy Pro checks in widgets
extension ProFeatureExtension on WidgetRef {
  /// Check if user has VoyZa Pro
  bool get isPro => watch(isProProvider);

  /// Show paywall if user doesn't have Pro, returns true if user is Pro or upgrades
  Future<bool> requirePro(BuildContext context) async {
    if (isPro) return true;
    return await showPaywall(context);
  }
}

/// Mixin for StatefulWidgets that need Pro feature checks
mixin ProFeatureMixin<T extends StatefulWidget> on State<T> {
  /// Check Pro status and show paywall if needed
  /// Returns true if user is Pro or successfully upgrades
  Future<bool> requirePro(WidgetRef ref) async {
    final isPro = ref.read(isProProvider);
    if (isPro) return true;

    final result = await showPaywall(context);
    return result;
  }
}

/// Widget that conditionally shows content based on Pro status
/// Similar to Visibility widget but for Pro features
class ProVisibility extends ConsumerWidget {
  /// Child to show when user has Pro
  final Widget child;

  /// Replacement to show when user doesn't have Pro
  /// If null, shows nothing (SizedBox.shrink())
  final Widget? replacement;

  /// Whether to maintain the child's state when hidden
  final bool maintainState;

  const ProVisibility({
    super.key,
    required this.child,
    this.replacement,
    this.maintainState = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);

    if (isPro) {
      return child;
    }

    if (maintainState) {
      return Visibility(
        visible: false,
        maintainState: true,
        child: child,
      );
    }

    return replacement ?? const SizedBox.shrink();
  }
}

/// Banner widget to show at the top of screens for non-Pro users
/// Professional gradient design with feature highlights
class ProUpgradeBanner extends ConsumerWidget {
  /// Whether the banner can be dismissed
  final bool dismissible;

  /// Callback when banner is dismissed
  final VoidCallback? onDismiss;

  const ProUpgradeBanner({
    super.key,
    this.dismissible = false,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final theme = Theme.of(context);

    if (isPro) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary,
            theme.colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showPaywall(context),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Pro icon with glow effect
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Upgrade to VoyZa Pro',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        // High-arousal + hero-aligned: sell the outcome the
                        // user has felt (the reorder), not a feature count.
                        'Never zig-zag a city again — unlimited places, smart routes for every day.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
                // Action indicator
                if (dismissible)
                  IconButton(
                    onPressed: onDismiss,
                    icon: Icon(
                      Icons.close,
                      size: 20,
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  )
                else
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Upgrade',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
