import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/places_service.dart';

void main() {
  test('keeps references in order with their attributions and size', () {
    final parsed = parsePlacePhotos([
      {
        'photo_reference': 'a',
        'width': 4032,
        'height': 3024.0,
        'html_attributions': ['<a>One</a>'],
      },
      {
        'photo_reference': 'b',
        'html_attributions': ['<a>Two</a>', '<a>Three</a>'],
      },
    ]);
    expect(parsed.references, ['a', 'b']);
    expect(parsed.coverReference, 'a');
    expect(parsed.attributions, ['<a>One</a>', '<a>Two</a>', '<a>Three</a>']);
    expect(parsed.width, 4032);
    expect(parsed.height, 3024);
  });

  test('drops entries without a usable reference, with their attributions', () {
    final parsed = parsePlacePhotos([
      {
        'html_attributions': ['<a>Orphan</a>']
      },
      {'photo_reference': ''},
      'garbage',
      {'photo_reference': 'ok'},
    ]);
    expect(parsed.references, ['ok']);
    expect(parsed.attributions, isEmpty);
    expect(parsed.attributionsOrNull, isNull);
  });

  test('tolerates a missing or malformed array', () {
    expect(parsePlacePhotos(null).references, isEmpty);
    expect(parsePlacePhotos('nope').coverReference, isNull);
    expect(parsePlacePhotos(<dynamic>[]).width, isNull);
  });
}
