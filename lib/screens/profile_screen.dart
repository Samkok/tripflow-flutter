import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/models/user_profile.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/widgets/app_toast.dart';

// Provider to fetch and cache the current user's profile
final userProfileProvider =
    FutureProvider.autoDispose<UserProfile?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final repo = ref.read(userProfileRepositoryProvider);
  return repo.getUserProfile(user.id);
});

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isSaving = false;
  bool _hasChanges = false;
  UserProfile? _originalProfile;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  void _populateFields(UserProfile profile) {
    if (_originalProfile?.userId == profile.userId) return;
    _originalProfile = profile;
    _firstNameController.text = profile.firstName ?? '';
    _lastNameController.text = profile.lastName ?? '';
    _firstNameController.addListener(_onFieldChanged);
    _lastNameController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    final changed = _firstNameController.text.trim() !=
            (_originalProfile?.firstName ?? '') ||
        _lastNameController.text.trim() != (_originalProfile?.lastName ?? '');
    if (changed != _hasChanges) setState(() => _hasChanges = changed);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    setState(() => _isSaving = true);
    try {
      final repo = ref.read(userProfileRepositoryProvider);
      await repo.updateProfileField(user.id, {
        'first_name': _firstNameController.text.trim().isEmpty
            ? null
            : _firstNameController.text.trim(),
        'last_name': _lastNameController.text.trim().isEmpty
            ? null
            : _lastNameController.text.trim(),
      });

      ref.invalidate(userProfileProvider);

      if (mounted) {
        setState(() => _hasChanges = false);
        AppToast.success(context, 'Profile updated successfully');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Failed to update profile. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(userProfileProvider);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          if (_hasChanges)
            TextButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('Failed to load profile'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(userProfileProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (profile) {
          if (profile != null) _populateFields(profile);

          final initials = _initials(
            profile?.firstName,
            profile?.lastName,
            user?.email,
          );

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Avatar
              Center(
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: AppTheme.primaryColor,
                  child: Text(
                    initials,
                    style: const TextStyle(
                      fontSize: 32,
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Email (read-only)
              _InfoTile(
                icon: Icons.email_outlined,
                label: 'Email',
                value: user?.email ?? '—',
                note: 'Email cannot be changed',
              ),
              const SizedBox(height: 24),

              // Editable fields
              Text(
                'Personal Details',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),

              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildField(
                      controller: _firstNameController,
                      label: 'First Name',
                      icon: Icons.person_outline,
                    ),
                    const SizedBox(height: 16),
                    _buildField(
                      controller: _lastNameController,
                      label: 'Last Name',
                      icon: Icons.person_outline,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // Save button (also in app bar, but visible here on mobile)
              if (_hasChanges)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Save Changes',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextFormField(
      controller: controller,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  String _initials(String? first, String? last, String? email) {
    if ((first ?? '').isNotEmpty && (last ?? '').isNotEmpty) {
      return '${first![0]}${last![0]}'.toUpperCase();
    }
    if ((first ?? '').isNotEmpty) return first![0].toUpperCase();
    if ((last ?? '').isNotEmpty) return last![0].toUpperCase();
    return (email ?? 'U')[0].toUpperCase();
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? note;

  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.5),
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    note!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.4),
                          fontStyle: FontStyle.italic,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
