import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/trip_collaborator_provider.dart';
import 'analytics_service.dart';
import 'supabase_service.dart';

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

    // Can't attach directly — invite path. Either they have no account, or
    // they have one that hasn't verified its email (collaboration is gated
    // on verification server-side); the dialog and the closing message say
    // which, because "we'll email them a referral" is the wrong story for
    // someone who already signed up.
    final unverifiedAccount = result.existsUnverified;
    if (!inviteWithoutAsking) {
      if (!context.mounted) {
        return const BuddyAddResult(BuddyAddStatus.cancelled);
      }
      final confirmed = await showInviteBuddyDialog(
        context,
        email: normalized,
        tripName: tripName,
        unverifiedAccount: unverifiedAccount,
      );
      if (confirmed != true) {
        return const BuddyAddResult(BuddyAddStatus.cancelled);
      }
    }

    final invite = await repository.createPendingInvite(
      tripId: tripId,
      email: normalized,
      permission: permission,
    );
    final code = invite.code;
    if (code == null) {
      return BuddyAddResult(
        BuddyAddStatus.error,
        invite.inviterUnverified
            ? 'Verify your own email first — open Settings and tap "Verify '
                'now". We need to know your address is real before you can '
                'invite people to a trip.'
            : 'Couldn\'t create the invite. Please try again.',
      );
    }
    AnalyticsService.instance.referralPromptShown('collab_invite');

    // The invite email is sent automatically (server-side, with the code
    // and store links). The OS share sheet only appears as the FALLBACK
    // when the email couldn't be sent — the invite must reach them somehow.
    var emailed = false;
    try {
      final res = await SupabaseService.instance.client.functions
          .invoke('send-invite-email', body: {
        'trip_id': tripId,
        'email': normalized,
      });
      emailed = (res.data is Map) && (res.data as Map)['ok'] == true;
    } catch (e) {
      debugPrint('TripBuddyService: invite email failed: $e');
    }
    if (!emailed) {
      await SharePlus.instance.share(ShareParams(
        text: 'Join me on VoyZa to plan "$tripName" together — '
            'you\'ll start with a free month of Pro. Use my code $code when '
            'you sign up: https://voyza.xtremon.com/r/$code',
        subject: 'Plan "$tripName" with me on VoyZa',
      ));
    }
    if (unverifiedAccount) {
      // Kept short: this lands in a toast, and the dialog above already
      // gave the full "why verification is required" explanation.
      return BuddyAddResult(
          BuddyAddStatus.invited,
          '$normalized hasn\'t verified their email yet — they\'ll join '
              'this trip automatically once they do.');
    }
    return BuddyAddResult(
        BuddyAddStatus.invited,
        emailed
            ? 'Invite emailed to $normalized — they\'ll join the trip '
                'automatically when they sign up.'
            : null);
  }

  /// Fast probe for pre-creation surfaces (the wizard checks at typing
  /// time, before any trip exists). [addable] means a VERIFIED account we
  /// can attach straight away; [unverifiedAccount] means the address is
  /// taken by an account that still has to verify its email before it can
  /// collaborate — an invite, with the right wording.
  static Future<({bool addable, bool unverifiedAccount})> probeEmail(
      WidgetRef ref, String email) async {
    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final normalized = email.trim().toLowerCase();
    final userId = await repository.getUserIdByEmail(normalized);
    if (userId != null) {
      return (addable: true, unverifiedAccount: false);
    }
    return (
      addable: false,
      unverifiedAccount: await repository.emailExists(normalized),
    );
  }
}

/// The one invite-consent dialog, shared by the Collaborators sheet and the
/// wizard's buddy step. Two stories, because the reason the person can't be
/// added directly changes what's true:
///   • default — no VoyZa account: the referral pitch (free month, rewards).
///   • [unverifiedAccount] — they HAVE an account but haven't verified their
///     email, which collaboration requires. No free-month promise (they're
///     not a new signup), just the honest "they must verify first, then
///     they're added automatically".
Future<bool?> showInviteBuddyDialog(
  BuildContext context, {
  required String email,
  required String tripName,
  bool unverifiedAccount = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(unverifiedAccount
            ? 'Their email isn\'t verified yet'
            : 'They\'re not on VoyZa yet'),
        content: Text(
          unverifiedAccount
              ? '$email has a VoyZa account, but hasn\'t verified their email '
                  'address yet — VoyZa requires that before someone can join '
                  'a trip.\n\nWe\'ll send them an invite to "$tripName". The '
                  'moment they verify, they\'re added to this trip '
                  'automatically.'
              : '$email doesn\'t have an account. We\'ll email them an invite '
                  'to plan "$tripName" with you — they start with a free month '
                  'of Pro and join this trip automatically when they sign up '
                  '(and you\'ll earn rewards too).',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: Icon(
                unverifiedAccount
                    ? Icons.mark_email_unread_outlined
                    : Icons.card_giftcard_rounded,
                size: 18),
            label: const Text('Send invite'),
          ),
        ],
      );
    },
  );
}
