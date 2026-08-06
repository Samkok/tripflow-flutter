import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers/auth_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/analytics_service.dart';
import '../services/anonymous_user_service.dart';
import '../providers/onboarding_checklist_provider.dart';
import '../services/trip_buddy_service.dart';
import '../widgets/app_toast.dart';
import '../utils/trip_dates.dart';
import '../widgets/country_picker_sheet.dart';
import '../widgets/country_flag_icon.dart';
import '../widgets/rotating_globe_background.dart';
import '../models/trip.dart';
import 'trip_details_screen.dart';

/// Step-by-step trip creation (the Wanderlog pattern): one decision per
/// screen instead of one dense form.
///
///   1. Country      — optional, skippable
///   2. Date range   — required (changeable later)
///   3. Trip name    — required
///   4. Trip buddies — optional, skippable (invite later)
///
/// Every step: an illustration with its label below, Cancel (top right),
/// Back (top left, from step 2 on), and a primary Next button that becomes
/// Confirm on the last step. Confirm creates the trip, sends any buddy
/// invites, and replaces this route with the trip's details screen.
class CreateTripWizard extends ConsumerStatefulWidget {
  /// Pre-picked country (onboarding hand-off). Empty string = "explicitly
  /// no country" — the step still shows so the user can revise.
  final String? initialCountryCode;

  const CreateTripWizard({super.key, this.initialCountryCode});

  @override
  ConsumerState<CreateTripWizard> createState() => _CreateTripWizardState();
}

class _CreateTripWizardState extends ConsumerState<CreateTripWizard> {
  final _pageController = PageController();
  int _step = 0;

  /// Guests skip the buddies step — inviting collaborators needs an
  /// account (trip_shares rows, invite emails). Their trips live on-device
  /// until the sign-in sync.
  bool get _isGuest => ref.read(currentUserIdProvider) == null;

  int get _stepCount => _isGuest ? 3 : 4;

  // Collected answers.
  String? _countryCode;
  String? _countryName;
  DateTimeRange? _dates;
  final _nameController = TextEditingController();
  final _buddyController = TextEditingController();

  /// Collected buddies. [invite] marks emails with no VoyZa account whose
  /// owner already consented (via the shared invite dialog) to a pending
  /// invite once the trip exists.
  final List<({String email, bool invite})> _buddies = [];
  String? _buddyError;
  bool _checkingBuddy = false;

  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final code = widget.initialCountryCode;
    if (code != null && code.isNotEmpty) _countryCode = code.toUpperCase();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _buddyController.dispose();
    super.dispose();
  }

  // ─── Navigation ────────────────────────────────────────────────────────

  void _goTo(int step) {
    setState(() => _step = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  bool get _nextEnabled {
    switch (_step) {
      case 1:
        return _dates != null;
      case 2:
        return _nameController.text.trim().isNotEmpty;
      default:
        return true;
    }
  }

  void _onNext() {
    if (_step < _stepCount - 1) {
      _goTo(_step + 1);
    } else {
      _confirm();
    }
  }

  // ─── Pickers ───────────────────────────────────────────────────────────

  Future<void> _pickCountry() async {
    final result = await showCountryPickerSheet(
      context,
      selectedCode: _countryCode,
    );
    if (result == null) return;
    setState(() {
      if (result.code == kClearCountry.code) {
        _countryCode = null;
        _countryName = null;
      } else {
        _countryCode = result.code;
        _countryName = result.name;
      }
    });
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _dates,
      // Trips can't start in the past — backward selection was a bug.
      firstDate: today,
      lastDate: DateTime(today.year + 5),
    );
    if (picked == null) return;
    setState(() => _dates = picked);
  }

  Future<void> _addBuddy() async {
    final email = _buddyController.text.trim().toLowerCase();
    if (email.isEmpty || _checkingBuddy) return;
    if (!TripBuddyService.isValidEmail(email)) {
      setState(() => _buddyError = 'Please enter a valid email address');
      return;
    }
    if (_buddies.any((b) => b.email == email)) {
      setState(() => _buddyError = 'Already added');
      return;
    }

    setState(() {
      _checkingBuddy = true;
      _buddyError = null;
    });
    final hasAccount = await TripBuddyService.emailHasAccount(ref, email);
    if (!mounted) return;
    setState(() => _checkingBuddy = false);

    if (hasAccount) {
      setState(() {
        _buddies.add((email: email, invite: false));
        _buddyController.clear();
      });
      return;
    }

    // No account — the same consent dialog the Collaborators screen shows.
    final typedName = _nameController.text.trim();
    final confirmed = await showInviteBuddyDialog(
      context,
      email: email,
      tripName: typedName.isEmpty ? 'this trip' : typedName,
    );
    if (confirmed == true && mounted) {
      setState(() {
        _buddies.add((email: email, invite: true));
        _buddyController.clear();
      });
    }
  }

  // ─── Confirm ───────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    if (_creating) return;
    final name = _nameController.text.trim();
    final dates = _dates;
    if (name.isEmpty || dates == null) return;
    // Guests get the device's stable anonymous id — same convention as
    // SavedLocation rows, re-stamped with the real uid at sync time.
    final userId =
        ref.read(currentUserIdProvider) ?? await AnonymousUserService.id;
    if (!mounted) return;

    // An email typed but never added via + would be silently discarded —
    // run it through the add flow first (it clears the field on success).
    if (_buddyController.text.trim().isNotEmpty) {
      await _addBuddy();
      if (!mounted) return;
      if (_buddyController.text.trim().isNotEmpty) {
        setState(
            () => _buddyError = 'Tap + to add this buddy, or clear the field.');
        return;
      }
    }

    setState(() => _creating = true);

    // ── Create the trip: its OWN try. A later buddy/navigation failure
    // must never read as "could not create trip" — retrying after that
    // message created a second identical trip.
    final Trip trip;
    final bool wasFirstTrip;
    try {
      wasFirstTrip = ref.read(userTripsProvider).asData?.value.isEmpty ?? false;
      trip = await ref.read(tripRepositoryProvider).createTrip(
            userId: userId,
            name: name,
            description: null,
            countryCode: _countryCode,
            startDate: dates.start,
            endDate: dates.end,
          );
      ref.invalidate(userTripsProvider);
      AnalyticsService.instance.tripCreated();
      // Checklist step 1 — and pre-arm the add-locations spotlight for the
      // trip details screen this wizard navigates to next.
      ref.read(checklistProvider.notifier).mark(ChecklistStep.createTrip);
      // Pre-arm the add-locations spotlight only while step 2 is still the
      // goal — veterans creating their fifth trip shouldn't get a tour.
      if (!ref.read(checklistProvider).isDone(ChecklistStep.addLocations)) {
        ref.read(checklistGuideRequestProvider.notifier).state =
            ChecklistGuide.addLocations;
      }
    } catch (e) {
      debugPrint('CreateTripWizard._confirm create: $e');
      if (mounted) {
        setState(() => _creating = false);
        AppToast.error(context,
            'Could not create trip. Please check your connection and try again.');
      }
      return;
    }

    // ── Buddy invites through the SHARED flow (same function as the
    // Collaborators screen). addBuddy converts its own failures into error
    // RESULTS, so nothing here can abort the flow — the trip exists and we
    // WILL navigate to it.
    var joined = 0, invited = 0, failed = 0;
    for (final b in _buddies) {
      if (!mounted) break;
      final result = await TripBuddyService.addBuddy(
        context,
        ref,
        tripId: trip.id,
        tripName: name,
        email: b.email,
        inviteWithoutAsking: b.invite,
      );
      switch (result.status) {
        case BuddyAddStatus.added:
          joined++;
        case BuddyAddStatus.invited:
          invited++;
        case BuddyAddStatus.cancelled:
          break;
        case BuddyAddStatus.error:
          failed++;
      }
    }

    if (!mounted) return;
    if (_buddies.isNotEmpty) {
      final parts = <String>[
        if (joined > 0) '$joined joined',
        if (invited > 0) '$invited will join when they sign up',
        if (failed > 0) '$failed failed — invite them again from the trip',
      ];
      AppToast.info(context, 'Trip buddies: ${parts.join(' · ')}');
    }

    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => TripDetailsScreen(
        trip: trip,
        celebrateFirstTrip: wasFirstTrip,
      ),
    ));
  }

  // ─── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        // Ambient rotating globe behind the wizard (matches the rest of
        // the app's surfaces).
        Positioned.fill(
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                // Header: Back · progress dots · Cancel.
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: _step > 0
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: IconButton(
                                  onPressed:
                                      _creating ? null : () => _goTo(_step - 1),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                  tooltip: 'Back',
                                ),
                              )
                            : null,
                      ),
                      Expanded(child: Center(child: _buildDots(theme))),
                      SizedBox(
                        width: 72,
                        child: TextButton(
                          onPressed: _creating
                              ? null
                              : () => Navigator.of(context).maybePop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _buildCountryStep(theme),
                      _buildDatesStep(theme),
                      _buildNameStep(theme),
                      if (!_isGuest) _buildBuddyStep(theme),
                    ],
                  ),
                ),
                // Footer: primary Next/Confirm (+ Skip on optional steps).
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        // Rebuilds with every name keystroke via the listenable
                        // (not setState) — the four step subtrees stay still.
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _nameController,
                          builder: (context, _, __) => FilledButton(
                            onPressed:
                                (_nextEnabled && !_creating) ? _onNext : null,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                              textStyle: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            child: _creating
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.5),
                                  )
                                : Text(_step == _stepCount - 1
                                    ? 'Confirm'
                                    : 'Next'),
                          ),
                        ),
                      ),
                      if (_step == 0 && _countryCode == null)
                        TextButton(
                          onPressed: _creating ? null : () => _goTo(1),
                          child: const Text('Skip — no country'),
                        ),
                      if (!_isGuest &&
                          _step == _stepCount - 1 &&
                          _buddies.isEmpty)
                        TextButton(
                          onPressed: _creating ? null : _confirm,
                          child: const Text('Skip — invite them later'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDots(ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_stepCount, (i) {
        final active = i == _step;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  /// Illustration + its label below — the fixed visual anchor of a step.
  Widget _buildStepHeader(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String caption,
  }) {
    final primary = theme.colorScheme.primary;
    return Column(
      children: [
        Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                primary.withValues(alpha: 0.22),
                primary.withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(color: primary.withValues(alpha: 0.35)),
          ),
          child: Icon(icon, size: 56, color: primary),
        ),
        const SizedBox(height: 18),
        Text(label,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          caption,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _stepScaffold(ThemeData theme,
      {required Widget header, required Widget control, Widget? footnote}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        children: [
          header,
          const SizedBox(height: 28),
          control,
          if (footnote != null) ...[const SizedBox(height: 12), footnote],
        ],
      ),
    );
  }

  /// The shared outlined "picker tile" look for tappable step controls.
  Widget _pickerTile(ThemeData theme,
      {required IconData icon,
      Widget? leading,
      required String text,
      required bool filled,
      required VoidCallback onTap}) {
    final primary = theme.colorScheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color:
                  filled ? primary.withValues(alpha: 0.6) : theme.dividerColor,
              width: filled ? 1.5 : 1,
            ),
            color:
                filled ? primary.withValues(alpha: 0.06) : Colors.transparent,
          ),
          child: Row(
            children: [
              leading ??
                  Icon(icon,
                      color: filled
                          ? primary
                          : theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
                    color: filled ? null : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCountryStep(ThemeData theme) {
    final hasCountry = _countryCode != null;
    return _stepScaffold(
      theme,
      header: _buildStepHeader(
        theme,
        icon: Icons.public_rounded,
        label: 'Where are you headed?',
        caption: 'Pick the trip\'s country so searches and dates stay '
            'focused. Optional — skip it if you\'re not sure yet.',
      ),
      control: _pickerTile(
        theme,
        icon: hasCountry ? Icons.flag_rounded : Icons.travel_explore_rounded,
        // CountryFlagIcon, not an emoji flag: Android's system font omits
        // flag glyphs, so emoji rendered as a "?" tofu box there.
        leading: hasCountry ? CountryFlagIcon(_countryCode!, height: 18) : null,
        text: hasCountry ? (_countryName ?? _countryCode!) : 'Select a country',
        filled: hasCountry,
        onTap: _pickCountry,
      ),
    );
  }

  Widget _buildDatesStep(ThemeData theme) {
    final dates = _dates;
    final label = dates == null
        ? 'Select your dates'
        : '${DateFormat('MMM d').format(dates.start)} – '
            '${DateFormat('MMM d, yyyy').format(dates.end)} '
            '(${daySpanDays(dates.start, dates.end) + 1} days)';
    return _stepScaffold(
      theme,
      header: _buildStepHeader(
        theme,
        icon: Icons.calendar_month_rounded,
        label: 'When is the trip?',
        caption: 'Choose your travel dates — every day gets its own plan.',
      ),
      control: _pickerTile(
        theme,
        icon: Icons.date_range_rounded,
        text: label,
        filled: dates != null,
        onTap: _pickDates,
      ),
      footnote: Text(
        'Don\'t worry — you can change the dates later.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    return _stepScaffold(
      theme,
      header: _buildStepHeader(
        theme,
        icon: Icons.edit_note_rounded,
        label: 'Name your trip',
        caption: 'Give it a name you\'ll recognize at a glance.',
      ),
      control: TextField(
        controller: _nameController,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (_) {
          if (_nextEnabled) _onNext();
        },
        decoration: InputDecoration(
          hintText: 'e.g. Singapore with family',
          helperText: 'or "Business trip to Dubai"',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  Widget _buildBuddyStep(ThemeData theme) {
    return _stepScaffold(
      theme,
      header: _buildStepHeader(
        theme,
        icon: Icons.group_add_rounded,
        label: 'Add a trip buddy',
        caption: 'Plan together in realtime. Optional — you can always '
            'invite them later from the trip.',
      ),
      control: Column(
        children: [
          TextField(
            controller: _buddyController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            // Enter just dismisses the keyboard — adding is the + button's
            // job (Enter used to advance the flow, which felt accidental).
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
            decoration: InputDecoration(
              hintText: 'friend@email.com',
              errorText: _buddyError,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              suffixIcon: _checkingBuddy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  : IconButton(
                      onPressed: _addBuddy,
                      icon: const Icon(Icons.add_rounded),
                      tooltip: 'Add buddy',
                    ),
            ),
          ),
          if (_buddies.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final b in _buddies)
                  Chip(
                    avatar: Icon(
                      b.invite
                          ? Icons.mail_outline_rounded
                          : Icons.check_circle_rounded,
                      size: 18,
                    ),
                    label: Text(b.email),
                    onDeleted: () => setState(() => _buddies.remove(b)),
                  ),
              ],
            ),
          ],
        ],
      ),
      footnote: Text(
        'Buddies on VoyZa join instantly; anyone else joins the moment '
        'they sign up with that email.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
