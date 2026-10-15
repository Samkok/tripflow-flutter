import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The minute hand behind the pins' opening-hours status. The map screen
/// advances it once a minute while it is on screen and in the foreground
/// (see `_MapScreenState._startPinClock`), and sets it to now on its
/// refresh button and when the app returns to the foreground — nothing
/// ticks while the map is away. A tick re-derives each pin's status; only
/// pins whose text changed rasterize again (the bitmaps are cached by
/// their text), so a tick costs a marker-set reassembly, not a redraw of
/// the map.
final pinClockProvider = StateProvider<DateTime>((_) => DateTime.now());
