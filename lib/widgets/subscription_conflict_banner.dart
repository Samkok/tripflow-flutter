import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/subscription_provider.dart';

/// Banner widget that displays when there's a conflict between database and SDK subscription status
class SubscriptionConflictBanner extends ConsumerWidget {
  const SubscriptionConflictBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptionState = ref.watch(subscriptionProvider);
    final conflict = subscriptionState.activeConflict;

    if (conflict == null) {
      return const SizedBox.shrink();
    }

    return Material(
      color: _getBackgroundColor(conflict.conflictType),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                _getIcon(conflict.conflictType),
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      conflict.userMessage,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _getDetailMessage(conflict),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getBackgroundColor(String conflictType) {
    switch (conflictType) {
      case 'expired_vs_active':
        return Colors.green.shade600; // Good news - user has access
      case 'active_vs_expired':
        return Colors.orange.shade600; // Warning - sync in progress
      case 'plan_mismatch':
        return Colors.blue.shade600; // Info - plan details updating
      case 'renewal_mismatch':
        return Colors.blue.shade600; // Info - renewal settings updating
      default:
        return Colors.amber.shade600;
    }
  }

  IconData _getIcon(String conflictType) {
    switch (conflictType) {
      case 'expired_vs_active':
        return Icons.check_circle_outline;
      case 'active_vs_expired':
        return Icons.sync;
      case 'plan_mismatch':
        return Icons.info_outline;
      case 'renewal_mismatch':
        return Icons.info_outline;
      default:
        return Icons.sync;
    }
  }

  String _getDetailMessage(ConflictInfo conflict) {
    final strategy = conflict.resolutionStrategy;
    switch (strategy) {
      case 'trust_sdk':
        return 'Updating database with latest purchase...';
      case 'trust_database':
        return 'Your access is preserved during grace period.';
      case 'trigger_webhook_sync':
        return 'Synchronizing subscription details...';
      default:
        return 'Resolving...';
    }
  }
}
