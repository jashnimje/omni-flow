import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  const renderer = TemplateRenderer();

  group('typed substitution', () {
    test('a whole-string placeholder keeps the value type', () {
      final out = renderer.render({
        'state': '{{value}}',
        'dimming': '{{level}}',
      }, const TemplateContext(params: {'value': true, 'level': 80}));
      expect(out, {'state': true, 'dimming': 80});
    });

    test('an embedded placeholder is interpolated as text', () {
      final out = renderer.render(
        'set volume output volume {{value}}',
        const TemplateContext(params: {'value': 45}),
      );
      expect(out, 'set volume output volume 45');
    });

    test('lists and nested maps are walked', () {
      final out = renderer.render({
        'params': {
          'rgb': ['{{r}}', '{{g}}', '{{b}}'],
        },
      }, const TemplateContext(params: {'r': 255, 'g': 0, 'b': 10}));
      expect(out, {
        'params': {
          'rgb': [255, 0, 10],
        },
      });
    });

    test('values without placeholders pass through unchanged', () {
      expect(
        renderer.render({
          'id': 1,
          'on': true,
          'x': null,
        }, const TemplateContext()),
        {'id': 1, 'on': true, 'x': null},
      );
    });
  });

  group('lookup order and fallbacks', () {
    test('params win over state for a bare name', () {
      final out = renderer.render(
        '{{brightness|state.brightness|100}}',
        const TemplateContext(
          params: {'brightness': 80},
          state: {'brightness': 30},
        ),
      );
      expect(out, 80);
    });

    test('falls back to state, then to the literal', () {
      expect(
        renderer.render(
          '{{brightness|state.brightness|100}}',
          const TemplateContext(state: {'brightness': 30}),
        ),
        30,
      );
      expect(
        renderer.render(
          '{{brightness|state.brightness|100}}',
          const TemplateContext(),
        ),
        100,
      );
    });

    test('a bare name reads params only, never state', () {
      expect(
        () => renderer.render(
          '{{temp}}',
          const TemplateContext(state: {'temp': 2700}),
        ),
        throwsA(isA<TemplateException>()),
      );
    });

    test('prefixed roots read their own maps', () {
      final ctx = const TemplateContext(
        device: {'ip': '10.0.0.5'},
        msg: {
          'payload': {'uid': '04:A1'},
        },
        globals: {'HomeMode': 'away'},
        flowVars: {'count': 3},
      );
      expect(renderer.render('{{device.ip}}', ctx), '10.0.0.5');
      expect(renderer.render('{{msg.payload.uid}}', ctx), '04:A1');
      expect(renderer.render(r'{{$HomeMode}}', ctx), 'away');
      expect(renderer.render('{{%count}}', ctx), 3);
    });

    test(
      'quoted string literals and booleans are allowed as the last term',
      () {
        expect(
          renderer.render("{{mode|'auto'}}", const TemplateContext()),
          'auto',
        );
        expect(
          renderer.render('{{flag|false}}', const TemplateContext()),
          false,
        );
      },
    );

    test('a null value counts as missing and falls through', () {
      expect(
        renderer.render(
          '{{value|7}}',
          const TemplateContext(params: {'value': null}),
        ),
        7,
      );
    });
  });

  group('errors', () {
    test('an unresolved placeholder with no fallback throws', () {
      expect(
        () => renderer.render('{{missing}}', const TemplateContext()),
        throwsA(isA<TemplateException>()),
      );
    });

    test('a literal before the last alternative is rejected', () {
      expect(
        () => parsePlaceholder('100|value'),
        throwsA(isA<TemplateException>()),
      );
    });

    test('a malformed term is rejected', () {
      expect(() => parsePlaceholder('a b'), throwsA(isA<TemplateException>()));
      expect(() => parsePlaceholder('a||b'), throwsA(isA<TemplateException>()));
    });
  });

  test('renderText turns a typed value into text', () {
    expect(
      renderer.renderText(
        '{{value}}',
        const TemplateContext(params: {'value': 3}),
      ),
      '3',
    );
  });

  test('placeholdersIn lists every placeholder and its paths', () {
    final found = placeholdersIn({
      'a': '{{value}}',
      'b': ['x {{r}} y', '{{brightness|state.brightness|100}}'],
    });
    expect(found.map((p) => p.source), [
      'value',
      'r',
      'brightness|state.brightness|100',
    ]);
    expect(found.last.paths, ['brightness', 'state.brightness']);
  });
}
