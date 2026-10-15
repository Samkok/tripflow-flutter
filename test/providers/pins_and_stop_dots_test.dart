import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/building_outline_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/optimized_map_overlay_provider.dart';
import 'package:voyza/providers/theme_provider.dart';
import 'package:voyza/providers/trip_day_labeler_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/utils/transit_line_style.dart';
import 'package:voyza/utils/trip_day_labels.dart';

class _FakeTripNotifier extends StateNotifier<TripState>
    implements TripNotifier {
  _FakeTripNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTheme extends StateNotifier<ThemeMode> implements ThemeNotifier {
  _FakeTheme() : super(ThemeMode.dark);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _day = DateTime(2026, 10, 14);

LocationModel _stop(String id, double lat, double lng) => LocationModel(
      id: id,
      name: 'Stop $id',
      address: '',
      coordinates: LatLng(lat, lng),
      addedAt: _day,
      scheduledDate: _day,
    );

/// One transit leg a → b: walk, a 4-stop tram ride (3 intermediate
/// stops), walk.
TripState _state() {
  final a = _stop('a', 22.2790, 114.1650);
  final b = _stop('b', 22.2770, 114.1730);
  final walk1 = [a.coordinates, const LatLng(22.2792, 114.1660)];
  final ride = [
    const LatLng(22.2792, 114.1660),
    const LatLng(22.2785, 114.1690),
    const LatLng(22.2780, 114.1710),
    const LatLng(22.2775, 114.1720),
  ];
  final walk2 = [const LatLng(22.2775, 114.1720), b.coordinates];
  final whole = [...walk1, ...ride, ...walk2];
  return TripState(
    pinnedLocations: [a, b],
    optimizedLocationsForSelectedDate: [a, b],
    startLocationId: 'a',
    optimizedRoute: whole,
    legPolylines: [whole],
    legDetails: [
      {
        'mode': 'transit',
        'distance': 1200.0,
        'duration': const Duration(minutes: 14),
        'fromId': 'a',
        'toId': 'b',
        'transit': [
          {
            'lineShort': '',
            'lineName': 'Tram',
            'lineColor': '#266b5c',
            'vehicleType': 'TRAM',
            'stopCount': 4,
            'boardStop': 'Admiralty Station',
            'alightStop': 'Wan Chai',
          },
        ],
        'transitSteps': [
          {'mode': 'WALK', 'points': walk1, 'durationSeconds': 120},
          {
            'mode': 'TRANSIT',
            'points': ride,
            'durationSeconds': 600,
            'lineColor': '#266b5c',
            'vehicleType': 'TRAM',
          },
          {'mode': 'WALK', 'points': walk2, 'durationSeconds': 90},
        ],
      },
    ],
  );
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    tripProvider.overrideWith((ref) => _FakeTripNotifier(_state())),
    selectedDateProvider.overrideWith((ref) => _day),
    themeProvider.overrideWith((ref) => _FakeTheme()),
    activeTripDayLabelerProvider.overrideWithValue(DayLabeler.forTrip(null)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Set<Marker>> markersOf(ProviderContainer c) async {
    await c.read(cachedMarkerBitmapsProvider.future);
    await c.read(transitStopLabelsProvider.future);
    // Let the sync provider pick the resolved bitmaps up.
    await Future<void>.delayed(Duration.zero);
    return c.read(finalMarkersProvider);
  }

  test('the names switch leaves the pin markers untouched', () async {
    final c = _container();
    final before = (await markersOf(c))
        .where((m) => m.markerId.value == 'a' || m.markerId.value == 'b')
        .toList();
    expect(before, hasLength(2));
    c.read(showPlaceNamesProvider.notifier).state = false;
    final after = (await markersOf(c))
        .where((m) => m.markerId.value == 'a' || m.markerId.value == 'b')
        .toList();
    // Equal markers = no platform update = no pin redraw on iOS.
    expect(after, before);
  });

  test('the selected leg beads its ride with one dot per intermediate stop',
      () async {
    final c = _container();
    Iterable<Marker> dots(Set<Marker> ms) =>
        ms.where((m) => m.markerId.value.startsWith('leg_stop_dot_'));
    expect(dots(await markersOf(c)), isEmpty);

    c.read(mapUIStateProvider.notifier).setTappedPolyline('leg_0_s1');
    final beads = dots(await markersOf(c)).toList();
    expect(beads, hasLength(3)); // 4 stops counted to the arrival → 3 between
    // All on the ride, none at its ends.
    for (final d in beads) {
      expect(d.position.longitude, greaterThan(114.1660));
      expect(d.position.longitude, lessThan(114.1720));
    }

    c.read(mapUIStateProvider.notifier).clearHighlights();
    expect(dots(await markersOf(c)), isEmpty);
  });

  test('the focused place gets the app callout, not a platform info window',
      () async {
    final c = _container();
    final pins = (await markersOf(c))
        .where((m) => m.markerId.value == 'a' || m.markerId.value == 'b');
    for (final p in pins) {
      expect(p.infoWindow, InfoWindow.noText);
    }
    expect(await c.read(focusedPlaceCalloutProvider.future), isEmpty);

    final a = c.read(tripProvider).pinnedLocations.first;
    c.read(focusedPlaceProvider.notifier).state = a;
    final callout = await c.read(focusedPlaceCalloutProvider.future);
    expect(callout.map((m) => m.markerId.value), ['place_callout_a']);
    final m = callout.single;
    expect(m.position, a.coordinates);
    // Bottom-centre anchored: the card floats above the pin's head.
    expect(m.anchor, const Offset(0.5, 1.0));
    expect(m.consumeTapEvents, isTrue);

    c.read(focusedPlaceProvider.notifier).state = null;
    expect(await c.read(focusedPlaceCalloutProvider.future), isEmpty);
  });

  test('chip badges carry every ride in its line colour, or the shared blue',
      () {
    final badges = chipBadgesFor([
      {'lineShort': '15', 'lineColor': '#f2f200', 'lineTextColor': '#1f4b7d'},
      {'lineShort': 'Island Line'},
      {'lineShort': '   '},
    ]);
    expect(badges.map((b) => b.text), ['15', 'Island Line']);
    expect(badges[0].fill, const Color(0xFFF2F200));
    expect(badges[0].textColor, const Color(0xFF1F4B7D));
    expect(badges[1].fill, defaultTransitLineColor);
    expect(badges[1].textColor, isNull);
  });
}
