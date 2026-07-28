import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/trip_collaborator_provider.dart';
import 'analytics_service.dart';

/// What happened to one add-a-buddy attempt.
enum BuddyAddStatus {
  /// Existing VoyZa user — attached to the trip now.
  added,

  /// Not a user yet — pending invite created (auto-joins at signup) and the
  /// share sheet was offered.
  invited,

  /// The user backed out of the invite dialog.
  cancelled,

  /// Something failed; [BuddyAddResult.error] says what.
  error,
}

class BuddyAddResult {
  final BuddyAddStatus status;
  final String? error;
  const BuddyAddResult(this.status, [this.error]);
}

/// THE add-a-trip-buddy flow — one function shared by the Collaborators
/// sheet and the New Trip wizard so the two buttons can never drift apart:
/// validate → existing users join immediately → unknown emails get the
/// "not on VoyZa yet" dialog, a pending invite (auto-join at signup), and
/// the referral share sheet.
class TripBuddyService {
  TripBuddyService._();

  static final _emailPattern = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');

  /// The one email format check every buddy surface uses (sheet + wizard).
  static bool isValidEmail(String email) =>
      _emailPattern.hasMatch(email.trim().toLowerCase());

  /// Adds [email] to [tripId]. When [inviteWithoutAsking] is true a
  /// non-user email skips the consent dialog (the caller already asked —
  /// the wizard's buddy step collects consent before the trip exists).
  static Future<BuddyAddResult> addBuddy(
    BuildContext context,
    WidgetRef ref, {
    required String tripId,
    required String tripName,
    required String email,
    String permission = 'write',
    bool inviteWithoutAsking = false,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (!_emailPattern.hasMatch(normalized)) {
      return const BuddyAddResult(
          BuddyAddStatus.error, 'Please enter a valid email address');
    }

    try {
      return await _addBuddyInner(
        context,
        ref,
        tripId: tripId,
        tripName: tripName,
        email: normalized,
        permission: permission,
        inviteWithoutAsking: inviteWithoutAsking,
      );
    } catch (e) {
      debugPrint('TripBuddyService.addBuddy: $e');
      return const BuddyAddResult(BuddyAddStatus.error,
          'Couldn\'t reach the server — check your connection and try again.');
    }
  }

  static Future<BuddyAddResult> _addBuddyInner(
    BuildContext context,
    WidgetRef ref, {
    required String tripId,
    required String tripName,
    required String email,
    required String permission,
    required bool inviteWithoutAsking,
  }) async {
    final normalized = email;
    final isOwner = await ref.read(isTripOwnerProvider(tripId).future);
    if (!isOwner) {
      return const BuddyAddResult(BuddyAddStatus.error,
          'Only the trip owner can invite travel buddies.');
    }

    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final result = await repository.addCollaborator(
      tripId: tripId,
      email: normalized,
      permission: permission,
    );

    if (result.success) {
      ref.invalidate(tripCollaboratorsProvider(tripId));
      ref.invalidate(isTripOwnerProvider(tripId));
      ref.invalidate(hasWriteAccessProvider(tripId));
      ref.invalidate(userTripPermissionProvider(tripId));
      return const BuddyAddResult(BuddyAddStatus.added);
    }

    if (!result.needsInvite) {
      return BuddyAddResult(
          BuddyAddStatus.error, result.error ?? 'Could not add them.');
    }

    // Not a user yet — referral invite path.
    if (!inviteWithoutAsking) {
      if (!context.mounted) {
        return const BuddyAddResult(BuddyAddStatus.cancelled);
      }
      final confirmed = await showInviteBuddyDialog(
        context,
        email: normalized,
        tripName: tripName,
      );
      if (confirmed != true) {
        return const BuddyAddResult(BuddyAddStatus.cancelled);
      }
    }

    final code = await repository.createPendingInvite(
      tripId: tripId,
      email: normalized,
      permission: permission,
    );
    if (code == null) {
      return const BuddyAddResult(BuddyAddStatus.error,
          'Couldn\'t create the invite. Please try again.');
    }
    AnalyticsService.instance.referralPromptShown('collab_invite');
    await SharePlus.instance.share(ShareParams(
      text: 'Join me on VoyZa to plan "$tripName" together — '
          'and we\'ll both get a free month of Pro. Use my code $code when '
          'you sign up: https://voyza.xtremon.com/r/$code',
      subject: 'Plan "$tripName" with me on VoyZa',
    ));
    return const BuddyAddResult(BuddyAddStatus.invited);
  }

  /// Fast existence probe for pre-creation surfaces (the wizard checks at
  /// typing time, before any trip exists).
  static Future<bool> emailHasAccount(WidgetRef ref, String email) async {
    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final userId =
        await repository.getUserIdByEmail(email.trim().toLowerCase());
    return userId != null;
  }
}

/// The one "they're not on VoyZa yet" consent dialog, shared verbatim by
/// the Collaborators sheet and the wizard's buddy step.
Future<bool?> showInviteBuddyDialog(
  BuildContext context, {
  required String email,
  required String tripName,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('They\'re not on VoyZa yet'),
        content: Text(
          '$email doesn\'t have an account. Invite them to plan '
          '"$tripName" with you — you\'ll both get a free month of '
          'Pro, and they\'ll join this trip automatically when they sign up.',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.card_giftcard_rounded, size: 18),
            label: const Text('Send invite'),
          ),
        ],
      );
    },
  );
}
