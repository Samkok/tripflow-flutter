import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers/auth_provider.dart';
import '../providers/user_trip_provider.dart';
import '../repositories/trip_repository.dart';
import '../services/photo_service.dart';
import '../services/supabase_service.dart';
import '../providers/subscription_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/rotating_globe_background.dart';
import 'paywall_screen.dart';

/// Lifetime trip copies used (server truth from user_profiles). Free users
/// get exactly one; the counter survives trip deletion by design.
final tripCopiesUsedProvider = FutureProvider<int>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return 0;
  try {
    final row = await SupabaseService.instance.client
        .from('user_profiles')
        .select('trip_copies_used')
        .eq('user_id', uid)
        .maybeSingle();
    return (row?['trip_copies_used'] as int?) ?? 0;
  } catch (_) {
    return 0;
  }
});

/// Copy-a-trip wizard: paste a TRIP-XXXXXX code → read-only preview →
/// choose a start date → server duplicates the whole trip (new id, this
/// user as owner, every date re-anchored, progress reset, copy born
/// private). Mirrors the create-trip wizard's structure: PageView steps,
/// progress dots, ambient globe.
class CopyTripWizard extends ConsumerStatefulWidget {
  const CopyTripWizard({super.key});

  @override
  ConsumerState<CopyTripWizard> createState() => _CopyTripWizardState();
}

class _CopyTripWizardState extends ConsumerState<CopyTripWizard> {
  final _pageController = PageController();
  final _codeController = TextEditingController();

  int _step = 0;
  bool _busy = false;
  Map<String, dynamic>? _preview; // RPC snapshot
  String? _normalizedCode;
  DateTime? _startDate;

  static const _stepCount = 3;

  @override
  void dispose() {
    _pageController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _goTo(int step) {
    setState(() => _step = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Step 0 → 1: fetch the preview ─────────────────────────────────────
  Future<void> _fetchPreview() async {
    final raw = _codeController.text.trim();
    if (raw.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final preview =
          await ref.read(tripRepositoryProvider).getPublicTripPreview(raw);
      if (!mounted) return;
      if (preview == null) {
        AppToast.error(
            context,
            "This code isn't active. Double-check it — or ask the owner "
            'to make the trip public.');
        return;
      }
      setState(() {
        _preview = preview;
        _normalizedCode = raw.toUpperCase().replaceFirst(
            RegExp(r'^TRIP-', caseSensitive: false), '');
      });
      _goTo(1);
    } on TripCodeException catch (e) {
      if (!mounted) return;
      AppToast.error(
          context,
          switch (e.error) {
            TripCodeError.rateLimited =>
              'Too many attempts — try again in a bit.',
            TripCodeError.ownTrip =>
              "That's your own trip — the code is for sharing with others.",
            _ => 'Could not look up that code. Check your connection.',
          });
    } catch (e) {
      debugPrint('CopyTripWizard preview: $e');
      if (mounted) {
        AppToast.error(
            context, 'Could not look up that code. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty && mounted) {
      _codeController.text = text;
      setState(() {});
    }
  }

  // ── Step 2: confirm ───────────────────────────────────────────────────
  Future<void> _confirm() async {
    final code = _normalizedCode;
    final start = _startDate;
    if (code == null || start == null || _busy) return;

    // Client gate first (accurate RevenueCat pro state); the RPC re-checks
    // server-side as the anti-bypass backstop.
    final isPro = ref.read(isProProvider);
    final copiesUsed = ref.read(tripCopiesUsedProvider).valueOrNull ?? 0;
    if (!isPro && copiesUsed >= 1) {
      await _showCopyLimitPaywall();
      return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(tripRepositoryProvider).duplicatePublicTrip(code, start);
      ref.invalidate(userTripsProvider);
      ref.invalidate(tripCopiesUsedProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      AppToast.success(context, "Trip copied — it's yours now!");
    } on TripCodeException catch (e) {
      if (!mounted) return;
      switch (e.error) {
        case TripCodeError.notPublic:
          AppToast.error(context,
              'The owner made this trip private — it can no longer be copied.');
        case TripCodeError.copyLimit:
          await _showCopyLimitPaywall();
        case TripCodeError.rateLimited:
          AppToast.error(context, 'Too many attempts — try again in a bit.');
        case TripCodeError.ownTrip:
          AppToast.error(context,
              "That's your own trip — the code is for sharing with others.");
        case TripCodeError.unknown:
          AppToast.error(
              context, 'Could not copy the trip. Please try again.');
      }
    } catch (e) {
      debugPrint('CopyTripWizard confirm: $e');
      if (mounted) {
        AppToast.error(context, 'Could not copy the trip. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCopyLimitPaywall() async {
    AppToast.info(context,
        "You've used your free trip copy — Pro copies without limits.");
    final upgraded = await showPaywall(context);
    if (upgraded && mounted) _confirm();
  }

  // ── UI ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const Text('Copy a trip'),
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            body: SafeArea(
              child: Column(
                children: [
                  _buildDots(theme),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _buildCodeStep(theme),
                        _buildPreviewStep(theme),
                        _buildDateStep(theme),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDots(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_stepCount, (i) {
          final active = i == _step;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: active ? 22 : 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCodeStep(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Enter the trip code',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Someone shared a trip with you? Paste their code — you\'ll get '
            'your own copy to reshape freely. Their trip stays untouched.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _codeController,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                letterSpacing: 2),
            onSubmitted: (_) => _fetchPreview(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'TRIP-XXXXXX',
              suffixIcon: IconButton(
                tooltip: 'Paste',
                icon: const Icon(Icons.content_paste_rounded, size: 20),
                onPressed: _pasteFromClipboard,
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _codeController.text.trim().isEmpty || _busy
                  ? null
                  : _fetchPreview,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Find trip'),
            ),
          ),
        ],
      ),
    );
  }

  // Read-only preview built purely from the RPC snapshot — deliberately NOT
  // TripDetailsScreen (its providers assume RLS access the viewer lacks).
  Widget _buildPreviewStep(ThemeData theme) {
    final p = _preview;
    if (p == null) return const SizedBox.shrink();
    final locations = (p['locations'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    // Group by calendar day; dateless at the end.
    final byDay = <DateTime?, List<Map<String, dynamic>>>{};
    for (final loc in locations) {
      final raw = loc['scheduled_date'] as String?;
      final d = raw == null ? null : DateTime.tryParse(raw)?.toLocal();
      final key = d == null ? null : DateTime(d.year, d.month, d.day);
      byDay.putIfAbsent(key, () => []).add(loc);
    }
    final dayKeys = byDay.keys.where((k) => k != null).cast<DateTime>().toList()
      ..sort();

    final start = DateTime.tryParse(p['start_date'] as String? ?? '');
    final end = DateTime.tryParse(p['end_date'] as String? ?? '');
    final days = (start != null && end != null)
        ? end.difference(start).inDays + 1
        : dayKeys.length;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            children: [
              Text(p['name'] as String? ?? 'Shared trip',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '$days day${days == 1 ? '' : 's'} · ${locations.length} '
                'place${locations.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < dayKeys.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Text(
                    'Day ${i + 1} · ${DateFormat('EEE, MMM d').format(dayKeys[i])}',
                    style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                ...byDay[dayKeys[i]]!.map((l) => _previewTile(theme, l)),
              ],
              if (byDay.containsKey(null)) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Text('Unscheduled',
                      style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700)),
                ),
                ...byDay[null]!.map((l) => _previewTile(theme, l)),
              ],
              const SizedBox(height: 8),
              Text(
                "You'll get your own copy — the owner keeps theirs, and "
                'neither of you sees the other\'s changes.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 90),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Row(
            children: [
              TextButton(
                onPressed: _busy ? null : () => _goTo(0),
                child: const Text('Back'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : () => _goTo(2),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('Next — pick your dates'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _previewTile(ThemeData theme, Map<String, dynamic> l) {
    final photoRef = l['photo_reference'] as String?;
    final staySecs = (l['stay_duration'] as num?)?.toInt() ?? 1800;
    final stayMin = staySecs ~/ 60;
    final stayLabel = stayMin >= 60
        ? '${stayMin ~/ 60}h${stayMin % 60 == 0 ? '' : ' ${stayMin % 60}m'}'
        : '${stayMin}m';
    final isAccommodation = l['is_accommodation'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: photoRef == null
                ? Container(
                    width: 44,
                    height: 44,
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    child: Icon(
                        isAccommodation
                            ? Icons.hotel_rounded
                            : Icons.place_rounded,
                        size: 22,
                        color: theme.colorScheme.primary),
                  )
                : Image.network(
                    PhotoService.getPhotoUrl(photoReference: photoRef),
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 44,
                      height: 44,
                      color:
                          theme.colorScheme.primary.withValues(alpha: 0.12),
                      child: Icon(Icons.place_rounded,
                          size: 22, color: theme.colorScheme.primary),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l['name'] as String? ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  isAccommodation ? 'Stay · $stayLabel' : 'Visit · $stayLabel',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateStep(ThemeData theme) {
    final p = _preview;
    final start = DateTime.tryParse(p?['start_date'] as String? ?? '');
    final end = DateTime.tryParse(p?['end_date'] as String? ?? '');
    final span =
        (start != null && end != null) ? end.difference(start).inDays : 0;
    final chosen = _startDate;
    final chosenEnd = chosen?.add(Duration(days: span));

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('When does YOUR trip start?',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Pick the first day — every place shifts to match, keeping the '
            'same day-by-day plan (${span + 1} day${span == 0 ? '' : 's'}). '
            'You can change anything later.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _busy
                ? null
                : () async {
                    final now = DateTime.now();
                    final today = DateTime(now.year, now.month, now.day);
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: chosen ?? today,
                      firstDate: today,
                      lastDate: DateTime(today.year + 5),
                      helpText: 'Trip start date',
                    );
                    if (picked != null && mounted) {
                      setState(() => _startDate = picked);
                    }
                  },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: chosen == null
                        ? theme.dividerColor.withValues(alpha: 0.4)
                        : theme.colorScheme.primary),
                color: theme.cardColor.withValues(alpha: 0.55),
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_rounded,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      chosen == null
                          ? 'Choose a start date'
                          : '${DateFormat('EEE, MMM d, yyyy').format(chosen)}'
                              '${chosenEnd == null ? '' : '  →  ${DateFormat('MMM d').format(chosenEnd)}'}',
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight:
                              chosen == null ? FontWeight.w500 : FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              TextButton(
                onPressed: _busy ? null : () => _goTo(1),
                child: const Text('Back'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: chosen == null || _busy ? null : _confirm,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Text('Copy this trip'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
