/// Marker ids that change with their bitmap.
///
/// Google Maps on iOS mis-renders a marker whose icon is replaced in place
/// by a bitmap of another size: the new image is drawn into the old
/// image's slot and comes out clipped — a pin showing only a slice of its
/// name ("CHAGEE (Ma"), a route chip reduced to "min ›". Pins now change
/// bitmaps as their opening-hours line ticks, so an in-place update is an
/// everyday event. Keying the marker id by the bitmap instance turns every
/// icon change into a remove + add, which the SDK draws correctly.
///
/// Everything that reads a location id out of a marker id goes through
/// [baseMarkerId].
String versionedMarkerId(String base, Object bitmap) =>
    '$base|${identityHashCode(bitmap)}';

/// The id without its bitmap version — the location id, the chip id, etc.
String baseMarkerId(String markerId) {
  final i = markerId.indexOf('|');
  return i < 0 ? markerId : markerId.substring(0, i);
}
