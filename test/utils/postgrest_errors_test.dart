import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/postgrest_errors.dart';

void main() {
  test('reads the rejected column out of a PGRST204 message', () {
    expect(
      unknownColumnFromPostgrestMessage(
          "Could not find the 'place_types' column of 'locations' in the schema cache"),
      'place_types',
    );
    expect(
      unknownColumnFromPostgrestMessage(
          "could not find the 'tag' column of 'locations' in the schema cache"),
      'tag',
    );
  });

  test('returns null for other messages', () {
    expect(unknownColumnFromPostgrestMessage(null), isNull);
    expect(unknownColumnFromPostgrestMessage(''), isNull);
    expect(
        unknownColumnFromPostgrestMessage(
            'new row violates row-level security policy for table "locations"'),
        isNull);
    expect(unknownColumnFromPostgrestMessage("Could not find the '' column"),
        isNull);
  });
}
