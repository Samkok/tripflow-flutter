import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/email_history_service.dart';
import '../services/email_otp_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/otp_entry_sheet.dart';
import '../widgets/rotating_globe_background.dart';

/// Moves the account to a new email address. The new address must prove
/// itself with a 6-digit code before the server swaps anything, so a typo
/// can never lock the user out — and the current password is required
/// first, so a stolen unlocked phone can't quietly re-key the account.
class ChangeEmailScreen extends ConsumerStatefulWidget {
  const ChangeEmailScreen({super.key});

  @override
  ConsumerState<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends ConsumerState<ChangeEmailScreen> {
  final _passwordController = TextEditingController();
  final _newEmailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;
  bool _obscure = true;
  String? _passwordError;
  String? _emailError;

  int _attempts = 0;
  static const int _maxAttempts = 5;

  @override
  void dispose() {
    _passwordController.dispose();
    _newEmailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_attempts >= _maxAttempts) return;

    final user = ref.read(currentUserProvider);
    final currentEmail = user?.email;
    if (currentEmail == null) return;
    final newEmail = _newEmailController.text.trim().toLowerCase();

    setState(() {
      _loading = true;
      _passwordError = null;
      _emailError = null;
    });

    // 1. Prove it's really the account holder asking.
    try {
      await SupabaseService.instance.client.auth.signInWithPassword(
        email: currentEmail,
        password: _passwordController.text,
      );
    } on AuthException {
      _attempts++;
      setState(() {
        _loading = false;
        _passwordError = _attempts >= _maxAttempts
            ? 'Too many failed attempts. Please try again later.'
            : 'Current password is incorrect.';
        _passwordController.clear();
      });
      return;
    } catch (_) {
      setState(() {
        _loading = false;
        _passwordError = 'Something went wrong. Please try again.';
      });
      return;
    }

    // 2. Mail the code to the NEW address.
    final status = await EmailOtpService.sendCode(
      purpose: 'email_change',
      newEmail: newEmail,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    switch (status) {
      case OtpSendStatus.sent:
      case OtpSendStatus.cooldown: // a live code already exists — enter it
        final ok = await showOtpEntrySheet(
          context,
          mode: OtpSheetMode.changeEmail,
          email: newEmail,
          sendOnOpen: false,
        );
        if (ok == true && mounted) {
          // Session was refreshed by the sheet; keep the login helpers in
          // step with the new identity.
          await AuthService.saveRememberMe(true, newEmail);
          await EmailHistoryService.instance.remember(newEmail);
          if (!mounted) return;
          AppToast.success(context, 'Email updated to $newEmail');
          Navigator.of(context).pop();
        }
      case OtpSendStatus.emailTaken:
        setState(
            () => _emailError = 'That email already has a VoyZa account.');
      case OtpSendStatus.sameEmail:
        setState(
            () => _emailError = "That's already this account's email.");
      case OtpSendStatus.invalidEmail:
        setState(() => _emailError = 'Enter a valid email address.');
      case OtpSendStatus.rateLimited:
        AppToast.error(
            context, 'Too many codes requested. Try again in about an hour.');
      case OtpSendStatus.failed:
        AppToast.error(context, "Couldn't send the code. Try again shortly.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentEmail = ref.watch(currentUserProvider)?.email ?? '';
    final blocked = _attempts >= _maxAttempts;

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Change Email'),
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.alternate_email_rounded,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Move this account to a new email',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "We'll send a 6-digit code to the new address — the "
                      'switch only happens after you enter it.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      cursorOpacityAnimates: false,
                      initialValue: currentEmail,
                      enabled: false,
                      decoration: const InputDecoration(
                        labelText: 'Current email',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      cursorOpacityAnimates: false,
                      controller: _passwordController,
                      obscureText: _obscure,
                      enabled: !blocked,
                      decoration: InputDecoration(
                        labelText: 'Current password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: _passwordError,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter your current password'
                          : null,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      cursorOpacityAnimates: false,
                      controller: _newEmailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enableSuggestions: false,
                      enabled: !blocked,
                      decoration: InputDecoration(
                        labelText: 'New email',
                        prefixIcon: const Icon(Icons.forward_to_inbox_rounded),
                        errorText: _emailError,
                      ),
                      onChanged: (_) {
                        if (_emailError != null) {
                          setState(() => _emailError = null);
                        }
                      },
                      validator: (v) {
                        final s = (v ?? '').trim();
                        if (s.isEmpty || !s.contains('@')) {
                          return 'Enter a valid email';
                        }
                        if (s.toLowerCase() == currentEmail.toLowerCase()) {
                          return "That's already this account's email";
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),
                    ElevatedButton(
                      onPressed: (blocked || _loading) ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            )
                          : const Text('Send verification code'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
