import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/otp_entry_sheet.dart';
import 'signup_screen.dart';

/// Password reset by 6-digit code: the recovery email carries a
/// {{ .Token }} code the user types here (auth.verifyOTP type recovery
/// signs the device in and fires passwordRecovery — main.dart pushes
/// ResetPasswordScreen). The email is code-only — no reset link.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _emailSent = false;

  /// True after the server said no account uses the typed email — shows
  /// the "doesn't exist" card with a sign-up path instead of pretending a
  /// reset email went out. Cleared as soon as the address is edited.
  bool _emailNotFound = false;

  Future<void> _sendResetEmail() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _emailNotFound = false;
    });
    try {
      final email = _emailController.text.trim();
      // Only mail accounts that exist — for everyone else the truthful
      // answer is "no account", not a reset email that never comes.
      // (emailExists fails OPEN on network errors, so a real user is
      // never blocked from their reset.)
      final exists = await ref.read(authServiceProvider).emailExists(email);
      if (!exists) {
        if (mounted) setState(() => _emailNotFound = true);
        return;
      }
      await ref.read(authServiceProvider).sendPasswordResetEmail(email);
      if (mounted) {
        setState(() => _emailSent = true);
        // Straight into code entry — the email is already on its way.
        await _openCodeSheet();
      }
    } on AuthException catch (e) {
      if (mounted) {
        AppToast.error(context, e.message);
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Unexpected error occurred');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// On success the sheet's verifyOTP fires passwordRecovery and main.dart
  /// pushes ResetPasswordScreen on top — nothing to do here. A dismissed
  /// sheet leaves the "Enter code" button below to reopen it.
  Future<void> _openCodeSheet() async {
    await showOtpEntrySheet(
      context,
      mode: OtpSheetMode.recovery,
      email: _emailController.text.trim(),
      sendOnOpen: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_outlined),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.lock_reset_outlined,
                    size: 80,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Forgot Password?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Enter your email and we'll send a 6-digit reset code",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    enabled: !_emailSent,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    onChanged: (_) {
                      if (_emailNotFound) {
                        setState(() => _emailNotFound = false);
                      }
                    },
                    validator: (val) {
                      if (val == null || val.isEmpty || !val.contains('@')) {
                        return 'Please enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  if (_emailNotFound) ...[
                    Card(
                      color: theme.colorScheme.error.withValues(alpha: 0.08),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color:
                              theme.colorScheme.error.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(Icons.person_off_outlined,
                                    color: theme.colorScheme.error),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'No VoyZa account uses this email. '
                                    'Check for typos — or create an '
                                    'account instead.',
                                    style:
                                        theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(
                                      builder: (_) => const SignupScreen()),
                                );
                              },
                              child: const Text(
                                'Create an account',
                                style:
                                    TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_emailSent) ...[
                    Card(
                      color: Colors.green.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Colors.green.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_outline,
                                color: Colors.green),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'We emailed you a 6-digit code — enter it '
                                'here to set a new password.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: Colors.green[700],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _openCodeSheet,
                      child: const Text('Enter code'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back to Sign In'),
                    ),
                  ] else ...[
                    ElevatedButton(
                      onPressed: _isLoading ? null : _sendResetEmail,
                      child: _isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            )
                          : const Text('Send Reset Code'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }
}
