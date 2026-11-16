import '../../api/plain_error.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/engine_calls.dart';
import '../../state/providers.dart';
import '../design/design.dart';
import 'board_page.dart' show saveBoardPins;
import 'board_pins.dart';

/// 5.2 Add a pin: a name, what is wired to it in plain words, the GPIO grid
/// with only the pins that can do that job enabled, used pins marked and
/// boot pins warned, then the role's options. Pops the save's
/// [PinsSaved] when it worked.
class AddPinPage extends ConsumerStatefulWidget {
  const AddPinPage({super.key, required this.id});

  /// The board device.
  final String id;

  @override
  ConsumerState<AddPinPage> createState() => _AddPinPageState();
}

class _AddPinPageState extends ConsumerState<AddPinPage> {
  final _name = TextEditingController();
  final _typed = TextEditingController();
  var _role = PinRole.button;
  var _toGround = true;
  var _activeLow = false;
  int? _picked;
  Reply<BoardInfo>? _info;
  ApiFailure? _refused;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_describe());
  }

  @override
  void dispose() {
    _name.dispose();
    _typed.dispose();
    super.dispose();
  }

  Future<void> _describe() async {
    final reply = await EngineApi(ref.read(engineClientProvider))
        .boardDescribe(widget.id);
    if (mounted) setState(() => _info = reply);
  }

  Json? get _device => ref
      .watch(devicesProvider)
      .value
      ?.where((d) => d['id'] == widget.id)
      .firstOrNull;

  String get _mode => _role.mode(toGround: _toGround);

  List<BoardGpio> get _gpios => _info?.value?.gpios ?? const [];

  bool _can(BoardGpio g, String mode) => g.caps.contains(capabilityFor(mode));

  bool _roleOffered(PinRole role) =>
      _gpios.isEmpty ||
      _gpios.any(
        (g) =>
            _can(g, role.mode()) ||
            (role == PinRole.button && _can(g, role.mode(toGround: false))),
      );

  void _setRole(PinRole role) => setState(() {
    _role = role;
    _refused = null;
    if (_picked != null &&
        !_gpios.any((g) => g.pin == _picked && _can(g, _mode))) {
      _picked = null;
    }
  });

  int? get _pin => _gpios.isEmpty ? int.tryParse(_typed.text.trim()) : _picked;

  Future<void> _save(Json device) async {
    final name = pinNameFor(_name.text);
    final pin = _pin;
    if (name.isEmpty || pin == null) return;
    final raw = NamedPin.rawOf(device);
    if (raw[name] is Map) {
      final old = NamedPin.ofDevice(device).firstWhere((p) => p.name == name);
      final ok = await confirm(
        context,
        title: 'Replace ${old.label}?',
        body:
            '${old.label} is ${old.description}. Saving makes it GPIO $pin '
            'and the old wiring stops working.',
        action: 'Replace',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    final spec = NamedPin(
      name: name,
      pin: pin,
      mode: _mode,
      invert: _role == PinRole.relay && _activeLow,
    );
    setState(() {
      _saving = true;
      _refused = null;
    });
    final reply = await saveBoardPins(ref, widget.id, {
      ...raw,
      name: spec.toJson(),
    }, quiet: true);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _refused = reply.failure;
    });
    if (reply.value case final saved?) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final device = _device;
    final info = _info?.value;
    final used = {
      if (device != null)
        for (final p in NamedPin.ofDevice(device)) p.pin: p.label,
    };
    final name = pinNameFor(_name.text);
    final pin = _pin;
    final boot = pin != null && (info?.bootPins.contains(pin) ?? false);
    final ready = device != null && name.isNotEmpty && pin != null && !_saving;
    return FormPage(
      title: 'Add a pin',
      commitLabel: _saving ? 'Saving' : 'Save pin',
      commitKey: const ValueKey('pin-save'),
      onCommit: ready ? () => _save(device) : null,
      missing: _saving ? null : 'Give it a name and pick a pin first.',
      banners: [
        if (_refused case final failure?)
          OmniBanner.error(
            key: const ValueKey('pin-refused'),
            failure.issues.isEmpty
                ? failure.message
                : [
                    for (final i in failure.issues)
                      plainError('invalid', i.message),
                  ].join(' '),
          ),
      ],
      children: (context) => [
        TextField(
          key: const ValueKey('pin-name'),
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'Door sensor',
            helperText: name.isEmpty || name == _name.text.trim()
                ? null
                : 'Saved as $name',
          ),
          onChanged: (_) => setState(() => _refused = null),
        ),
        const OmniSectionHeader('What is wired to it?'),
        Wrap(
          spacing: OmniSpace.xs,
          children: [
            for (final r in PinRole.values)
              OmniFilterChip(
                key: ValueKey('pin-role-${r.name}'),
                label: r.label,
                selected: _role == r,
                onTap: _roleOffered(r) ? () => _setRole(r) : null,
              ),
          ],
        ),
        const OmniSectionHeader(
          'Pick a pin',
          trailingText: 'pins this board offers',
        ),
        if (_info == null)
          const OmniListSkeleton(rows: 2, rowHeight: OmniSpace.target)
        else if (_gpios.isEmpty) ...[
          const OmniBanner.warning(
            key: ValueKey('pin-no-describe'),
            'The board is not answering, so OmniFlow cannot list its pins. '
            'Type the GPIO number printed next to the pin.',
          ),
          TextField(
            key: const ValueKey('pin-number'),
            controller: _typed,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'GPIO number'),
            onChanged: (_) => setState(() => _refused = null),
          ),
        ] else
          _PinGrid(
            gpios: _gpios,
            mode: _mode,
            picked: _picked,
            used: used,
            boot: info?.bootPins ?? const {},
            onPick: (p) => setState(() {
              _picked = p;
              _refused = null;
            }),
          ),
        const SizedBox(height: OmniSpace.sm),
        if (boot)
          OmniBanner.warning(
            key: const ValueKey('pin-boot-warning'),
            'GPIO $pin is a boot pin on ${boardTypeLabel(info?.board)}: it '
            'can stop the board starting if it is held the wrong way at '
            'power on. Pick another pin if one is free.',
          ),
        if (_role == PinRole.button)
          OmniCard(
            title: 'Wired to ground (press reads on)',
            trailing: Semantics(
              label: 'Wired to ground',
              child: Switch(
                key: const ValueKey('pin-to-ground'),
                value: _toGround,
                onChanged: (v) {
                  _toGround = v;
                  _setRole(_role);
                },
              ),
            ),
            child: const Text(
              'Off when the button connects the pin to 3.3 V instead.',
              style: OmniText.caption,
            ),
          ),
        if (_role == PinRole.relay)
          OmniCard(
            title: 'Active low',
            trailing: Semantics(
              label: 'Active low',
              child: Switch(
                key: const ValueKey('pin-active-low'),
                value: _activeLow,
                onChanged: (v) => setState(() => _activeLow = v),
              ),
            ),
            child: const Text(
              'For relay boards that switch on when the pin is low.',
              style: OmniText.caption,
            ),
          ),
      ],
    );
  }
}

/// The GPIO grid, six across. A pin that cannot do [mode] is faded and
/// cannot be picked, a pin another name uses is marked, a boot pin carries
/// an amber dot.
class _PinGrid extends StatelessWidget {
  const _PinGrid({
    required this.gpios,
    required this.mode,
    required this.picked,
    required this.used,
    required this.boot,
    required this.onPick,
  });

  final List<BoardGpio> gpios;
  final String mode;
  final int? picked;
  final Map<int, String> used;
  final Set<int> boot;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const columns = 6;
      const gap = OmniSpace.sm;
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        key: const ValueKey('pin-grid'),
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final g in gpios)
            SizedBox(width: width, child: _cell(context, g)),
        ],
      );
    },
  );

  Widget _cell(BuildContext context, BoardGpio g) {
    final can = g.caps.contains(capabilityFor(mode));
    final user = used[g.pin];
    final enabled = can && user == null;
    final selected = picked == g.pin;
    final isBoot = boot.contains(g.pin);
    final palette = OmniPalette.of(context);
    final (bg, border, fg) = selected
        ? (palette.accent, palette.accent, palette.onAccent)
        : user != null
        ? (palette.accentSoft, palette.accentLine, palette.accent)
        : (palette.card, palette.line, OmniColors.text);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: [
        'GPIO ${g.pin}',
        if (user != null) 'used by $user',
        if (!can && user == null) 'cannot do this',
        if (isBoot) 'boot pin',
      ].join(', '),
      excludeSemantics: true,
      onTap: enabled ? () => onPick(g.pin) : null,
      child: Opacity(
        opacity: can || user != null ? 1 : 0.3,
        child: Material(
          key: ValueKey('gpio-${g.pin}'),
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(OmniShape.sm),
            side: BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? () => onPick(g.pin) : null,
            child: SizedBox(
              height: OmniSpace.target,
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      '${g.pin}',
                      style: OmniText.label.copyWith(
                        color: fg,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (isBoot)
                    const Positioned(
                      top: OmniSpace.xs,
                      right: OmniSpace.xs,
                      child: StatusDot(StatusKind.warning, label: 'Boot pin'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
