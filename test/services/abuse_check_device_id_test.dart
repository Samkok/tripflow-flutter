import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/abuse_check_device_id.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(deviceChannel, null));

  group('on Android', () {
    test('is the Android ID the native side reports', () async {
      answer((_) => 'a1b2c3d4e5f60718');
      expect(await abuseCheckDeviceId(isAndroid: true), 'a1b2c3d4e5f60718');
      expect(calls.single.method, 'androidId');
    });

    test('is nothing when the native side has nothing', () async {
      answer((_) => null);
      expect(await abuseCheckDeviceId(isAndroid: true), isNull);
      answer((_) => '');
      expect(await abuseCheckDeviceId(isAndroid: true), isNull);
    });

    test('is nothing, not an error, without the bridge or when it fails',
        () async {
      expect(await abuseCheckDeviceId(isAndroid: true), isNull);
      answer((_) => throw PlatformException(code: 'boom'));
      expect(await abuseCheckDeviceId(isAndroid: true), isNull);
    });
  });

  test('elsewhere there is no identifier', () async {
    answer((_) => 'never asked');
    expect(await abuseCheckDeviceId(isAndroid: false, isIOS: false), isNull);
    expect(calls, isEmpty);
  });
}
