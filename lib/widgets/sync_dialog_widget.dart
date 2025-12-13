import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/sync_provider.dart';
import '../providers/anonymous_locations_provider.dart';
import '../providers/location_provider.dart';
import '../services/storage_service.dart';

/// Modal dialog shown to anonymous users when they log in
class SyncAnonymousLocationsDialog extends ConsumerStatefulWidget {
  final String userId;
  final VoidCallback onSyncComplete;

  const SyncAnonymousLocationsDialog({
    Key? key,
    required this.userId,
    required this.onSyncComplete,
  }) : super(key: key);

  @override
  ConsumerState<SyncAnonymousLocationsDialog> createState() =>
      _SyncAnonymousLocationsDialogState();
}

class _SyncAnonymousLocationsDialogState
    extends ConsumerState<SyncAnonymousLocationsDialog> {
  @override
  Widget build(BuildContext context) {
    final isSyncing = ref.watch(isSyncingProvider);
    final syncError = ref.watch(syncErrorProvider);

    return AlertDialog(
      title: const Text('Sync Local Locations?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'You have offline locations stored locally. Would you like to sync them with your account?',
          ),
          const SizedBox(height: 16),
          if (syncError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Error: $syncError',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (isSyncing)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isSyncing
              ? null
              : () async {
                  // Discard anonymous locations
                  ref.read(userSyncChoiceProvider.notifier).state = false;
                  ref.read(syncDecisionProvider.notifier).state = true;
                  Navigator.of(context).pop();
                  widget.onSyncComplete();
                },
          child: const Text('No, Discard'),
        ),
        ElevatedButton(
          onPressed: isSyncing ? null : () => _performSync(context),
          child: const Text('Yes, Sync'),
        ),
      ],
    );
  }

  Future<void> _performSync(BuildContext context) async {
    ref.read(isSyncingProvider.notifier).state = true;
    ref.read(syncErrorProvider.notifier).state = null;

    try {
      // Get anonymous locations
      final anonLocations =
          await ref.read(anonymousLocationsProvider.future);

      if (anonLocations.isEmpty) {
        // No locations to sync
        ref.read(userSyncChoiceProvider.notifier).state = true;
        ref.read(syncDecisionProvider.notifier).state = true;
        if (mounted) {
          Navigator.of(context).pop();
          widget.onSyncComplete();
        }
        return;
      }

      // Get repository and sync
      final repository = ref.read(locationRepositoryProvider);
      final remoteLocations =
          await repository.getLocationsByUserId(widget.userId);

      final result = await repository.syncLocalLocations(
        localLocations: anonLocations,
        remoteLocations: remoteLocations,
      );

      if (!result.isSuccess) {
        ref.read(syncErrorProvider.notifier).state =
            'Failed to sync some locations. ${result.errors.join(", ")}';
        return;
      }

      // Clear synced locations from Hive
      for (final loc in anonLocations) {
        await StorageService.deleteLocationFromHive(loc.id);
      }

      ref.read(userSyncChoiceProvider.notifier).state = true;
      ref.read(syncDecisionProvider.notifier).state = true;

      if (mounted) {
        Navigator.of(context).pop();
        widget.onSyncComplete();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Synced ${result.uploadedCount} location(s). Skipped ${result.skippedCount} duplicate(s).',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ref.read(syncErrorProvider.notifier).state =
          'Sync failed. Please try again.';
    } finally {
      ref.read(isSyncingProvider.notifier).state = false;
    }
  }
}

/// Widget to show sync dialog if needed on login
class LoginSyncListener extends ConsumerWidget {
  final Widget child;

  const LoginSyncListener({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Listen for auth state changes and trigger sync if needed
    ref.listen<AsyncValue<dynamic>>(authStateProvider, (prev, next) async {
      next.whenData((authState) async {
        final userId = authState?.session?.user.id;
        if (userId == null) return;

        // Check if we've already shown the modal this session
        final syncDecision = ref.read(syncDecisionProvider);
        if (syncDecision != null) return; // Already decided

        // Check if there are anonymous locations
        final anonLocations =
            await ref.read(anonymousLocationsProvider.future);
        if (anonLocations.isNotEmpty && context.mounted) {
          // Show sync dialog
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => SyncAnonymousLocationsDialog(
              userId: userId,
              onSyncComplete: () {},
            ),
          );
        }
      });
    });

    return child;
  }
}
