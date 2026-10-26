// LoopbackWebAuth's default landing page for the accepted callback.

import 'package:flutter_test/flutter_test.dart';
import 'package:stridelabs_slauth/stridelabs_slauth.dart';

void main() {
  final page = defaultLandingPageHtml;
  final lower = page.toLowerCase();

  test('asks the user to return to the app, and says nothing about success', () {
    expect(
      page,
      contains(
        '<p>Return to the app to finish signing in. You can close this tab.</p>',
      ),
    );
    expect(lower, isNot(contains('signed in')));
    expect(lower, isNot(contains('success')));
  });

  test('is a UTF-8 HTML document with a data: icon', () {
    expect(lower, startsWith('<!doctype html>'));
    expect(page, contains('<meta charset="utf-8">'));
    expect(page, contains('<link rel="icon" href="data:,">'));
  });

  test('has no script in any form', () {
    expect(lower, isNot(contains('<script')));
    expect(lower, isNot(contains('javascript:')));
    // No inline event handlers (onload=, onclick=, ...).
    expect(RegExp(r'\son[a-z]+\s*=').hasMatch(lower), isFalse);
    // No history.replaceState, by choice (the page's doc says why).
    expect(page, isNot(contains('replaceState')));
    expect(page, isNot(contains('history')));
  });

  test('loads no external resource: every src/href is a data: URI', () {
    final references = RegExp(
      r'''\b(?:src|href|srcset|action|poster|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    ).allMatches(lower).map((m) => m[1] ?? m[2] ?? m[3]!).toList();
    expect(references, isNotEmpty); // the icon
    for (final reference in references) {
      expect(reference, startsWith('data:'), reason: reference);
    }
    // Nor through CSS, a refresh or an embedded document.
    expect(lower, isNot(contains('url(')));
    expect(lower, isNot(contains('@import')));
    expect(lower, isNot(contains('http-equiv')));
    for (final tag in ['<iframe', '<object', '<embed', '<img', '<form']) {
      expect(lower, isNot(contains(tag)), reason: tag);
    }
    final links = RegExp(r'<link\b[^>]*>').allMatches(lower).toList();
    expect(links.map((m) => m[0]), ['<link rel="icon" href="data:,">']);
  });

  test('echoes nothing: it has no placeholder for the query', () {
    for (final marker in [r'${', '{{', '%s', 'code=', 'state=']) {
      expect(page, isNot(contains(marker)), reason: marker);
    }
  });
}
