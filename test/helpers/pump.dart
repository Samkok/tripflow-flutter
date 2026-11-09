// Pumping helpers shared by the widget tests.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

Future<void>? _fonts;

/// Loads the app's Roboto for every family the themes may name, so an
/// exported picture shows letterforms instead of the test font's boxes.
/// Memoised; cheap to call from every test that might export.
Future<void> loadAppFonts() => _fonts ??= () async {
      final weights = <String, Uint8List>{
        for (final w in ['Regular', 'Medium', 'Bold'])
          w: File('assets/fonts/Roboto-$w.ttf').readAsBytesSync(),
      };
      for (final family in [
        'Roboto',
        'monospace',
        '.SF UI Text',
        '.SF UI Display',
      ]) {
        final loader = FontLoader(family);
        for (final bytes in weights.values) {
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
        }
        await loader.load();
      }
      // The icon font ships with the SDK, next to the test runner binary
      // (<sdk>/bin/cache/artifacts/...). Best effort: boxes if absent.
      final cache = File(Platform.resolvedExecutable)
          .parent // darwin-x64 (or linux-x64)
          .parent // engine
          .parent; // artifacts
      final icons =
          File('${cache.path}/material_fonts/MaterialIcons-Regular.otf');
      if (icons.existsSync()) {
        final loader = FontLoader('MaterialIcons')
          ..addFont(
              Future.value(ByteData.sublistView(icons.readAsBytesSync())));
        await loader.load();
      }
    }();

/// Gives the test a fresh in-memory SharedPreferences and seeds the app's
/// synchronous cache with it, so widgets that read prefs in `build` work.
Future<SharedPreferences> useMockPrefs(
    [Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(Map.of(initial));
  final prefs = await SharedPreferences.getInstance();
  SharedPrefsCache.debugSetInstance(prefs);
  return prefs;
}

/// Pumps [child] inside a themed [MaterialApp] under a [ProviderContainer]
/// built from [overrides], at a phone-sized view. Returns the container so
/// the test can read providers. Pass [boundaryKey] to wrap the whole app in
/// a [RepaintBoundary] for `exportShot`.
Future<ProviderContainer> pumpVoyza(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  ThemeData? theme,
  Size physicalSize = const Size(1170, 2532),
  double devicePixelRatio = 3,
  bool scaffold = true,
  GlobalKey? boundaryKey,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);

  final base = theme ?? AppTheme.darkTheme;
  Widget app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
    ),
    home: scaffold ? Scaffold(body: child) : child,
  );
  if (boundaryKey != null) {
    app = RepaintBoundary(key: boundaryKey, child: app);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: app),
  );
  return container;
}
