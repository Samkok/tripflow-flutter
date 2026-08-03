import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip_collaborator.dart';
import '../providers/trip_collaborator_provider.dart';
import 'app_toast.dart';
import 'collaborators_sheet.dart';
import 'package:voyza/core/theme.dart';

/// Collaborator display for a home-page trip card.
///
/// [canManage] = true (owned trips): a compact header ("Shared with N" + the
/// 2-people add button) plus a per-collaborator row with an inline
/// View/Edit permission toggle, so the owner can manage access without
/// opening the trip.
///
/// [canManage] = false (shared trips the user is a guest on): a read-only
/// overlapping avatar stack + count, no add button, no toggles.
class TripCollaboratorsRow extends ConsumerWidget {
  final String tripId;
  final String tripName;
  final bool canManage;

  const TripCollaboratorsRow({
    super.key,
    required this.tripId,
    required this.tripName,
    this.canManage = true,
  });

  static const _avatarSize = 28.0;
  static const _avatarStep = 19.0;
  static const _maxAvatars = 3;

  static const _palette = [
    Color(0xFF2E5BD0),
    Color(0xFF15BFB6),
    Color(0xFF7C4DFF),
    Color(0xFFF5793B),
    Color(0xFFE0568A),
    Color(0xFF1EA672),
  ];

  static Color colorFor(String email) =>
      _palette[email.hashCode.abs() % _palette.length];

  static String initialFor(String email) {
    final local = email.split('@').first.trim();
    return local.isEmpty ? '?' : local[0].toUpperCase();
  }

  static String countLabel(int n) =>
      n == 1 ? 'Shared with 1 person' : 'Shared with $n people';

  void _openSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Light barrier so the page stays visible behind the glass sheet.
      barrierColor: AppTheme.sheetBarrierColor(context),
      builder: (_) => CollaboratorsSheet(tripId: tripId, tripName: tripName),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final collaborators =
        ref.watch(tripCollaboratorsProvider(tripId)).asData?.value ?? const [];

    // Read-only mode (guest on a shared trip): just the avatar stack.
    if (!canManage) {
      if (collaborators.isEmpty) return const SizedBox.shrink();
      return Row(
        children: [
          _AvatarStack(collaborators: collaborators),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              countLabel(collaborators.length),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    // Manage mode (owner): header + per-collaborator toggle rows.
    final addButton = Tooltip(
      message: 'Invite travel buddies',
      child: Material(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _openSheet(context),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(Icons.group_add_outlined,
                size: 20, color: theme.colorScheme.primary),
          ),
        ),
      ),
    );

    if (collaborators.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Plan together — invite travel buddies',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          addButton,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                countLabel(collaborators.length),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            addButton,
          ],
        ),
        const SizedBox(height: 8),
        ...collaborators.map((c) => _CollaboratorManageTile(
              tripId: tripId,
              collaborator: c,
            )),
      ],
    );
  }
}

/// A managed collaborator row: avatar + email + View/Edit permission toggle.
class _CollaboratorManageTile extends ConsumerStatefulWidget {
  final String tripId;
  final TripCollaborator collaborator;

  const _CollaboratorManageTile({
    required this.tripId,
    required this.collaborator,
  });

  @override
  ConsumerState<_CollaboratorManageTile> createState() =>
      _CollaboratorManageTileState();
}

class _CollaboratorManageTileState
    extends ConsumerState<_CollaboratorManageTile> {
  late String _permission = widget.collaborator.permission;
  bool _busy = false;

  Future<void> _setPermission(String next) async {
    if (_busy || next == _permission) return;
    final previous = _permission;
    setState(() {
      _permission = next; // optimistic
      _busy = true;
    });
    final repo = ref.read(tripCollaboratorRepositoryProvider);
    final ok = await repo.updatePermission(
      collaboratorId: widget.collaborator.id,
      permission: next,
    );
    if (!mounted) return;
    if (ok) {
      // Keep the detail screen + gates in sync.
      ref.invalidate(tripCollaboratorsProvider(widget.tripId));
      ref.invalidate(hasWriteAccessProvider(widget.tripId));
      ref.invalidate(userTripPermissionProvider(widget.tripId));
      setState(() => _busy = false);
    } else {
      setState(() {
        _permission = previous; // revert
        _busy = false;
      });
      AppToast.error(context, 'Couldn\'t update permission. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = widget.collaborator.email;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: TripCollaboratorsRow.colorFor(email),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              TripCollaboratorsRow.initialFor(email),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              email,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _PermissionToggle(
            permission: _permission,
            busy: _busy,
            onChanged: _setPermission,
          ),
        ],
      ),
    );
  }
}

/// Compact two-segment [View | Edit] control.
class _PermissionToggle extends StatelessWidget {
  final String permission; // 'read' | 'write'
  final bool busy;
  final ValueChanged<String> onChanged;

  const _PermissionToggle({
    required this.permission,
    required this.busy,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget seg(String label, String value, IconData icon) {
      final active = permission == value;
      return InkWell(
        onTap: busy ? null : () => onChanged(value),
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? theme.colorScheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 13,
                  color: active
                      ? Colors.white
                      : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? Colors.white
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Opacity(
      opacity: busy ? 0.6 : 1,
      child: Container(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg('View', 'read', Icons.visibility_outlined),
            seg('Edit', 'write', Icons.edit_outlined),
          ],
        ),
      ),
    );
  }
}

class _AvatarStack extends StatelessWidget {
  final List<TripCollaborator> collaborators;

  const _AvatarStack({required this.collaborators});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible =
        collaborators.take(TripCollaboratorsRow._maxAvatars).toList();
    final overflow = collaborators.length - visible.length;
    final circleCount = visible.length + (overflow > 0 ? 1 : 0);
    final width = (circleCount - 1) * TripCollaboratorsRow._avatarStep +
        TripCollaboratorsRow._avatarSize;

    Widget circle(Widget child, Color bg, double left) => Positioned(
          left: left,
          child: Container(
            width: TripCollaboratorsRow._avatarSize,
            height: TripCollaboratorsRow._avatarSize,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: theme.cardColor, width: 2),
            ),
            alignment: Alignment.center,
            child: child,
          ),
        );

    final children = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      final email = visible[i].email;
      children.add(circle(
        Text(
          TripCollaboratorsRow.initialFor(email),
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
        ),
        TripCollaboratorsRow.colorFor(email),
        i * TripCollaboratorsRow._avatarStep,
      ));
    }
    if (overflow > 0) {
      children.add(circle(
        Text('+$overflow',
            style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
        theme.colorScheme.surfaceContainerHighest,
        visible.length * TripCollaboratorsRow._avatarStep,
      ));
    }

    return SizedBox(
      width: width,
      height: TripCollaboratorsRow._avatarSize,
      child: Stack(children: children),
    );
  }
}
