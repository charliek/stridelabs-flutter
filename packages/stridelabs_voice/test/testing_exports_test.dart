import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// The names are used below, so a name the export list drops stops compiling.
import 'package:stridelabs_voice/testing.dart';
import 'package:stridelabs_voice/wav_mic.dart';

/// `testing.dart` and `wav_mic.dart` are public entry points (D1 §8.4): what
/// they export is a contract, so it is pinned to the design's list, name for
/// name. The scan reads the library files themselves (package tests run from
/// the package root).
void main() {
  // D1 §8.4's `package:stridelabs_voice/testing.dart`.
  const testingNames = {
    'FakeMicCapture',
    'FakeRelayChannel',
    'RelayAttempt',
    'FakeRelayServer',
    'isSilence',
    'kFakeMp3',
    'FakeTtsCall',
    'FakeReplyTts',
    'FakeTtsAuth',
    'FakeReplyPlayer',
    'FakeClipFiles',
    'FakeVoiceTransport',
    'MvoiceLine',
  };
  // D1 §8.4's `package:stridelabs_voice/wav_mic.dart`.
  const wavMicNames = {
    'WavMicCapture',
    'WavPcm',
    'WavMicProblem',
    'WavMicException',
  };

  test('testing.dart exports exactly the names of D1 §8.4', () {
    final exported = _exportedNames(File('lib/testing.dart'));
    expect(exported.unshown, isEmpty, reason: 'every export has a show list');
    expect(exported.names.toSet(), testingNames);
    expect(
      exported.names,
      hasLength(testingNames.length),
      reason: 'no repeats',
    );
    // Each shown name is declared at the top level of its file.
    for (final MapEntry(key: path, value: shown) in exported.byFile.entries) {
      final declared = _declaredNames(File('lib/$path'));
      expect(declared, containsAll(shown), reason: path);
    }
  });

  test('wav_mic.dart exports exactly the names of D1 §8.4', () {
    final exported = _exportedNames(File('lib/wav_mic.dart'));
    // It exports its one file whole: what that declares is the contract.
    expect(exported.byFile.keys, isEmpty);
    expect(exported.unshown, ['src/transport/wav_mic_capture.dart']);
    final declared = _declaredNames(
      File('lib/src/transport/wav_mic_capture.dart'),
    );
    expect(declared, wavMicNames);
  });

  test('the names resolve, and are the types the design declares', () {
    final types = <Type>[
      FakeMicCapture,
      FakeRelayChannel,
      FakeRelayServer,
      FakeTtsCall,
      FakeReplyTts,
      FakeTtsAuth,
      FakeReplyPlayer,
      FakeClipFiles,
      FakeVoiceTransport,
      MvoiceLine,
      WavMicCapture,
      WavPcm,
      WavMicProblem,
      WavMicException,
    ];
    expect(types.toSet(), hasLength(types.length));
    // A typedef, a function and a constant.
    const RelayAttempt? attempt = null;
    expect(attempt, isNull);
    expect(isSilence, isA<Function>());
    expect(kFakeMp3, isNotEmpty);
  });

  test('the main library exports neither entry point', () {
    final exported = _exportedNames(File('lib/stridelabs_voice.dart'));
    for (final path in [...exported.unshown, ...exported.byFile.keys]) {
      expect(path, isNot(contains('testing')));
      expect(path, isNot(contains('wav_mic')));
    }
    expect(exported.unshown, isNotEmpty, reason: 'the scan reads the exports');
  });
}

/// The `export '<path>' [show A, B];` statements of [file], paths relative
/// to `lib/`.
({List<String> names, Map<String, List<String>> byFile, List<String> unshown})
_exportedNames(File file) {
  final source = file.readAsStringSync();
  final names = <String>[];
  final byFile = <String, List<String>>{};
  final unshown = <String>[];
  final export = RegExp(
    r"^export '([^']+)'(?:\s+show\s+([^;]+))?;",
    multiLine: true,
  );
  for (final match in export.allMatches(source)) {
    final path = match.group(1)!;
    final show = match.group(2);
    if (show == null) {
      unshown.add(path);
      continue;
    }
    final shown = [for (final n in show.split(',')) n.trim()];
    names.addAll(shown);
    byFile[path] = shown;
  }
  return (names: names, byFile: byFile, unshown: unshown);
}

/// The public top-level names [file] declares: classes, enums, typedefs,
/// constants, variables and functions.
Set<String> _declaredNames(File file) {
  final source = file.readAsStringSync();
  final names = <String>{};
  final type = RegExp(
    r'^(?:abstract |final |sealed |base |interface )*(?:class|enum|mixin|typedef|extension type) (\w+)',
    multiLine: true,
  );
  for (final m in type.allMatches(source)) {
    names.add(m.group(1)!);
  }
  // `const List<int> kFakeMp3 = …`, `bool isSilence(…) =>`, `int helper() {`.
  final value = RegExp(
    r'^(?:const |final )?[A-Za-z_][\w<>,? ()]*? (\w+)\s*(?:=|\(|;)',
    multiLine: true,
  );
  for (final m in value.allMatches(source)) {
    final name = m.group(1)!;
    if (!name.startsWith('_') && !_keywords.contains(name)) names.add(name);
  }
  return {
    for (final n in names)
      if (!n.startsWith('_')) n,
  };
}

const _keywords = {'class', 'enum', 'typedef', 'import', 'export', 'library'};
