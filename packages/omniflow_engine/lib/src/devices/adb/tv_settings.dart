import '../../manifest/validation.dart';

/// How a catalog setting's text is read and written.
enum TvSettingType {
  boolean('bool'),
  integer('int'),
  float('float'),
  enumeration('enum'),
  string('string');

  const TvSettingType(this.wireName);

  final String wireName;
}

/// One choice of an enum setting: the stored text and what it means.
typedef TvSettingOption = ({String value, String label});

/// A setting the catalog knows: where it lives, its type and range.
class TvSetting {
  const TvSetting(
    this.namespace,
    this.key,
    this.label,
    this.type, {
    this.min,
    this.max,
    this.step,
    this.options = const [],
    this.unit,
    this.description,
  });

  final String namespace;
  final String key;
  final String label;
  final TvSettingType type;
  final num? min;
  final num? max;
  final num? step;
  final List<TvSettingOption> options;
  final String? unit;
  final String? description;

  String get id => '$namespace/$key';

  /// The stored text as this setting's type, or null when it is unset or
  /// does not read as that type.
  Object? read(String? raw) {
    if (raw == null || raw == 'null') return null;
    final text = raw.trim();
    return switch (type) {
      TvSettingType.boolean => switch (text) {
        '1' || 'true' => true,
        '0' || 'false' => false,
        _ => null,
      },
      TvSettingType.integer => int.tryParse(text),
      TvSettingType.float => double.tryParse(text),
      TvSettingType.enumeration || TvSettingType.string => raw,
    };
  }

  /// Checks [value] against the type and range, and returns the text to
  /// store. Throws [ValidationException] with the reason.
  String encode(Object? value) {
    String fail(String message) => throw ValidationException('tv setting', [
      ValidationIssue(r'$.value', '$id $message'),
    ]);
    switch (type) {
      case TvSettingType.boolean:
        return switch (value) {
          true || 'true' || '1' || 1 => '1',
          false || 'false' || '0' || 0 => '0',
          _ => fail('is true or false'),
        };
      case TvSettingType.integer:
        final n = value is String ? int.tryParse(value.trim()) : value;
        if (n is! int) return fail('is a whole number');
        _range(n, fail);
        return '$n';
      case TvSettingType.float:
        final n = value is String ? double.tryParse(value.trim()) : value;
        if (n is! num || !n.isFinite) return fail('is a number');
        _range(n, fail);
        return n.toDouble().toString();
      case TvSettingType.enumeration:
        final text = value is String ? value : '$value';
        if (!options.any((o) => o.value == text)) {
          return fail(
            'is one of ${options.map((o) => '${o.value} (${o.label})').join(', ')}',
          );
        }
        return text;
      case TvSettingType.string:
        if (value is! String) return fail('is text');
        if (value.length > 4096 || value.contains(RegExp('[\x00\r\n]'))) {
          return fail('is at most 4096 characters on one line');
        }
        return value;
    }
  }

  void _range(num n, void Function(String) fail) {
    if (min != null && n < min!) fail('is at least $min');
    if (max != null && n > max!) fail('is at most $max');
  }

  Map<String, Object?> toJson(String? raw) => {
    'namespace': namespace,
    'key': key,
    'label': label,
    'type': type.wireName,
    'min': ?min,
    'max': ?max,
    'step': ?step,
    if (options.isNotEmpty)
      'options': [
        for (final o in options) {'value': o.value, 'label': o.label},
      ],
    'unit': ?unit,
    'description': ?description,
    'value': read(raw),
  };
}

const _bool = TvSettingType.boolean;
const _int = TvSettingType.integer;
const _float = TvSettingType.float;
const _enum = TvSettingType.enumeration;
const _string = TvSettingType.string;

const _animationScales = [
  (value: '0.0', label: 'Off'),
  (value: '0.5', label: '0.5x'),
  (value: '1.0', label: '1x'),
  (value: '1.5', label: '1.5x'),
  (value: '2.0', label: '2x'),
  (value: '5.0', label: '5x'),
  (value: '10.0', label: '10x'),
];

TvSetting _scale(String key, String label) => TvSetting(
  'global',
  key,
  label,
  _float,
  min: 0,
  max: 10,
  step: 0.5,
  unit: 'x',
  description: 'Choices: ${_animationScales.map((o) => o.label).join(', ')}',
);

/// The settings worth changing on an Android TV, by category. Each was read
/// on a TCL Google TV on Android 14; a key the TV has never stored reads as
/// null until it is set. Writes that would cut the engine off from the TV
/// (ADB, Wi-Fi, airplane mode, developer options) are left out.
final List<({String category, List<TvSetting> settings})> tvSettingCatalog = [
  (
    category: 'Display and sound',
    settings: [
      const TvSetting(
        'system',
        'screen_brightness',
        'Screen brightness',
        _int,
        min: 0,
        max: 255,
        step: 1,
      ),
      const TvSetting(
        'system',
        'screen_brightness_mode',
        'Brightness mode',
        _enum,
        options: [
          (value: '0', label: 'Manual'),
          (value: '1', label: 'Automatic'),
        ],
      ),
      const TvSetting(
        'system',
        'font_scale',
        'Text size',
        _float,
        min: 0.85,
        max: 2,
        step: 0.05,
        unit: 'x',
      ),
      const TvSetting(
        'system',
        'sound_effects_enabled',
        'Sounds on navigation',
        _bool,
      ),
      const TvSetting(
        'global',
        'user_disabled_hdr_formats',
        'HDR formats turned off',
        _string,
        description: 'Comma-separated HDR type numbers, empty for none',
      ),
    ],
  ),
  (
    category: 'Network',
    settings: [
      const TvSetting(
        'global',
        'private_dns_mode',
        'Private DNS',
        _enum,
        options: [
          (value: 'off', label: 'Off'),
          (value: 'opportunistic', label: 'Automatic'),
          (value: 'hostname', label: 'Private DNS provider hostname'),
        ],
      ),
      const TvSetting(
        'global',
        'private_dns_specifier',
        'Private DNS hostname',
        _string,
        description: 'Used when Private DNS is set to a provider hostname',
      ),
      const TvSetting(
        'global',
        'wifi_scan_always_enabled',
        'Wi-Fi scanning while Wi-Fi is off',
        _bool,
      ),
    ],
  ),
  (
    category: 'Power and sleep',
    settings: [
      const TvSetting(
        'system',
        'screen_off_timeout',
        'Screen off after',
        _int,
        min: 10000,
        max: 2147483647,
        step: 60000,
        unit: 'ms',
      ),
      const TvSetting(
        'secure',
        'sleep_timeout',
        'Sleep after',
        _int,
        min: -1,
        max: 2147483647,
        step: 60000,
        unit: 'ms',
        description: '-1 never sleeps',
      ),
      const TvSetting(
        'secure',
        'attentive_timeout',
        'Turn off when idle after',
        _int,
        min: -1,
        max: 2147483647,
        step: 3600000,
        unit: 'ms',
        description: '-1 never turns off',
      ),
      const TvSetting(
        'global',
        'low_power_standby_enabled',
        'Low power standby',
        _bool,
      ),
    ],
  ),
  (
    category: 'Screensaver',
    settings: [
      const TvSetting('secure', 'screensaver_enabled', 'Screensaver', _bool),
      const TvSetting(
        'secure',
        'screensaver_activate_on_sleep',
        'Start the screensaver when idle',
        _bool,
      ),
      const TvSetting(
        'secure',
        'screensaver_activate_on_dock',
        'Start the screensaver when docked',
        _bool,
      ),
      const TvSetting(
        'secure',
        'screensaver_components',
        'Screensaver app',
        _string,
        description: 'The screensaver component, package/class',
      ),
    ],
  ),
  (
    category: 'HDMI-CEC',
    settings: [
      const TvSetting('global', 'hdmi_control_enabled', 'HDMI control', _bool),
      const TvSetting(
        'global',
        'hdmi_control_auto_wakeup_enabled',
        'Turn on with the HDMI device',
        _bool,
      ),
      const TvSetting(
        'global',
        'hdmi_control_auto_device_off_enabled',
        'Turn HDMI devices off with the TV',
        _bool,
      ),
      const TvSetting(
        'global',
        'hdmi_control_auto_tv_off_enabled',
        'Turn off with the HDMI device',
        _bool,
      ),
      const TvSetting(
        'global',
        'hdmi_control_volume_control_enabled',
        'Volume control over HDMI',
        _bool,
      ),
      const TvSetting(
        'global',
        'hdmi_system_audio_control_enabled',
        'System audio control',
        _bool,
      ),
      const TvSetting(
        'global',
        'tv_send_standby_on_sleep',
        'Send standby when the TV sleeps',
        _bool,
      ),
      const TvSetting(
        'global',
        'tv_wake_on_one_touch_play',
        'Wake on one-touch play',
        _bool,
      ),
    ],
  ),
  (
    category: 'Bluetooth',
    settings: [
      const TvSetting(
        'global',
        'bluetooth_on',
        'Bluetooth',
        _bool,
        description: 'Turned on and off through the Bluetooth service',
      ),
    ],
  ),
  (
    category: 'Accessibility and captions',
    settings: [
      const TvSetting(
        'secure',
        'accessibility_captioning_enabled',
        'Captions',
        _bool,
      ),
      const TvSetting(
        'secure',
        'accessibility_captioning_font_scale',
        'Caption text size',
        _float,
        min: 0.25,
        max: 2,
        step: 0.25,
        unit: 'x',
      ),
      const TvSetting(
        'secure',
        'high_text_contrast_enabled',
        'High contrast text',
        _bool,
      ),
      const TvSetting(
        'secure',
        'accessibility_display_inversion_enabled',
        'Color inversion',
        _bool,
      ),
      const TvSetting(
        'secure',
        'accessibility_display_magnification_enabled',
        'Magnification',
        _bool,
      ),
      const TvSetting(
        'secure',
        'long_press_timeout',
        'Touch and hold delay',
        _int,
        min: 300,
        max: 1500,
        step: 100,
        unit: 'ms',
      ),
    ],
  ),
  (
    category: 'Developer',
    settings: [
      _scale('animator_duration_scale', 'Animator duration scale'),
      _scale('transition_animation_scale', 'Transition animation scale'),
      _scale('window_animation_scale', 'Window animation scale'),
      const TvSetting(
        'global',
        'stay_on_while_plugged_in',
        'Stay awake',
        _enum,
        options: [(value: '0', label: 'Off'), (value: '7', label: 'On')],
      ),
      const TvSetting('system', 'show_touches', 'Show taps', _bool),
      const TvSetting('system', 'pointer_location', 'Pointer location', _bool),
      const TvSetting(
        'global',
        'always_finish_activities',
        'Do not keep activities',
        _bool,
      ),
    ],
  ),
  (
    category: 'Date and time',
    settings: [
      const TvSetting('global', 'auto_time', 'Network time', _bool),
      const TvSetting('global', 'auto_time_zone', 'Network time zone', _bool),
      const TvSetting(
        'system',
        'time_12_24',
        'Time format',
        _enum,
        options: [
          (value: '12', label: '12-hour'),
          (value: '24', label: '24-hour'),
        ],
      ),
    ],
  ),
  (
    category: 'Location',
    settings: [
      const TvSetting(
        'secure',
        'location_mode',
        'Location',
        _enum,
        options: [(value: '0', label: 'Off'), (value: '3', label: 'On')],
      ),
      const TvSetting('global', 'assisted_gps_enabled', 'Assisted GPS', _bool),
    ],
  ),
  (
    category: 'Other',
    settings: [
      const TvSetting('global', 'device_name', 'Device name', _string),
      const TvSetting(
        'global',
        'zen_mode',
        'Do not disturb',
        _enum,
        options: [
          (value: '0', label: 'Off'),
          (value: '1', label: 'Priority only'),
          (value: '2', label: 'Total silence'),
          (value: '3', label: 'Alarms only'),
        ],
      ),
      const TvSetting(
        'global',
        'heads_up_notifications_enabled',
        'Pop-up notifications',
        _bool,
      ),
    ],
  ),
];

/// Every catalog setting by `namespace/key`.
final Map<String, TvSetting> tvSettingsById = {
  for (final c in tvSettingCatalog)
    for (final s in c.settings) s.id: s,
};
