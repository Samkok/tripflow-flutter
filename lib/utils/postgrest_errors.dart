/// Helpers for reading PostgREST error messages.
library;

final RegExp _unknownColumn =
    RegExp(r"""Could not find the '([^']+)' column""", caseSensitive: false);

/// PostgREST code for "the request names a column the schema cache doesn't
/// have" — what an app build gets when it runs ahead of its migration.
const String postgrestUnknownColumnCode = 'PGRST204';

/// The column PostgREST rejected in a PGRST204 message
/// ("Could not find the 'place_types' column of 'locations' in the schema
/// cache"), or null when the message has another shape.
String? unknownColumnFromPostgrestMessage(String? message) {
  if (message == null) return null;
  final match = _unknownColumn.firstMatch(message);
  final column = match?.group(1)?.trim();
  return column == null || column.isEmpty ? null : column;
}
