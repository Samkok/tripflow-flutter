import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/all_days_route_provider.dart';
import 'package:voyza/utils/day_visibility.dart';
import 'package:voyza/widgets/day_legend.dart';

/// The legend lives in the map's top chrome, whose Stack is only as tall as
/// the free-places chip and the refresh button. A Positioned legend painted
/// past that box but could not be tapped there — the lower rows were dead.
/// These tests build the same shape of tree and tap the LAST row.
void main() {
  final days = [for (var i = 0; i < 8; i++) DateTime(2026, 10, 5 + i)];

  ProviderContainer container() => ProviderContainer(overrides: [
        allDaysModeProvider.overrideWith((ref) => true),
        tripDayLegendProvider.overrideWith((ref) {
          final hidden =
              effectiveHiddenDays(ref.watch(hiddenTripDaysProvider), days);
          return [
            for (var i = 0; i < days.length; i++)
              DayLegendEntry(
                day: days[i],
                number: i + 1,
                color: kDayRouteColors[i],
                label: 'Day ${i + 1}',
                stops: 3,
                visible: !hidden.contains(days[i]),
              ),
          ];
        }),
      ]);

  /// The chrome as the map screen lays it out: a short Stack (the chip +
  /// refresh column stands in as a 106 px box) with the legend beside it.
  Widget chrome(ProviderContainer c, {required bool inFlow}) {
    return UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                top: 50,
                left: 16,
                right: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const SizedBox(height: 106, width: double.infinity),
                        if (inFlow)
                          const DayLegend()
                        else
                          const Positioned(left: 0, top: 0, child: DayLegend()),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('every row is tappable, including the last one', (tester) async {
    final c = container();
    addTearDown(c.dispose);
    await tester.pumpWidget(chrome(c, inFlow: true));

    await tester.tap(find.text('Day 8'));
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), {days[7]});

    // Tapping it again shows it.
    await tester.tap(find.text('Day 8'));
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), isEmpty);
  });

  testWidgets('holding a row shows only that day; Show all restores',
      (tester) async {
    final c = container();
    addTearDown(c.dispose);
    await tester.pumpWidget(chrome(c, inFlow: true));

    await tester.longPress(find.text('Day 6'));
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), {...days}..remove(days[5]));
    expect(find.text('Days · 1 of 8'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), isEmpty);
    expect(find.text('Days'), findsOneWidget);
  });

  testWidgets('the last visible day cannot be hidden — it shows all instead',
      (tester) async {
    final c = container();
    addTearDown(c.dispose);
    await tester.pumpWidget(chrome(c, inFlow: true));

    await tester.longPress(find.text('Day 2'));
    await tester.pump();
    await tester.tap(find.text('Day 2'));
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), isEmpty);
  });

  testWidgets('regression: a Positioned legend has dead rows', (tester) async {
    // Documents the bug the in-flow layout fixes: the same tap on the last
    // row lands outside the Stack's box and changes nothing.
    final c = container();
    addTearDown(c.dispose);
    await tester.pumpWidget(chrome(c, inFlow: false));

    await tester.tap(find.text('Day 8'), warnIfMissed: false);
    await tester.pump();
    expect(c.read(hiddenTripDaysProvider), isEmpty);
  });
}
