import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../providers/auth_provider.dart';
import '../providers/trip_collaborator_provider.dart';

/// "Planning with someone? Invite a travel buddy" — the trip page's quiet
/// replacement for the creation wizard's buddies step. Shown to the
/// signed-in owner of a trip with no collaborators and no pending invites,
/// until dismissed (remembered per trip).
class BuddyNudgeRow extends ConsumerStatefulWidget {
  const BuddyNudgeRow({
    super.key,
    required this.tripId,
    required this.ownerId,
    required this.onInvite,
  });

  final String tripId;
  final String ownerId;
  final VoidCallback onInvite;

  static String prefsKey(String tripId) => 'buddy_nudge_dismissed_$tripId';

  @override
  ConsumerState<BuddyNudgeRow> createState() => _BuddyNudgeRowState();
}

class _BuddyNudgeRowState extends ConsumerState<BuddyNudgeRow> {
  late bool _dismissed = SharedPrefsCache.maybeInstance
          ?.getBool(BuddyNudgeRow.prefsKey(widget.tripId)) ??
      false;

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    final key = BuddyNudgeRow.prefsKey(widget.tripId);
    final prefs =
        SharedPrefsCache.maybeInstance ?? await SharedPreferences.getInstance();
    await prefs.setBool(key, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final me = ref.watch(currentUserIdProvider);
    if (me == null || me != widget.ownerId) return const SizedBox.shrink();
    // Only once both answers are in and both are empty; loading or an
    // error shows nothing rather than a nudge that may be wrong.
    final collaborators =
        ref.watch(tripCollaboratorsProvider(widget.tripId)).valueOrNull;
    final invites =
        ref.watch(pendingInvitesProvider(widget.tripId)).valueOrNull;
    if (collaborators == null || invites == null) {
      return const SizedBox.shrink();
    }
    if (collaborators.isNotEmpty || invites.isNotEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onInvite,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.group_add_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Planning with someone? Invite a travel buddy',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
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
          ),
        ),
      ),
    );
  }
}
