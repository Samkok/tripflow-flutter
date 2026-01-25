import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class DeleteAccountDialog extends ConsumerStatefulWidget {
  const DeleteAccountDialog({super.key});

  @override
  ConsumerState<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<DeleteAccountDialog> {
  int _currentStep = 0;
  bool _acknowledgedDataLoss = false;
  final _emailController = TextEditingController();
  String? _emailError;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_rounded, color: Colors.red),
          const SizedBox(width: 8),
          const Text('Delete Account'),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: _currentStep == 0 ? _buildStep1(theme) : _buildStep2(theme),
        ),
      ),
      actions: _buildActions(context),
    );
  }

  Widget _buildStep1(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'This will permanently delete:',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildDataItem(theme, Icons.location_on, 'All your saved locations'),
              _buildDataItem(theme, Icons.map, 'All your trips and itineraries'),
              _buildDataItem(theme, Icons.people, 'Your trip collaborations'),
              _buildDataItem(theme, Icons.person, 'Your profile and account data'),
              const SizedBox(height: 12),
              Text(
                '⚠️ This action cannot be undone. All data will be permanently lost.',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Checkbox confirmation
        InkWell(
          onTap: () {
            setState(() {
              _acknowledgedDataLoss = !_acknowledgedDataLoss;
            });
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: _acknowledgedDataLoss,
                  onChanged: (value) {
                    setState(() {
                      _acknowledgedDataLoss = value ?? false;
                    });
                  },
                  fillColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return Colors.red;
                    }
                    return null;
                  }),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'I understand that all my data will be permanently deleted and cannot be recovered.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDataItem(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildStep2(ThemeData theme) {
    final user = ref.watch(currentUserProvider);
    final userEmail = user?.email ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'To confirm deletion, please type your email address:',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            userEmail,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _emailController,
          decoration: InputDecoration(
            labelText: 'Enter your email',
            hintText: 'Type your email to confirm',
            errorText: _emailError,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.email),
          ),
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          onChanged: (_) {
            setState(() {
              if (_emailError != null) {
                _emailError = null;
              }
            });
          },
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_rounded, color: Colors.red, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'This is your last chance to cancel. After clicking "Delete Account", this action cannot be undone.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.red.shade700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_currentStep == 0) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _acknowledgedDataLoss
              ? () {
                  setState(() {
                    _currentStep = 1;
                  });
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: const Text('Continue'),
        ),
      ];
    } else {
      // Check if email matches
      final user = ref.read(currentUserProvider);
      final userEmail = user?.email ?? '';
      final enteredEmail = _emailController.text.trim();
      final emailMatches = enteredEmail.isNotEmpty &&
                           enteredEmail.toLowerCase() == userEmail.toLowerCase();

      return [
        TextButton(
          onPressed: () {
            setState(() {
              _currentStep = 0;
              _emailController.clear();
              _emailError = null;
            });
          },
          child: const Text('Back'),
        ),
        ElevatedButton(
          onPressed: emailMatches ? _verifyAndDelete : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: const Text('Delete Account'),
        ),
      ];
    }
  }

  void _verifyAndDelete() {
    final user = ref.read(currentUserProvider);
    final userEmail = user?.email ?? '';
    final enteredEmail = _emailController.text.trim();

    if (enteredEmail.isEmpty) {
      setState(() {
        _emailError = 'Please enter your email';
      });
      return;
    }

    if (enteredEmail.toLowerCase() != userEmail.toLowerCase()) {
      setState(() {
        _emailError = 'Email does not match';
      });
      return;
    }

    // Email verified - proceed with deletion
    Navigator.of(context).pop(true);
  }
}
