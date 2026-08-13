import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/email_history_service.dart';
import '../services/referral_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/rotating_globe_background.dart';
import '../widgets/save_password_prompt.dart';
import 'login_screen.dart';

/// Upgrades an INSTANT (anonymous) account with an email + password — same
/// auth.uid, so trips, subscriptions, and progress keep their owner. On
/// submit, Supabase mails a confirmation link; the app keeps working while
/// it's pending, and main.dart's link handler runs the unlocks (profile
/// row, referral, invites) the moment the address confirms.
class LinkEmailScreen extends ConsumerStatefulWidget {
  const LinkEmailScreen({super.key});

  @override
  ConsumerState<LinkEmailScreen> createState() => _LinkEmailScreenState();
}

class _LinkEmailScreenState extends ConsumerState<LinkEmailScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _referralCodeController = TextEditingController();

  bool _isLoading = false;
  bool _obscure = true;
  bool _showReferralField = false;

  /// Non-null after a successful submit — flips the body to the
  /// "confirm your inbox" state for this address.
  String? _sentTo;
  DateTime? _resendAvailableAt;

  /// A code typed at instant-signup is already parked as the pending code —
  /// don't ask again.
  bool _hasPendingReferral = false;

  @override
  void initState() {
    super.initState();
    ReferralService.instance.pendingCode().then((code) {
      if (mounted && code != null) {
        setState(() => _hasPendingReferral = true);
      }
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _referralCodeController.dispose();
    super.dispose();
  }

  /// Same shape as the signup screen's generator (iOS Strong-Password
  /// style, guaranteed upper/lower/digit per group).
  String _generateStrongPassword() {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const digits = '23456789';
    const all = '$upper$lower$digits';
    final rng = Random.secure();
    String pickFrom(String s) => s[rng.nextInt(s.length)];
    String group() {
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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = _emailController.text.trim();
    setState(() => _isLoading = true);
    try {
      // A referral code entered here redeems automatically once the email
      // confirms (redemption requires a non-anonymous account).
      final code = _referralCodeController.text.trim();
      if (code.isNotEmpty) {
        await ReferralService.instance.savePendingCode(code);
      }

      await ref
          .read(authServiceProvider)
          .linkEmail(email, _passwordController.text);
      await AuthService.markPendingEmailLink();

      // Autofill niceties, mirrored from signup: offer to save the new
      // credential and remember the address for future auth screens.
      if (mounted) {
        await promptSavePasswordIfNeeded(context, email);
      }
      await EmailHistoryService.instance.remember(email);

      if (!mounted) return;
      setState(() {
        _sentTo = email;
        _resendAvailableAt = DateTime.now().add(const Duration(seconds: 60));
      });
    } on EmailAlreadyRegisteredException {
      if (mounted) await _showEmailExistsDialog(email);
    } on AuthException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    } catch (_) {
      if (mounted) {
        AppToast.error(context, 'Could not link your email. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// The address already belongs to another VoyZa account. Signing into it
  /// is possible, but it is a DIFFERENT account — this instant account's
  /// server data doesn't merge (documented v1 limitation), so say exactly
  /// that instead of letting the user discover it as "my trips vanished".
  Future<void> _showEmailExistsDialog(String email) async {
    final signIn = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Email already in use'),
        content: Text(
          '$email already has a VoyZa account.\n\n'
          'You can sign in to it instead — but that is a different account: '
          'trips created on this instant account stay here and won\'t move '
          'over. To keep everything in one place, use a different email.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Use another email'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign in to that account'),
          ),
        ],
      ),
    );
    if (signIn == true && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  Future<void> _resend() async {
    final email = _sentTo;
    if (email == null) return;
    final available = _resendAvailableAt;
    if (available != null && DateTime.now().isBefore(available)) return;
    try {
      await ref.read(authServiceProvider).resendLinkEmailConfirmation(email);
      if (!mounted) return;
      setState(() =>
          _resendAvailableAt = DateTime.now().add(const Duration(seconds: 60)));
      AppToast.success(context, 'Confirmation email re-sent');
    } on AuthException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add your email'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const Positioned.fill(child: RotatingGlobeBackground()),
          SafeArea(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              behavior: HitTestBehavior.translucent,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: _sentTo == null
                      ? _buildForm(theme)
                      : _buildPendingState(theme),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(ThemeData theme) {
    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.mark_email_unread_outlined,
                size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Secure your account',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Your trips stay exactly as they are. An email adds account '
              'recovery, sign-in on other devices, invites, and referrals.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email,
              ],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.email_outlined),
              ),
              validator: (v) {
                final s = v?.trim() ?? '';
                if (s.isEmpty) return 'Enter your email';
                if (!s.contains('@') || !s.contains('.')) {
                  return 'Enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                      size: 20),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) =>
                  (v == null || v.length < 8) ? 'At least 8 characters' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirmController,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: 'Confirm password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              validator: (v) => v != _passwordController.text
                  ? 'Passwords don\'t match'
                  : null,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _isLoading
                    ? null
                    : () {
                        final pwd = _generateStrongPassword();
                        _passwordController.text = pwd;
                        _confirmController.text = pwd;
                        setState(() => _obscure = false);
                        AppToast.success(
                            context, 'Strong password generated and filled');
                      },
                child: const Text('Suggest strong password'),
              ),
            ),
            // Referral entry — only when no code is already parked from the
            // instant signup.
            if (!_hasPendingReferral) ...[
              if (!_showReferralField)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showReferralField = true),
                    child: const Text('Have a referral code?'),
                  ),
                )
              else
                TextFormField(
                  controller: _referralCodeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Referral code (optional)',
                    hintText: 'VOYZA-XXXXXX',
                    prefixIcon: Icon(Icons.redeem_rounded),
                  ),
                ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _isLoading ? null : _submit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : const Text('Add email',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingState(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.mark_email_read_outlined,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Confirm your email',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Text(
          'We sent a confirmation link to\n$_sentTo\n\n'
          'You can keep using the app — invites, referrals, and account '
          'recovery unlock the moment you tap it. Check spam if it doesn\'t '
          'arrive within a minute or two.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child:
              const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        TextButton(
          onPressed: _resend,
          child: const Text('Resend email'),
        ),
      ],
    );
  }
}
