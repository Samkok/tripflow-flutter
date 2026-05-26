import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyza/screens/forgot_password_screen.dart';
import 'package:voyza/screens/terms_screen.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/save_password_prompt.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _agreedToTerms = false;
  // Visibility state moved into the per-field [_NewPasswordField] widgets
  // below so tapping the eye toggle only rebuilds that one field instead
  // of the entire SignupScreen / AutofillGroup — the rebuild cascade
  // was contributing to focus lag.

  /// Builds a 19-character password in the same shape as iOS Suggested
  /// Strong Password (`Xxxx-Xxxx-Xxxx-Xxxx`). Uses [Random.secure] so
  /// the entropy actually matters (~76 bits at this length). Each
  /// group is guaranteed to contain at least one of upper / lower /
  /// digit so it satisfies typical "must contain a number and a
  /// letter" server-side rules without an extra retry loop.
  String _generateStrongPassword() {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // skip I, O for legibility
    const lower = 'abcdefghijkmnopqrstuvwxyz'; // skip l
    const digits = '23456789'; // skip 0, 1
    final all = '$upper$lower$digits';
    final rng = Random.secure();

    String pickFrom(String s) => s[rng.nextInt(s.length)];

    String group() {
      // Guarantee one of each class so the generated value never
      // fails a "needs upper/lower/digit" check, then fill to 4 chars
      // from the combined pool and shuffle.
      final chars = <String>[
        pickFrom(upper),
        pickFrom(lower),
        pickFrom(digits),
        pickFrom(all),
      ]..shuffle(rng);
      return chars.join();
    }

    return '${group()}-${group()}-${group()}-${group()}';
  }

  /// Generates a strong password, drops it into both fields, and
  /// flashes a quick toast so the user knows what just happened.
  /// Sidesteps the iOS Strong-Password QuickType bar entirely — that
  /// pipeline is what's slow on focus, and not all platforms / users
  /// have iCloud Keychain configured anyway.
  void _useSuggestedStrongPassword() {
    final pwd = _generateStrongPassword();
    _passwordController.text = pwd;
    _confirmPasswordController.text = pwd;
    AppToast.success(context, 'Strong password generated and filled');
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      await ref.read(authServiceProvider).signUp(
            _emailController.text,
            _passwordController.text,
          );
      if (mounted) {
        // Ask the user (once per email) whether to save the credential
        // to the device's password manager. Same dialog + per-email
        // tracking the sign-in screen uses, so a brand-new account
        // gets the prompt here and a subsequent sign-in with the
        // same address won't re-ask.
        //
        // Must happen BEFORE we pop — the helper calls
        // finishAutofillContext which needs the screen's text fields
        // still mounted to commit their values into the autofill
        // context.
        await promptSavePasswordIfNeeded(
            context, _emailController.text.trim());
        if (!mounted) return;

        AppToast.success(
            context, 'Success! Please check your email to verify.');
        // Pop back to the login screen after successful sign-up
        if (Navigator.canPop(context)) {
          Navigator.of(context).pop();
        }
      }
    } on EmailAlreadyRegisteredException catch (e) {
      if (mounted) {
        await _showEmailAlreadyExistsDialog(e.email);
      }
    } on AuthException catch (e) {
      if (mounted) {
        // Supabase sometimes does surface a duplicate-email AuthException
        // (depends on project config: "Confirm email" off vs on). Catch
        // the common wording and route through the same dialog so the
        // user sees consistent messaging regardless of project setting.
        final msg = e.message.toLowerCase();
        final isDuplicate = msg.contains('already registered') ||
            msg.contains('already exists') ||
            msg.contains('user already');
        if (isDuplicate) {
          await _showEmailAlreadyExistsDialog(_emailController.text.trim());
        } else {
          AppToast.error(context, e.message);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Unexpected error occurred');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Shown when sign-up is rejected because [email] already belongs to
  /// an existing account. Offers the password-reset flow as the natural
  /// next step (vs. just dumping the user back on the form with a toast
  /// they may not connect to "you already have an account").
  Future<void> _showEmailAlreadyExistsDialog(String email) async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Account already exists'),
        content: Text(
          'An account is already registered with $email.\n\n'
          'If you forgot your password, you can reset it and sign in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset password'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (shouldReset == true) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // An AppBar is useful on secondary screens for the back button
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24.0, 0, 24.0, 24.0),
          child: Form(
            key: _formKey,
            // AutofillGroup binds the three fields together so the platform
            // autofill service treats them as one credential. Submitting
            // via TextInput.finishAutofillContext (in _signUp) then shows
            // the OS save prompt for the email + new-password pair, and
            // on iOS the Suggested Strong Password fills BOTH password
            // fields simultaneously because they share the same
            // AutofillHints.newPassword tag inside the group.
            child: AutofillGroup(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                Text(
                  'Create Your Account',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Start planning your next adventure',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 40),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  // username + email is the order iOS's Strong-Password
                  // pairing heuristic prefers — it tells the platform
                  // "this is the login identifier; the newPassword
                  // field below pairs with me". email alone sometimes
                  // makes iOS treat the form as sign-in instead of
                  // sign-up and skip the Strong Password offer.
                  autofillHints: const [
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (val) {
                    if (val == null || val.isEmpty || !val.contains('@')) {
                      return 'Please enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                _NewPasswordField(
                  controller: _passwordController,
                  label: 'Password',
                  textInputAction: TextInputAction.next,
                  validator: (val) => (val?.length ?? 0) < 6
                      ? 'Password must be at least 6 characters'
                      : null,
                ),
                // In-app strong-password generator. Independent of iOS
                // Suggested Strong Password — which is slow on focus
                // because the system has to negotiate with the
                // QuickType bar / iCloud Keychain before the keyboard
                // is even usable, and doesn't exist at all on Android.
                // Tapping this is instant: generate, fill both fields,
                // done.
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _useSuggestedStrongPassword,
                    icon: const Icon(Icons.password_rounded, size: 18),
                    label: const Text('Suggest strong password'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _NewPasswordField(
                  controller: _confirmPasswordController,
                  label: 'Confirm Password',
                  textInputAction: TextInputAction.done,
                  validator: (val) => val != _passwordController.text
                      ? 'Passwords do not match'
                      : null,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Checkbox(
                      value: _agreedToTerms,
                      onChanged: (value) {
                        setState(() {
                          _agreedToTerms = value ?? false;
                        });
                      },
                    ),
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('I agree to the '),
                          GestureDetector(
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const TermsScreen())),
                            child: Text(
                              'Terms & Conditions',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: (_isLoading || !_agreedToTerms) ? null : _signUp,
                  child: _isLoading
                      ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 3))
                      : const Text('Sign Up'),
                ),
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
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
}

/// Password field for the SIGN-UP flow. Owns its own visibility state so
/// tapping the eye toggle only rebuilds this field — previously the
/// toggle's setState lived on the SignupScreen and rebuilt the entire
/// AutofillGroup, which made each focus + toggle feel sluggish.
///
/// On the keyboard config: `obscureText: true` + `AutofillHints.newPassword`
/// is the canonical iOS Suggested-Strong-Password setup. We deliberately
/// do NOT set `keyboardType: TextInputType.visiblePassword` — that swap
/// makes iOS reset its keyboard / autofill pipeline on every focus
/// transition and is the source of the perceived "lag on focus" the
/// user reported. The default keyboard type plus secure entry still
/// triggers the Strong Password offer reliably.
class _NewPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final TextInputAction textInputAction;
  final FormFieldValidator<String> validator;

  const _NewPasswordField({
    required this.controller,
    required this.label,
    required this.textInputAction,
    required this.validator,
  });

  @override
  State<_NewPasswordField> createState() => _NewPasswordFieldState();
}

class _NewPasswordFieldState extends State<_NewPasswordField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: !_visible,
      autofillHints: const [AutofillHints.newPassword],
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: widget.textInputAction,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_visible
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined),
          onPressed: () => setState(() => _visible = !_visible),
        ),
      ),
    );
  }
}
