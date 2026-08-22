/// Exact shortest Hamiltonian PATH solver (visit every node once, free or
/// pinned endpoints, no return) for the city-ordering step. Pure Dart.
///
/// Held-Karp dynamic programming: O(2^n · n²). Exact for n ≤
/// [kExactTspMaxClusters] (≈6·10⁵ ops at 12); beyond that (pathological
/// trips) a nearest-neighbor construction + 2-opt improvement is used.
///
/// This is deliberately NOT a cycle (TSP) solver: a trip visits its cities
/// once and ends wherever the last one is — forcing a return-to-start
/// order was exactly the old optimizer's mistake at day scale.
library;

/// Returns the visiting order (indices into [d]) minimizing total path
/// length. [d] must be a full symmetric matrix. [start]/[end] pin the
/// first/last node when non-null. Ties break toward lower indices so the
/// result is deterministic for equal inputs.
List<int> shortestHamiltonianPath(
  List<List<double>> d, {
  int? start,
  int? end,
}) {
  final n = d.length;
  if (n == 0) return const [];
  if (n == 1) return const [0];

  if (n <= 12) return _heldKarp(d, start: start, end: end);
  return _nnTwoOpt(d, start: start, end: end);
}

List<int> _heldKarp(List<List<double>> d, {int? start, int? end}) {
  final n = d.length;
  final full = 1 << n;
  const inf = double.infinity;

  // dp[mask][j] = cheapest path visiting exactly `mask`, ending at j.
  final dp = List.generate(full, (_) => List.filled(n, inf));
  final parent = List.generate(full, (_) => List.filled(n, -1));

  for (var j = 0; j < n; j++) {
    if (start == null || j == start) dp[1 << j][j] = 0;
  }

  for (var mask = 1; mask < full; mask++) {
    for (var j = 0; j < n; j++) {
      final cost = dp[mask][j];
      if (cost == inf || (mask & (1 << j)) == 0) continue;
      for (var k = 0; k < n; k++) {
        if ((mask & (1 << k)) != 0) continue;
        final next = mask | (1 << k);
        final cand = cost + d[j][k];
        if (cand < dp[next][k]) {
          dp[next][k] = cand;
          parent[next][k] = j;
        }
      }
    }
  }

  // Pick the best terminal state.
  var bestEnd = -1;
  var best = inf;
  final fullMask = full - 1;
  for (var j = 0; j < n; j++) {
    if (end != null && j != end) continue;
    if (dp[fullMask][j] < best) {
      best = dp[fullMask][j];
      bestEnd = j;
    }
  }
  // Unreachable only if constraints contradict (start == end with n > 1);
  // fall back to index order rather than crash.
  if (bestEnd == -1) return [for (var i = 0; i < n; i++) i];

  final order = <int>[];
  var mask = fullMask;
  var j = bestEnd;
  while (j != -1) {
    order.add(j);
    final p = parent[mask][j];
    mask &= ~(1 << j);
    j = p;
  }
  return order.reversed.toList();
}

List<int> _nnTwoOpt(List<List<double>> d, {int? start, int? end}) {
  final n = d.length;
  final visited = List.filled(n, false);
  final order = <int>[];
  var current = start ?? 0;
  order.add(current);
  visited[current] = true;
  if (end != null) visited[end] = true; // reserve; appended last

  while (order.length < n - (end != null ? 1 : 0)) {
    var bestNext = -1;
    var best = double.infinity;
    for (var k = 0; k < n; k++) {
      if (visited[k]) continue;
      if (d[current][k] < best) {
        best = d[current][k];
        bestNext = k;
      }
    }
    if (bestNext == -1) break;
    order.add(bestNext);
    visited[bestNext] = true;
    current = bestNext;
  }
  if (end != null) order.add(end);

  // 2-opt: reverse segments while it shortens the path. Endpoints stay
  // pinned when constrained.
  double len(List<int> o) {
    var s = 0.0;
    for (var i = 1; i < o.length; i++) {
      s += d[o[i - 1]][o[i]];
    }
    return s;
  }

  var improved = true;
  var bestLen = len(order);
  final lo = start != null ? 1 : 0;
  final hi = end != null ? order.length - 2 : order.length - 1;
  while (improved) {
    improved = false;
    for (var i = lo; i < hi; i++) {
      for (var k = i + 1; k <= hi; k++) {
        final candidate = [
          ...order.sublist(0, i),
          ...order.sublist(i, k + 1).reversed,
          ...order.sublist(k + 1),
        ];
        final l = len(candidate);
        if (l + 1e-9 < bestLen) {
          order
            ..clear()
            ..addAll(candidate);
          bestLen = l;
          improved = true;
        }
      }
    }
  }
  return order;
}
