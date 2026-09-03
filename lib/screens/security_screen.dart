import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/email_verified_provider.dart';
import 'package:voyza/services/supabase_service.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/otp_entry_sheet.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  // Step 1 — verify current password
  final _currentPasswordController = TextEditingController();

  // Step 2 — new password
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  final _step1Key = GlobalKey<FormState>();
  final _step2Key = GlobalKey<FormState>();

  bool _step1Loading = false;
  bool _step2Loading = false;
  bool _step1Obscure = true;
  bool _newObscure = true;
  bool _confirmObscure = true;

  /// null  = not verified yet
  /// true  = current password was correct
  bool? _verified;
  String? _currentPasswordError;

  // Simple rate limiting: max 5 attempts
  int _attempts = 0;
  static const int _maxAttempts = 5;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ─── Step 1: verify current password by re-authenticating ───────────────

  Future<void> _verifyCurrentPassword() async {
    if (!_step1Key.currentState!.validate()) return;
    if (_attempts >= _maxAttempts) return;

    setState(() {
      _step1Loading = true;
      _currentPasswordError = null;
    });

    final user = ref.read(currentUserProvider);
    final email = user?.email;
    if (email == null) return;

    try {
      // Re-authenticate to verify the current password
      await SupabaseService.instance.client.auth.signInWithPassword(
        email: email,
        password: _currentPasswordController.text,
      );

      // Success
      setState(() {
        _verified = true;
        _step1Loading = false;
      });
    } on AuthException catch (e) {
      _attempts++;
      setState(() {
        _step1Loading = false;
        _currentPasswordError = _attempts >= _maxAttempts
            ? 'Too many failed attempts. Please try again later.'
            : _friendlyAuthError(e);
        _currentPasswordController.clear();
      });
    } catch (_) {
      _attempts++;
      setState(() {
        _step1Loading = false;
        _currentPasswordError = 'Something went wrong. Please try again.';
        _currentPasswordController.clear();
      });
    }
  }

  // ─── Step 2: set new password ────────────────────────────────────────────

  Future<void> _changePassword() async {
    if (!_step2Key.currentState!.validate()) return;

    setState(() => _step2Loading = true);

    try {
      await SupabaseService.instance.client.auth.updateUser(
        UserAttributes(password: _newPasswordController.text),
      );

      if (!mounted) return;

      // Ask whether to sign out other devices
      final signOutOthers = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.devices_rounded, size: 22),
              SizedBox(width: 10),
              Text('Sign out other devices?'),
            ],
          ),
          content: const Text(
            'Would you like to sign out from all other devices logged into your account?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No, keep them signed in'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Yes, sign them out'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      if (signOutOthers == true) {
        await SupabaseService.instance.client.auth
            .signOut(scope: SignOutScope.others);
      }

      if (!mounted) return;

      AppToast.success(
        context,
        signOutOthers == true
            ? 'Password changed and other devices signed out.'
            : 'Password changed successfully.',
      );
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) {
        AppToast.error(context, _friendlyAuthError(e));
      }
    } catch (_) {
      if (mounted) {
        AppToast.error(context, 'Failed to change password. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _step2Loading = false);
    }
  }

  String _friendlyAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid') ||
        msg.contains('wrong') ||
        msg.contains('incorrect')) {
      return 'Current password is incorrect.';
    }
    if (msg.contains('weak') || msg.contains('short')) {
      return 'New password is too weak. Use at least 8 characters.';
    }
    return 'Incorrect password. Please try again.';
  }

  // ─── Password strength ───────────────────────────────────────────────────

  double _passwordStrength(String password) {
    if (password.isEmpty) return 0;
    double score = 0;
    if (password.length >= 8) score += 0.25;
    if (password.length >= 12) score += 0.15;
    if (password.contains(RegExp(r'[A-Z]'))) score += 0.2;
    if (password.contains(RegExp(r'[0-9]'))) score += 0.2;
    if (password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'))) score += 0.2;
    return score.clamp(0, 1);
  }

  Color _strengthColor(double strength) {
    if (strength < 0.4) return Colors.red;
    if (strength < 0.7) return Colors.orange;
    return Colors.green;
  }

  String _strengthLabel(double strength) {
    if (strength < 0.4) return 'Weak';
    if (strength < 0.7) return 'Fair';
    return 'Strong';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Ambient rotating globe behind the page (app-wide treatment).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Security'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Unverified email = unrecoverable account if the password
              // is forgotten. Not dismissible here — this screen is
              // exactly where that risk lives.
              const _UnverifiedResetWarning(),

              // Section header
              const _SectionHeader(
                icon: Icons.lock_outline_rounded,
                title: 'Change Password',
                subtitle: 'Update your account password',
              ),
              const SizedBox(height: 20),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.05, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: _verified == true ? _buildStep2() : _buildStep1(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Step 1 widget ───────────────────────────────────────────────────────

  Widget _buildStep1() {
    final blocked = _attempts >= _maxAttempts;

    return Form(
      key: _step1Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StepIndicator(step: 1, label: 'Verify your identity'),
          const SizedBox(height: 16),
          Text(
            'Enter your current password to continue.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
          ),
          const SizedBox(height: 20),
          TextFormField(
            cursorOpacityAnimates: false,
            controller: _currentPasswordController,
            obscureText: _step1Obscure,
            enabled: !blocked,
            decoration: InputDecoration(
              labelText: 'Current Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _step1Obscure ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _step1Obscure = !_step1Obscure),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              errorText: null, // handled manually below
            ),
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Enter your current password' : null,
            onFieldSubmitted: (_) => blocked ? null : _verifyCurrentPassword(),
          ),

          // Manual error display (keeps red text even after rebuild)
          if (_currentPasswordError != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.error_outline, size: 16, color: Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _currentPasswordError!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  blocked || _step1Loading ? null : _verifyCurrentPassword,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _step1Loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'Continue',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Step 2 widget ───────────────────────────────────────────────────────

  Widget _buildStep2() {
    final newPassword = _newPasswordController.text;
    final strength = _passwordStrength(newPassword);

    return Form(
      key: _step2Key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StepIndicator(step: 2, label: 'Set new password'),
          const SizedBox(height: 16),
          Text(
            'Choose a strong password you haven\'t used before.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
          ),
          const SizedBox(height: 20),

          // New password field
          StatefulBuilder(
            builder: (context, setLocal) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  cursorOpacityAnimates: false,
                  controller: _newPasswordController,
                  obscureText: _newObscure,
                  decoration: InputDecoration(
                    labelText: 'New Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _newObscure ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _newObscure = !_newObscure),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter a new password';
                    if (v.length < 8) return 'Use at least 8 characters';
                    return null;
                  },
                ),
                if (newPassword.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  // Strength bar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: strength,
                      minHeight: 6,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(
                        _strengthColor(strength),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        strength >= 0.7
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 14,
                        color: _strengthColor(strength),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Password strength: ${_strengthLabel(strength)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: _strengthColor(strength),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _PasswordRequirements(password: newPassword),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Confirm password field
          TextFormField(
            cursorOpacityAnimates: false,
            controller: _confirmPasswordController,
            obscureText: _confirmObscure,
            decoration: InputDecoration(
              labelText: 'Confirm New Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _confirmObscure ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _confirmObscure = !_confirmObscure),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Confirm your new password';
              if (v != _newPasswordController.text) {
                return 'Passwords do not match';
              }
              return null;
            },
          ),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'After changing your password, you\'ll be asked whether to sign out from all other devices.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.blue,
                        ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _step2Loading ? null : _changePassword,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _step2Loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'Change Password',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => setState(() {
                _verified = null;
                _currentPasswordError = null;
                _currentPasswordController.clear();
              }),
              child: const Text('Back'),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Supporting widgets ─────────────────────────────────────────────────────

/// Red warning shown while the account's email is unverified: the reset
/// code goes to an inbox the user hasn't proven they can open, so a
/// forgotten password could mean losing the account for good.
class _UnverifiedResetWarning extends ConsumerWidget {
  const _UnverifiedResetWarning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final verified = ref.watch(emailVerifiedProvider).valueOrNull;
    if (verified != false) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final red = theme.colorScheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: red.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_maybe_rounded, color: red, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your email is not verified',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: red,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Password reset codes go to this email. Until you verify you '
            'can receive them, a forgotten password means this account '
            "can't be recovered — and you could lose it for good.",
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: () async {
                final ok = await showOtpEntrySheet(
                  context,
                  mode: OtpSheetMode.verifyEmail,
                  sendOnOpen: true,
                );
                if (ok == true && context.mounted) {
                  AppToast.success(context, 'Email verified!');
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: red.withValues(alpha: 0.12),
                foregroundColor: red,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text(
                'Verify now',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon,
              color: Theme.of(context).colorScheme.primary, size: 24),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
                  ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  final int step;
  final String label;

  const _StepIndicator({required this.step, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: Text(
            '$step',
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _PasswordRequirements extends StatelessWidget {
  final String password;

  const _PasswordRequirements({required this.password});

  @override
  Widget build(BuildContext context) {
    final checks = [
      (password.length >= 8, 'At least 8 characters'),
      (password.contains(RegExp(r'[A-Z]')), 'One uppercase letter'),
      (password.contains(RegExp(r'[0-9]')), 'One number'),
      (
        password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]')),
        'One special character'
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: checks.map((c) {
        final met = c.$1;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            children: [
              Icon(
                met ? Icons.check_rounded : Icons.circle_outlined,
                size: 14,
                color: met
                    ? Colors.green
                    : Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.35),
              ),
              const SizedBox(width: 6),
              Text(
                c.$2,
                style: TextStyle(
                  fontSize: 12,
                  color: met
                      ? Colors.green
                      : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
