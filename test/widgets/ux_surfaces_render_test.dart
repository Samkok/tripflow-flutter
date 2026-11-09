// Every reworked UX surface, rendered standalone in light and dark.
//
// Always: each surface must build and settle without an exception (smoke
// coverage for widgets that have no test of their own).
//
// For an eye-check, also export pictures:
//   VOYZA_UX_SHOTS_OUT=build/qa_shots/ux flutter test test/widgets/ux_surfaces_render_test.dart
// writes <dir>/<surface>-<light|dark>.png. Nothing here pumps the Google
// map: only sheet and card bodies are registered.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/detail_sheet_ui_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/subscription_provider.dart';
import 'package:voyza/utils/pro_status_copy.dart';
import 'package:voyza/widgets/pro_status_row.dart';
import 'package:voyza/widgets/save_trips_account_card.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart'
    show
        hasWriteAccessProvider,
        isTripOwnerProvider,
        pendingInvitesProvider,
        sharedTripsProvider,
        tripCollaboratorsProvider;
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/screens/create_trip_screen.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/widgets/optimized_location_card.dart';
import 'package:voyza/services/places_gateway.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/widgets/add_place_sheet.dart';
import 'package:voyza/widgets/buddy_nudge_row.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/map_settings_sheet.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';
import 'package:voyza/widgets/plan_sheet.dart';
import 'package:voyza/widgets/switch_trip_sheet.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';
import '../helpers/shots.dart';

typedef Surface = ({
  WidgetBuilder build,
  List<Override> overrides,
  bool scaffold,
});

/// Registered surfaces. Later phases add theirs here.
final surfaces = <String, Surface>{
  'checklist-all-set': (
    build: (_) => const Padding(
          padding: EdgeInsets.all(16),
          child: ChecklistAllSetCard(),
        ),
    overrides: const [],
    scaffold: true,
  ),
  // Phase 1: which trip the map shows.
  'switch-trip-sheet': (
    build: (_) => const SwitchTripSheet(),
    overrides: [
      userTripsProvider.overrideWith((ref) async => [
            sampleTrip(id: 'a', name: 'Taipei weekend'),
            sampleTrip(
                id: 'b',
                name: 'Tokyo in five days',
                start: DateTime(2026, 11, 2),
                days: 5,
                countryCode: 'JP'),
          ]),
      sharedTripsProvider.overrideWith((ref) async => [
            {
              'permission': 'read',
              'trips': {
                'id': 'c',
                'user_id': 'friend',
                'name': 'Lisbon with Ana',
                'start_date': '2026-12-01T00:00:00+00:00',
                'end_date': '2026-12-04T00:00:00+00:00',
                'country_code': 'PT',
                'created_at': '2026-10-01T00:00:00+00:00',
                'updated_at': '2026-10-01T00:00:00+00:00',
              },
            },
          ]),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('a')),
    ],
    scaffold: true,
  ),
  // Phase 3: one place card, in the plan sheet and on the trip page.
  for (final home in ['plan', 'trip-page'])
    'place-card-$home': (
      build: (_) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (final (i, done) in [(1, false), (2, true)])
                  OptimizedLocationCard(
                    location: LocationModel(
                      id: 'l$i',
                      name: i == 1 ? 'Din Tai Fung' : 'Taipei 101 Observatory',
                      address: 'Xinyi',
                      coordinates: const LatLng(25.033, 121.53),
                      addedAt: DateTime(2026, 10, 1, 15, 12),
                      scheduledDate: DateTime(2026, 10, 6),
                      tripId: 't1',
                      isDone: done,
                      stayDuration: const Duration(minutes: 90),
                    ),
                    number: i,
                    showNumber: home == 'plan',
                    scrollController: ScrollController(),
                    sheetController: null,
                    onLocationTap: null,
                    tripId: 't1',
                    day: DateTime(2026, 10, 6),
                    labeler: DayLabeler.forTrip(
                        sampleTrip(id: 't1', start: DateTime(2026, 10, 5))),
                    footnote:
                        home == 'plan' ? null : 'Added 1 Oct 2026, 3:12 PM',
                    trailing: home == 'plan'
                        ? null
                        : const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 6, vertical: 8),
                            child: Icon(Icons.drag_indicator, size: 22),
                          ),
                  ),
              ],
            ),
          ),
      overrides: [
        tripProvider.overrideWith((ref) => FakeTripNotifier(TripState())),
        hasWriteAccessProvider.overrideWith((ref, id) async => true),
        localActiveTripIdProvider
            .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
      ],
      scaffold: true,
    ),
  // Phase 3: the place sheet, folded and with Details open.
  for (final open in [false, true])
    'place-sheet-${open ? 'details' : 'folded'}': (
      build: (_) => SingleChildScrollView(
            child: LocationDetailSheet(
              location: LocationModel(
                id: 'l1',
                name: 'Din Tai Fung',
                address: 'Xinyi',
                coordinates: const LatLng(25.033, 121.53),
                addedAt: DateTime(2026, 10, 1),
                scheduledDate: DateTime(2026, 10, 6),
                tripId: 't1',
                tag: 'food',
                stayDuration: const Duration(minutes: 90),
              ),
              number: 1,
              parentScrollController: ScrollController(),
              tripId: 't1',
              locationsForDate: const [],
            ),
          ),
      overrides: [
        tripProvider.overrideWith((ref) => FakeTripNotifier(TripState())),
        hasWriteAccessProvider.overrideWith((ref, id) async => true),
        localActiveTripIdProvider
            .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
        userTripsProvider.overrideWith((ref) async =>
            [sampleTrip(id: 't1', start: DateTime(2026, 10, 5))]),
        realtimeActiveTripProvider.overrideWith((ref) =>
            Stream.value(sampleTrip(id: 't1', start: DateTime(2026, 10, 5)))),
        detailSheetDetailsOpenProvider.overrideWith((ref) => open),
      ],
      scaffold: true,
    ),
  // Phase 2: one add-place sheet, three segments.
  for (final seg in AddPlaceSegment.values)
    'add-place-${seg.name}': (
      build: (_) => AddPlaceSheet(
            trip: sampleTrip(id: 't1', name: 'Taipei weekend'),
            day: DateTime(2026, 10, 6),
            initial: seg,
            nearbyCenter: seg == AddPlaceSegment.nearby
                ? const LatLng(25.033, 121.53)
                : null,
          ),
      overrides: [
        placesGatewayProvider.overrideWithValue(FakePlacesGateway(
          nearbyPlaces: [
            const NearbyPlace(
              placeId: 'n1',
              name: 'Din Tai Fung',
              vicinity: 'Xinyi Road',
              coordinates: LatLng(25.033, 121.53),
              distanceMeters: 120,
              primaryType: 'restaurant',
              types: ['restaurant'],
            ),
            const NearbyPlace(
              placeId: 'n2',
              name: 'Taipei 101 Observatory',
              vicinity: 'Xinyi District',
              coordinates: LatLng(25.0339, 121.5645),
              distanceMeters: 480,
              primaryType: 'tourist_attraction',
              types: ['tourist_attraction'],
            ),
          ],
        )),
        savedLocationsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      scaffold: true,
    ),
  // Phase 5: the one planning verb, both scopes.
  'plan-sheet-day': (
    build: (_) => const PlanSheet(initial: PlanScope.day),
    overrides: _planOverrides(),
    scaffold: true,
  ),
  'plan-sheet-trip': (
    build: (_) => const PlanSheet(initial: PlanScope.trip),
    overrides: _planOverrides(),
    scaffold: true,
  ),
  // Phase 6: trip creation on one screen, and the buddy nudge that took
  // the wizard's buddies step.
  'create-trip-undated': (
    build: (_) => const CreateTripScreen(),
    overrides: [userTripsProvider.overrideWith((ref) async => [])],
    scaffold: false,
  ),
  'create-trip-dated': (
    build: (_) => CreateTripScreen(
          initialCountryCode: 'JP',
          initialDates: DateTimeRange(
              start: DateTime(2027, 3, 9), end: DateTime(2027, 3, 12)),
        ),
    overrides: [userTripsProvider.overrideWith((ref) async => [])],
    scaffold: false,
  ),
  'buddy-nudge-row': (
    build: (_) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: BuddyNudgeRow(tripId: 't1', ownerId: 'u1', onInvite: () {}),
        ),
    overrides: [
      currentUserIdProvider.overrideWithValue('u1'),
      tripCollaboratorsProvider.overrideWith((ref, id) async => []),
      pendingInvitesProvider.overrideWith((ref, id) async => []),
    ],
    scaffold: true,
  ),
  // Phase 7: the one Map settings sheet.
  'map-settings-sheet': (
    build: (_) => const Align(
          alignment: Alignment.bottomCenter,
          child: MapSettingsSheetBody(),
        ),
    overrides: const [],
    scaffold: true,
  ),
  // Phase 8: the one subscription row, every tier.
  for (final tier in {
    'free': ProStatus.free,
    'trial': ProStatus(
        tier: ProTier.trial,
        expiresAt: DateTime.now().add(const Duration(days: 2, hours: 2))),
    'pro': ProStatus(
        tier: ProTier.pro, expiresAt: DateTime(2027, 3, 9), willRenew: true),
    'lifetime': const ProStatus(tier: ProTier.pro),
  }.entries)
    'pro-status-${tier.key}': (
      build: (_) => const Padding(
            padding: EdgeInsets.all(16),
            child: ProStatusRow(),
          ),
      overrides: [proStatusProvider.overrideWithValue(tier.value)],
      scaffold: true,
    ),
  // Phase 9: the soft sign-up ask on the trips list.
  'save-trips-account-card': (
    build: (_) => const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: SaveTripsAccountCard(),
        ),
    overrides: [
      currentUserIdProvider.overrideWithValue(null),
      userTripsProvider.overrideWith((ref) async => [sampleTrip(id: 'a')]),
    ],
    scaffold: true,
  ),
};

final _planStart = DateTime(DateTime.now().year + 1, 3, 9);

/// Nine places on the first day of a trip that is still ahead.
List<Override> _planOverrides() {
  final trip = sampleTrip(id: 'plan-trip', start: _planStart, days: 3);
  final places = [
    for (var i = 0; i < 9; i++)
      LocationModel(
        id: 'p$i',
        name: 'Place $i',
        address: '',
        coordinates: LatLng(25.04 + (i % 5) * 0.004, 121.51 + (i % 7) * 0.004),
        addedAt: DateTime(2026),
        scheduledDate: _planStart,
        tripId: 'plan-trip',
        stayDuration: const Duration(minutes: 60),
      ),
  ];
  return [
    tripProvider.overrideWith(
        (ref) => FakeTripNotifier(TripState(pinnedLocations: places))),
    realtimeActiveTripProvider.overrideWith((ref) => Stream.value(trip)),
    selectedDateProvider.overrideWith((ref) => _planStart),
    allDaysModeProvider.overrideWith((ref) => false),
    isProProvider.overrideWithValue(true),
    isTripOwnerProvider.overrideWith((ref, id) async => true),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['VOYZA_UX_SHOTS_OUT'];

  setUpAll(() async {
    if (out != null) await loadAppFonts();
  });

  final themes = {'light': AppTheme.lightTheme, 'dark': AppTheme.darkTheme};

  for (final surface in surfaces.entries) {
    for (final theme in themes.entries) {
      testWidgets('${surface.key} renders (${theme.key})', (tester) async {
        await useMockPrefs();
        final key = GlobalKey();
        await pumpVoyza(
          tester,
          Builder(builder: surface.value.build),
          overrides: surface.value.overrides,
          theme: theme.value,
          scaffold: surface.value.scaffold,
          boundaryKey: key,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (out != null) {
          await exportShot(tester, key, '$out/${surface.key}-${theme.key}.png');
        }
      });
    }
  }
}
