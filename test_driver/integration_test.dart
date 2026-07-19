import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host-side driver for the QA integration tests. Saves every screenshot the
/// test takes to build/qa_shots/<name>.png so the run can be reviewed
/// visually afterwards.
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes,
          [Map<String, Object?>? args]) async {
        final file = File('build/qa_shots/$name.png')
          ..createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        return true;
      },
    );
