import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_drive/stridelabs_drive.dart';

void main() {
  // These helpers write straight to `debugPrint`; capture it so we can assert on
  // the exact greppable MSTATE/MRESULT lines the driving harness depends on.
  late List<String?> captured;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    captured = <String?>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => captured.add(message);
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  group('logDriveState', () {
    test('emits MSTATE only when the state changes (dedup)', () {
      logDriveState('a-unique-1');
      logDriveState('a-unique-1'); // duplicate — suppressed
      logDriveState('a-unique-2');

      expect(captured, ['MSTATE a-unique-1', 'MSTATE a-unique-2']);
    });
  });

  group('logDriveResult', () {
    test('formats an ok result', () {
      logDriveResult('save', ok: true);
      expect(captured, ['MRESULT save ok']);
    });

    test('formats an error result with the error appended', () {
      logDriveResult('save', ok: false, error: 'boom');
      expect(captured, ['MRESULT save error=boom']);
    });
  });
}
