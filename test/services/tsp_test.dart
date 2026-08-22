import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/day_distribution/tsp.dart';

double _pathLen(List<List<double>> d, List<int> order) {
  var s = 0.0;
  for (var i = 1; i < order.length; i++) {
    s += d[order[i - 1]][order[i]];
  }
  return s;
}

/// Brute-force optimum for small n.
double _bruteBest(List<List<double>> d, {int? start, int? end}) {
  final n = d.length;
  final idx = List.generate(n, (i) => i);
  var best = double.infinity;
  void permute(List<int> current, List<int> rest) {
    if (rest.isEmpty) {
      if (start != null && current.first != start) return;
      if (end != null && current.last != end) return;
      best = math.min(best, _pathLen(d, current));
      return;
    }
    for (var i = 0; i < rest.length; i++) {
      permute([...current, rest[i]],
          [...rest.sublist(0, i), ...rest.sublist(i + 1)]);
    }
  }

  permute([], idx);
  return best;
}

List<List<double>> _randomMatrix(int n, math.Random rng) {
  final pts = List.generate(
      n, (_) => (rng.nextDouble() * 100, rng.nextDouble() * 100));
  return [
    for (final a in pts)
      [
        for (final b in pts)
          math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2))
      ]
  ];
}

void main() {
  test('Held-Karp equals brute force on random matrices (n≤8)', () {
    final rng = math.Random(42);
    for (var n = 2; n <= 8; n++) {
      for (var trial = 0; trial < 5; trial++) {
        final d = _randomMatrix(n, rng);
        final order = shortestHamiltonianPath(d);
        expect(order.toSet(), List.generate(n, (i) => i).toSet(),
            reason: 'visits every node exactly once');
        expect(_pathLen(d, order), closeTo(_bruteBest(d), 1e-9),
            reason: 'n=$n trial=$trial must be optimal');
      }
    }
  });

  test('fixed start and end are honored and still optimal', () {
    final rng = math.Random(7);
    final d = _randomMatrix(6, rng);
    final order = shortestHamiltonianPath(d, start: 2, end: 5);
    expect(order.first, 2);
    expect(order.last, 5);
    expect(_pathLen(d, order), closeTo(_bruteBest(d, start: 2, end: 5), 1e-9));
  });

  test('degenerate sizes', () {
    expect(shortestHamiltonianPath(const []), isEmpty);
    expect(shortestHamiltonianPath(const [[0.0]]), [0]);
  });

  test('large n falls back to NN+2-opt and still visits everything', () {
    final rng = math.Random(3);
    final d = _randomMatrix(15, rng);
    final order = shortestHamiltonianPath(d, start: 0);
    expect(order.length, 15);
    expect(order.toSet().length, 15);
    expect(order.first, 0);
  });
}
