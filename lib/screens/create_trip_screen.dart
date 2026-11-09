import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/onboarding_checklist_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/analytics_service.dart';
import '../services/anonymous_user_service.dart';
import '../utils/countries.dart';
import '../utils/trip_dates.dart';
import '../widgets/app_toast.dart';
import '../widgets/country_flag_icon.dart';
import '../widgets/country_picker_sheet.dart';
import '../widgets/rotating_globe_background.dart';
import 'trip_details_screen.dart';

/// Signature of the date-range picker the form opens; a test seam.
typedef PickDateRange = Future<DateTimeRange?> Function(
    BuildContext context, DateTimeRange? current);

/// Trip creation on one screen: a name (required), a country (optional)
/// and the dates, which default to "No dates yet · 3 days" so a trip is
/// one field away. Identical for guests and signed-in users; travel
/// buddies are invited from the trip page.
class CreateTripScreen extends ConsumerStatefulWidget {
  const CreateTripScreen({
    super.key,
    this.initialCountryCode,
    this.initialDates,
    this.onCreated,
    this.pickDateRange,
  });

  /// Pre-picked country (onboarding hand-off). Empty string = "explicitly
  /// no country".
  final String? initialCountryCode;

  /// Start dated instead of "No dates yet" (tests, renders).
  final DateTimeRange? initialDates;

  /// Test seam: called with the new trip instead of opening its page.
  final void Function(Trip trip, {required bool wasFirstTrip})? onCreated;

  /// Test seam: stands in for the Material range picker.
  final PickDateRange? pickDateRange;

  @override
  ConsumerState<CreateTripScreen> createState() => _CreateTripScreenState();
}

class _CreateTripScreenState extends ConsumerState<CreateTripScreen> {
  final _nameController = TextEditingController();
  String? _countryCode;
  String? _countryName;

  /// null = "No dates yet": the trip is created on the day anchor with
  /// [_days] numbered days; real dates come later from the trip menu.
  DateTimeRange? _dates;
  int _days = 3;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    final code = widget.initialCountryCode;
    if (code != null && code.isNotEmpty) {
      _countryCode = code.toUpperCase();
      _countryName = findCountryByCode(_countryCode)?.name;
    }
    _dates = widget.initialDates;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickCountry() async {
    final result =
        await showCountryPickerSheet(context, selectedCode: _countryCode);
    if (result == null || !mounted) return;
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
    final DateTimeRange? picked;
    if (widget.pickDateRange != null) {
      picked = await widget.pickDateRange!(context, _dates);
    } else {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      picked = await showDateRangePicker(
        context: context,
        initialDateRange: _dates,
        // Trips can't start in the past.
        firstDate: today,
        lastDate: DateTime(today.year + 5),
      );
    }
    if (picked == null || !mounted) return;
    setState(() => _dates = picked);
  }

  Future<void> _create() async {
    if (_creating) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    // Guests get the device's stable anonymous id — same convention as
    // SavedLocation rows, re-stamped with the real uid at sync time.
    final userId =
        ref.read(currentUserIdProvider) ?? await AnonymousUserService.id;
    if (!mounted) return;
    setState(() => _creating = true);

    final Trip trip;
    final bool wasFirstTrip;
    try {
      wasFirstTrip = ref.read(userTripsProvider).asData?.value.isEmpty ?? false;
      final dates = _dates;
      trip = await ref.read(tripRepositoryProvider).createTrip(
            userId: userId,
            name: name,
            description: null,
            countryCode: _countryCode,
            startDate: dates?.start ?? tripDatesTbdAnchor,
            endDate: dates?.end ?? shiftTripDay(tripDatesTbdAnchor, _days - 1),
            datesTbd: dates == null,
          );
      ref.invalidate(userTripsProvider);
      AnalyticsService.instance.tripCreated();
      // Checklist step 1 — and pre-arm the add-locations spotlight for the
      // trip page this screen opens next, only while step 2 is still the
      // goal (veterans creating their fifth trip get no tour).
      ref.read(checklistProvider.notifier).mark(ChecklistStep.createTrip);
      final checklist = ref.read(checklistProvider);
      if (!checklist.skipped && !checklist.isDone(ChecklistStep.addLocations)) {
        ref.read(checklistGuideRequestProvider.notifier).state =
            ChecklistGuide.addLocations;
      }
    } catch (e) {
      debugPrint('CreateTripScreen._create: $e');
      if (mounted) {
        setState(() => _creating = false);
        AppToast.error(context,
            'Could not create trip. Please check your connection and try again.');
      }
      return;
    }

    if (!mounted) return;
    final onCreated = widget.onCreated;
    if (onCreated != null) {
      // The screen stays up in a test: stop the spinner.
      setState(() => _creating = false);
      onCreated(trip, wasFirstTrip: wasFirstTrip);
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => TripDetailsScreen(
        trip: trip,
        celebrateFirstTrip: wasFirstTrip,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
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
            backgroundColor: Colors.transparent,
            title: const Text('New trip'),
            leading: IconButton(
              tooltip: 'Cancel',
              onPressed:
                  _creating ? null : () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('create-trip-name'),
                  cursorOpacityAnimates: false,
                  controller: _nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _create(),
                  decoration: InputDecoration(
                    labelText: 'Trip name',
                    hintText: 'e.g. Singapore with family',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(height: 16),
                _countryTile(theme),
                const SizedBox(height: 12),
                _datesCard(theme),
                const SizedBox(height: 10),
                Text(
                  _dates == null
                      ? 'Plan by day number now; set the dates later from '
                          'the trip menu and every day keeps its plan.'
                      : 'You can change the dates later.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          // Above the keyboard while the name is typed.
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    // Rebuilds with every keystroke via the listenable, not
                    // setState — the form above stays still.
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _nameController,
                      builder: (context, value, _) => FilledButton(
                        key: const Key('create-trip-submit'),
                        onPressed: (value.text.trim().isNotEmpty && !_creating)
                            ? _create
                            : null,
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : const Text('Create trip'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'You can invite travel buddies from the trip page.',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The outlined picker-tile look shared by the country and dates rows.
  BoxDecoration _tileDecoration(ThemeData theme, {required bool filled}) {
    final primary = theme.colorScheme.primary;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: filled ? primary.withValues(alpha: 0.6) : theme.dividerColor,
        width: filled ? 1.5 : 1,
      ),
      color: filled ? primary.withValues(alpha: 0.06) : Colors.transparent,
    );
  }

  Widget _countryTile(ThemeData theme) {
    final hasCountry = _countryCode != null;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('create-trip-country'),
        borderRadius: BorderRadius.circular(14),
        onTap: _creating ? null : _pickCountry,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: _tileDecoration(theme, filled: hasCountry),
          child: Row(
            children: [
              // CountryFlagIcon, not an emoji flag: Android's system font
              // omits flag glyphs.
              if (hasCountry)
                CountryFlagIcon(_countryCode!, height: 18)
              else
                Icon(Icons.public_rounded, color: muted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  hasCountry
                      ? (_countryName ?? _countryCode!)
                      : 'Add a country · optional',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: hasCountry ? FontWeight.w700 : FontWeight.w500,
                    color: hasCountry ? null : muted,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _datesCard(ThemeData theme) {
    final dates = _dates;
    final muted = theme.colorScheme.onSurfaceVariant;
    final primary = theme.colorScheme.primary;
    final label = dates == null
        ? 'No dates yet · $_days ${_days == 1 ? 'day' : 'days'}'
        : '${DateFormat('MMM d').format(dates.start)} – '
            '${DateFormat('MMM d, yyyy').format(dates.end)} '
            '(${daySpanDays(dates.start, dates.end) + 1} days)';
    return Container(
      decoration: _tileDecoration(theme, filled: true),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
            child: Row(
              children: [
                Icon(Icons.calendar_month_rounded, color: primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (dates == null) ...[
                  IconButton(
                    key: const Key('create-trip-days-minus'),
                    tooltip: 'One day fewer',
                    onPressed: _days > 1 && !_creating
                        ? () => setState(() => _days--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                  IconButton(
                    key: const Key('create-trip-days-plus'),
                    tooltip: 'One day more',
                    onPressed: _days < 60 && !_creating
                        ? () => setState(() => _days++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.5)),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
              child: dates == null
                  ? TextButton.icon(
                      onPressed: _creating ? null : _pickDates,
                      icon: const Icon(Icons.date_range_rounded, size: 18),
                      label: const Text('Pick dates'),
                    )
                  : TextButton.icon(
                      onPressed: _creating
                          ? null
                          : () => setState(() => _dates = null),
                      icon: const Icon(Icons.event_busy_rounded, size: 18),
                      label: const Text('No dates yet'),
                    ),
            ),
          ),
          if (dates == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Plan by day number and set the dates later.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
