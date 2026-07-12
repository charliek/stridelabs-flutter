import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_logging/stridelabs_logging.dart';

void main() {
  late List<String?> captured;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    captured = <String?>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    logSink = null;
  });

  test('prefixes the message with the [area] tag', () {
    log('auth', 'signed in');
    expect(captured, ['[auth] signed in']);
  });

  test('fans out to logSink when one is set', () {
    final seen = <String>[];
    logSink = (area, message) => seen.add('$area/$message');

    log('api', 'GET /feeds');

    expect(captured, ['[api] GET /feeds']);
    expect(seen, ['api/GET /feeds']);
  });
}
