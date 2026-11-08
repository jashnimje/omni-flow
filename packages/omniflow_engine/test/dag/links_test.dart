import 'package:omniflow_engine/omniflow_engine.dart';
import 'package:test/test.dart';

void main() {
  const relay = CapabilitySpec(
    id: 'relay',
    type: CapabilityType.toggle,
    label: 'relay',
    params: {'value': ParamSpec(type: ParamType.boolean)},
    command: {'cmd': 'relay'},
    stateJsonPath: r'$.relay',
  );

  LinkRequest link(
    String from,
    String to, {
    LinkMode mode = LinkMode.threshold,
    num? above,
    num? below,
    Object? set,
  }) => LinkRequest(
    from: LinkEnd.parse(from, 'from'),
    to: LinkEnd.parse(to, 'to'),
    mode: mode,
    target: relay,
    above: above,
    below: below,
    set: set,
  );

  test('the two halves of a hysteresis pair are two links', () {
    final on = link('desk.light', 'hall.relay', below: 30, set: true);
    final off = link('desk.light', 'hall.relay', above: 60, set: false);
    expect(on.id, isNot(off.id));
    expect(on.toFlow()['id'], on.id);
  });

  test('ends that only differ in where the underscore sits do not collide', () {
    final a = link('desk.button_a', 'lamp.relay', mode: LinkMode.toggle);
    final b = link('desk_button.a', 'lamp.relay', mode: LinkMode.toggle);
    expect(a.id, isNot(b.id));
    expect(a.id, matches(RegExp(r'^link_[0-9a-f]{12}$')));
  });

  test('the same link always gets the same id', () {
    expect(
      link('desk.light', 'hall.relay', below: 30, set: true).id,
      link('desk.light', 'hall.relay', below: 30, set: true).id,
    );
  });

  test('a follow into a whole-number param rounds the scaled value', () {
    const dimmer = CapabilitySpec(
      id: 'dimmer',
      type: CapabilityType.level,
      label: 'dimmer',
      params: {
        'value': ParamSpec(
          type: ParamType.number,
          min: 10,
          max: 100,
          integer: true,
        ),
      },
      command: {'cmd': 'dim'},
    );
    final flow = LinkRequest(
      from: LinkEnd.parse('desk.knob', 'from'),
      to: LinkEnd.parse('lamp.dimmer', 'to'),
      mode: LinkMode.follow,
      target: dimmer,
    ).toFlow();
    final scale = (flow['nodes'] as List).cast<Map>().firstWhere(
      (n) => n['type'] == 'range_map',
    );
    final config = Map<String, Object?>.from(scale['config'] as Map);
    expect(config['round'], isTrue);
    expect(rangeMap(59, config), 63);
    expect(rangeMap(59, {...config, 'round': false}), closeTo(63.1, 1e-9));
  });
}
