import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/core/measurement_config.dart';
import 'package:voyza/core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/services/measurement_consent_service.dart';
import 'package:voyza/services/tracking_permission.dart';
import 'package:voyza/utils/ads_event_map.dart';
import 'package:voyza/utils/measurement_decision.dart';
import 'package:voyza/widgets/measurement_consent_dialog.dart';
import 'package:voyza/widgets/measurement_settings_tiles.dart';

class _Applier implements MeasurementApplier {
  @override
  Future<void> apply({required bool analytics, required bool ads}) async {}
}

class _Sink implements AdsMeasurementSink {
  final tracking = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async {}

  @override
  Future<void> setTrackingAllowed(bool allowed) async => tracking.add(allowed);

  @override
  void log(AdsEvent event) {}
}

class _Gateway implements TrackingPermissionGateway {
  _Gateway(this.current, {this.answer = TrackingStatus.authorized});

  TrackingStatus current;
  final TrackingStatus answer;
  int requests = 0;

  @override
  Future<TrackingStatus> status() async => current;

  @override
  Future<TrackingStatus> request() async {
    requests++;
    return current = answer;
  }
}

Future<MeasurementConsentService> serviceIn(String? country) async {
  final service = MeasurementConsentService(
    applier: _Applier(),
    deviceCountry: () => country,
    lookupCountry: () async => country,
  );
  await service.applyAtStartup();
  await service.whenRegionSettled();
  return service;
}

/// A page with one button that runs [action] with a live context.
Future<void> pumpHost(
  WidgetTester tester,
  Future<void> Function(BuildContext context) action,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => action(context),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
}

bool ticked(WidgetTester tester, String key) => tester
    .widget<Checkbox>(find.descendant(
        of: find.byKey(ValueKey(key)), matching: find.byType(Checkbox)))
    .value!;

OutlinedButton button(WidgetTester tester, String label) =>
    tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ads measurement is on unless a build switches it off', () {
    // On since the release that added Meta's SDK, Apple's tracking prompt
    // and the revised privacy policy. The way back is
    // --dart-define=VOYZA_ADS_MEASUREMENT=false.
    expect(MeasurementConfig.adsMeasurement, isTrue);
  });

  // Looked at by hand:
  //   VOYZA_PROMPT_OUT=/tmp/prompt flutter test test/widgets/measurement_consent_dialog_test.dart
  testWidgets('exports the prompts as images', (tester) async {
    final out = Platform.environment['VOYZA_PROMPT_OUT'];
    if (out == null) return;
    for (final family in ['Roboto', '.SF UI Text', '.SF UI Display']) {
      final loader = FontLoader(family);
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        final bytes = File('assets/fonts/Roboto-$weight.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final shots = <String, Future<void> Function(BuildContext)>{
      'consent': showMeasurementConsentDialog,
      'notice': showMeasurementNotice,
    };
    for (final theme
        in {'light': AppTheme.lightTheme, 'dark': AppTheme.darkTheme}.entries) {
      for (final shot in shots.entries) {
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: theme.value.copyWith(
              textTheme: theme.value.textTheme.apply(fontFamily: 'Roboto'),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => shot.value(context),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        if (shot.key == 'consent') {
          await tester.tap(find.text('Usage analytics'));
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$out-${shot.key}-${theme.key}.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
        });
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  group('the opt-in prompt', () {
    testWidgets('offers both purposes, unticked, with three equal buttons',
        (tester) async {
      await pumpHost(tester, showMeasurementConsentDialog);

      expect(find.text('Your privacy choices'), findsOneWidget);
      expect(find.text('Usage analytics'), findsOneWidget);
      expect(find.text('Ads measurement'), findsOneWidget);
      expect(find.textContaining('Meta (Facebook, Instagram) and Google'),
          findsOneWidget);
      expect(find.textContaining('16 or older'), findsOneWidget);
      expect(find.text('Privacy policy'), findsOneWidget);

      expect(ticked(tester, 'measurement-analytics'), isFalse);
      expect(ticked(tester, 'measurement-ads'), isFalse);

      // Refusing looks exactly like accepting: same kind of button.
      for (final label in ["Don't allow", 'Allow selected', 'Allow all']) {
        expect(find.widgetWithText(OutlinedButton, label), findsOneWidget);
      }
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      // Nothing ticked, nothing to allow.
      expect(button(tester, 'Allow selected').onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cannot be waved away without choosing', (tester) async {
      await pumpHost(tester, showMeasurementConsentDialog);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Your privacy choices'), findsOneWidget);
    });

    testWidgets('each button gives the answer it names', (tester) async {
      Future<MeasurementConsentAnswer> answerAfter(
          Future<void> Function() taps) async {
        late MeasurementConsentAnswer answer;
        await pumpHost(tester, (context) async {
          answer = await showMeasurementConsentDialog(context);
        });
        await taps();
        await tester.pumpAndSettle();
        expect(find.text('Your privacy choices'), findsNothing);
        return answer;
      }

      expect(
        await answerAfter(() => tester.tap(find.text("Don't allow"))),
        (analytics: false, ads: false),
      );
      expect(
        await answerAfter(() => tester.tap(find.text('Allow all'))),
        (analytics: true, ads: true),
      );
      expect(
        await answerAfter(() async {
          await tester.tap(find.text('Usage analytics'));
          await tester.pump();
          expect(button(tester, 'Allow selected').onPressed, isNotNull);
          await tester.tap(find.text('Allow selected'));
        }),
        (analytics: true, ads: false),
      );
      expect(
        await answerAfter(() async {
          await tester.tap(find.text('Ads measurement'));
          await tester.pump();
          await tester.tap(find.text('Allow selected'));
        }),
        (analytics: false, ads: true),
      );
      // Ticking both and then "Don't allow" is still a no.
      expect(
        await answerAfter(() async {
          await tester.tap(find.text('Usage analytics'));
          await tester.tap(find.text('Ads measurement'));
          await tester.pump();
          await tester.tap(find.text("Don't allow"));
        }),
        (analytics: false, ads: false),
      );
    });

    testWidgets('an earlier yes to analytics shows ticked; ads never does',
        (tester) async {
      await pumpHost(
          tester, (c) => showMeasurementConsentDialog(c, analytics: true));
      expect(ticked(tester, 'measurement-analytics'), isTrue);
      expect(ticked(tester, 'measurement-ads'), isFalse);
    });

    testWidgets('fits a small phone with large text', (tester) async {
      tester.view.physicalSize = const Size(640, 1136);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.6),
          ),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMeasurementConsentDialog(context),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Allow all'), findsOneWidget);
    });
  });

  group('maybeShowMeasurementPrompts', () {
    testWidgets('consent region: asks, and records the answer', (tester) async {
      final service = await tester.runAsync(() => serviceIn('DE'));
      await pumpHost(
          tester, (c) => maybeShowMeasurementPrompts(c, service: service));
      expect(find.text('Your privacy choices'), findsOneWidget);

      await tester.tap(find.text('Usage analytics'));
      await tester.pump();
      await tester.tap(find.text('Allow selected'));
      await tester.pumpAndSettle();

      expect(service!.choices.analytics, isTrue);
      expect(service.choices.ads, isFalse);
      expect(service.decision.value!.ask, MeasurementAsk.nothing);
    });

    testWidgets('elsewhere: shows the notice once; OK keeps it on',
        (tester) async {
      final service = await tester.runAsync(() => serviceIn('US'));
      await pumpHost(
          tester, (c) => maybeShowMeasurementPrompts(c, service: service));
      expect(find.text('How we measure our ads is changing'), findsOneWidget);
      expect(find.text('Your privacy choices'), findsNothing);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(service!.adsAllowed, isTrue);
      expect(service.choices.noticeShown, isTrue);

      // Not shown a second time.
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('How we measure our ads is changing'), findsNothing);
    });

    testWidgets('elsewhere: "Turn off" switches ads measurement off',
        (tester) async {
      final service = await tester.runAsync(() => serviceIn('KH'));
      await pumpHost(
          tester, (c) => maybeShowMeasurementPrompts(c, service: service));
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      expect(service!.adsAllowed, isFalse);
      expect(service.choices.ads, isFalse);
      expect(service.decision.value!.analytics, isTrue);
    });

    testWidgets('asks nothing when we cannot tell where the person is',
        (tester) async {
      final service = await tester.runAsync(() => serviceIn(null));
      await pumpHost(
          tester, (c) => maybeShowMeasurementPrompts(c, service: service));
      expect(find.byType(AlertDialog), findsNothing);
      expect(service!.adsAllowed, isFalse);
    });

    testWidgets('asks nothing once the person has chosen', (tester) async {
      final service = await tester.runAsync(() async {
        final s = await serviceIn('FR');
        await s.recordConsent(analytics: false, ads: false);
        return s;
      });
      await pumpHost(
          tester, (c) => maybeShowMeasurementPrompts(c, service: service));
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group("Apple's tracking question", () {
    Future<(MeasurementConsentService, _Sink)> adsOn() async {
      final service = await serviceIn('US');
      await service.acknowledgeNotice(keepOn: true);
      final sink = _Sink();
      service.addSink(sink);
      return (service, sink);
    }

    testWidgets('explains first, then asks, then tells the ad SDK',
        (tester) async {
      final (service, sink) = (await tester.runAsync(adsOn))!;
      final gateway = _Gateway(TrackingStatus.notDetermined);
      await pumpHost(
        tester,
        (c) =>
            maybeAskTrackingPermission(c, service: service, gateway: gateway),
      );
      expect(find.text('One more choice, from Apple'), findsOneWidget);
      expect(gateway.requests, 0, reason: 'not before the explanation');
      // One way forward, and it leads to the system prompt.
      expect(find.byType(TextButton), findsOneWidget); // the host's own
      expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(gateway.requests, 1);
      expect(sink.tracking, [true]);
    });

    testWidgets('a refusal is passed on as a refusal', (tester) async {
      final (service, sink) = (await tester.runAsync(adsOn))!;
      final gateway =
          _Gateway(TrackingStatus.notDetermined, answer: TrackingStatus.denied);
      await pumpHost(
        tester,
        (c) =>
            maybeAskTrackingPermission(c, service: service, gateway: gateway),
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(sink.tracking, [false]);
    });

    testWidgets('is not asked twice, nor where there is nothing to ask',
        (tester) async {
      final (service, _) = (await tester.runAsync(adsOn))!;
      for (final status in [
        TrackingStatus.authorized,
        TrackingStatus.denied,
        TrackingStatus.restricted,
        TrackingStatus.notSupported,
      ]) {
        final gateway = _Gateway(status);
        await pumpHost(
          tester,
          (c) =>
              maybeAskTrackingPermission(c, service: service, gateway: gateway),
        );
        expect(find.byType(AlertDialog), findsNothing, reason: status.name);
        expect(gateway.requests, 0, reason: status.name);
      }
    });

    testWidgets('is not asked while ads measurement is off', (tester) async {
      final service = await tester.runAsync(() => serviceIn('DE'));
      final gateway = _Gateway(TrackingStatus.notDetermined);
      await pumpHost(
        tester,
        (c) =>
            maybeAskTrackingPermission(c, service: service, gateway: gateway),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(gateway.requests, 0);
    });

    testWidgets('this build never asks: there is no permission to ask about',
        (tester) async {
      expect(await trackingPermission.status(), TrackingStatus.notSupported);
      final (service, _) = (await tester.runAsync(adsOn))!;
      await pumpHost(
          tester, (c) => maybeAskTrackingPermission(c, service: service));
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('the Settings switches', () {
    Future<void> pumpTiles(
        WidgetTester tester, MeasurementConsentService service) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MeasurementSettingsTiles(service: service),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    bool switchOn(WidgetTester tester, String key) =>
        tester.widget<SwitchListTile>(find.byKey(ValueKey(key))).value;

    testWidgets('show what is in force and move independently', (tester) async {
      final service = (await tester.runAsync(() async {
        final s = await serviceIn('US');
        await s.acknowledgeNotice(keepOn: true);
        return s;
      }))!;
      await pumpTiles(tester, service);
      expect(switchOn(tester, 'settings-usage-analytics'), isTrue);
      expect(switchOn(tester, 'settings-ads-measurement'), isTrue);

      await tester.tap(find.text('Ads measurement'));
      await tester.pumpAndSettle();
      expect(switchOn(tester, 'settings-ads-measurement'), isFalse);
      expect(switchOn(tester, 'settings-usage-analytics'), isTrue);
      expect(service.adsAllowed, isFalse);
      expect(service.choices.ads, isFalse);

      await tester.tap(find.text('Usage analytics'));
      await tester.pumpAndSettle();
      expect(switchOn(tester, 'settings-usage-analytics'), isFalse);
      expect(service.choices.analytics, isFalse);
    });

    testWidgets('are both off for someone in Europe who has not answered',
        (tester) async {
      final service = (await tester.runAsync(() => serviceIn('ES')))!;
      await pumpTiles(tester, service);
      expect(switchOn(tester, 'settings-usage-analytics'), isFalse);
      expect(switchOn(tester, 'settings-ads-measurement'), isFalse);

      // Switching one on here is an opt-in for that purpose alone.
      await tester.tap(find.text('Usage analytics'));
      await tester.pumpAndSettle();
      expect(service.choices.analytics, isTrue);
      expect(service.choices.ads, isNull);
      expect(service.adsAllowed, isFalse);
    });

    testWidgets('on an iPhone, point to where tracking permission lives',
        (tester) async {
      final service = (await tester.runAsync(() => serviceIn('US')))!;
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        await pumpTiles(tester, service);
        final note = find.text('Tracking permission is managed by iOS.');
        final link = find.widgetWithText(TextButton, 'Open iOS Settings');
        final matcher =
            platform == TargetPlatform.iOS ? findsOneWidget : findsNothing;
        expect(note, matcher, reason: platform.name);
        expect(link, matcher, reason: platform.name);
        await tester.pumpWidget(const SizedBox());
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
