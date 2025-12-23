import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/trip_collaborator.dart';
import '../providers/trip_collaborator_provider.dart';

class CollaboratorsSheet extends ConsumerStatefulWidget {
  final String tripId;
  final String tripName;

  const CollaboratorsSheet({
    super.key,
    required this.tripId,
    required this.tripName,
  });

  @override
  ConsumerState<CollaboratorsSheet> createState() => _CollaboratorsSheetState();
}

class _CollaboratorsSheetState extends ConsumerState<CollaboratorsSheet> {
  final TextEditingController _emailController = TextEditingController();
  String _selectedPermission = 'read';
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _addCollaborator() async {
    // Only owner can add collaborators - check at function level
    final isOwner = await ref.read(isTripOwnerProvider(widget.tripId).future);
    if (!isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the trip owner can add team members.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final email = _emailController.text.trim().toLowerCase();

    if (email.isEmpty) {
      setState(() => _errorMessage = 'Please enter an email address');
      return;
    }

    // Basic email validation
    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      setState(() => _errorMessage = 'Please enter a valid email address');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final result = await repository.addCollaborator(
      tripId: widget.tripId,
      email: email,
      permission: _selectedPermission,
    );

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (result.success) {
      _emailController.clear();
      // Refresh all trip-related providers to ensure UI updates correctly
      ref.invalidate(tripCollaboratorsProvider(widget.tripId));
      ref.invalidate(isTripOwnerProvider(widget.tripId));
      ref.invalidate(hasWriteAccessProvider(widget.tripId));
      ref.invalidate(userTripPermissionProvider(widget.tripId));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added $email as collaborator'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      setState(() => _errorMessage = result.error);
    }
  }

  Future<void> _updatePermission(
      TripCollaborator collaborator, String newPermission) async {
    // Only owner can update permissions - check at function level
    final isOwner = await ref.read(isTripOwnerProvider(widget.tripId).future);
    if (!isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the trip owner can change permissions.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final success = await repository.updatePermission(
      collaboratorId: collaborator.id,
      permission: newPermission,
    );

    if (success) {
      // Refresh all trip-related providers
      ref.invalidate(tripCollaboratorsProvider(widget.tripId));
      ref.invalidate(isTripOwnerProvider(widget.tripId));
      ref.invalidate(hasWriteAccessProvider(widget.tripId));
      ref.invalidate(userTripPermissionProvider(widget.tripId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Updated ${collaborator.email} permission to $newPermission'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _removeCollaborator(TripCollaborator collaborator) async {
    // Only owner can remove collaborators - check at function level
    final isOwner = await ref.read(isTripOwnerProvider(widget.tripId).future);
    if (!isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only the trip owner can remove team members.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Show confirmation dialog
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Collaborator?'),
        content: Text(
          'Are you sure you want to remove ${collaborator.email} from this trip?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final repository = ref.read(tripCollaboratorRepositoryProvider);
    final success = await repository.removeCollaborator(collaborator.id);

    if (success) {
      // Refresh all trip-related providers
      ref.invalidate(tripCollaboratorsProvider(widget.tripId));
      ref.invalidate(isTripOwnerProvider(widget.tripId));
      ref.invalidate(hasWriteAccessProvider(widget.tripId));
      ref.invalidate(userTripPermissionProvider(widget.tripId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed ${collaborator.email} from trip'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final collaboratorsAsync = ref.watch(tripCollaboratorsProvider(widget.tripId));
    // Check if current user is the owner
    final isOwnerAsync = ref.watch(isTripOwnerProvider(widget.tripId));
    final isOwner = isOwnerAsync.asData?.value ?? false;

    // Get current user ID for comparison
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.group,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Team Members',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          Text(
                            widget.tripName,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              const Divider(),

              // Add collaborator form - ONLY visible to owner
              if (isOwner) ...[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add Team Member',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 12),

                      // Email input
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          hintText: 'Enter email address',
                          prefixIcon: const Icon(Icons.email_outlined),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: Theme.of(context).cardColor,
                          errorText: _errorMessage,
                        ),
                        onChanged: (_) {
                          if (_errorMessage != null) {
                            setState(() => _errorMessage = null);
                          }
                        },
                      ),
                      const SizedBox(height: 12),

                      // Permission selector
                      Row(
                        children: [
                          Expanded(
                            child: _buildPermissionOption(
                              'read',
                              'Read Only',
                              Icons.visibility,
                              'Can view locations',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildPermissionOption(
                              'write',
                              'Can Edit',
                              Icons.edit,
                              'Can add, edit, delete',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Add button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _addCollaborator,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.person_add),
                          label: Text(_isLoading ? 'Adding...' : 'Add Member'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
              ],

              // Collaborators list header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      isOwner ? 'Current Team Members' : 'Team Members',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const Spacer(),
                    collaboratorsAsync.when(
                      data: (collaborators) => Text(
                        '${collaborators.length} member${collaborators.length != 1 ? 's' : ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                            ),
                      ),
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),

              // Collaborators list
              Expanded(
                child: collaboratorsAsync.when(
                  data: (collaborators) {
                    if (collaborators.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.group_outlined,
                              size: 64,
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No team members yet',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isOwner
                                  ? 'Add members using the form above'
                                  : 'Only the owner can add team members',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                                  ),
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: collaborators.length,
                      separatorBuilder: (context, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final collaborator = collaborators[index];
                        return _buildCollaboratorCard(
                          collaborator,
                          isOwner: isOwner,
                          isCurrentUser: collaborator.userId == currentUserId,
                        );
                      },
                    );
                  },
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: Text('Error: $error'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPermissionOption(
    String value,
    String label,
    IconData icon,
    String description,
  ) {
    final isSelected = _selectedPermission == value;
    final color = value == 'write' ? Colors.orange : Colors.blue;

    return GestureDetector(
      onTap: () => setState(() => _selectedPermission = value),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Theme.of(context).dividerColor.withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? color : Theme.of(context).iconTheme.color,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? color : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 0.6),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollaboratorCard(
    TripCollaborator collaborator, {
    required bool isOwner,
    required bool isCurrentUser,
  }) {
    final isWrite = collaborator.permission == 'write';
    final permissionColor = isWrite ? Colors.orange : Colors.blue;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            child: Text(
              collaborator.email[0].toUpperCase(),
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Email and permission
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        collaborator.email,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isCurrentUser)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'You',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: permissionColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isWrite ? 'Can Edit' : 'Read Only',
                    style: TextStyle(
                      fontSize: 11,
                      color: permissionColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Actions - only visible to owner, and not for themselves
          if (isOwner && !isCurrentUser)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: isWrite ? 'read' : 'write',
                  child: Row(
                    children: [
                      Icon(
                        isWrite ? Icons.visibility : Icons.edit,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(isWrite ? 'Change to Read Only' : 'Change to Can Edit'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(Icons.person_remove, size: 18, color: Colors.red),
                      SizedBox(width: 12),
                      Text('Remove', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'remove') {
                  _removeCollaborator(collaborator);
                } else {
                  _updatePermission(collaborator, value);
                }
              },
            )
          else if (!isOwner)
            // Show permission badge for non-owners viewing the list
            const SizedBox(width: 48), // Placeholder for consistent spacing
        ],
      ),
    );
  }
}
