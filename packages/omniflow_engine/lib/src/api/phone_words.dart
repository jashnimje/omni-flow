/// Plain words for the phone's newer triggers and actions, which read
/// better as a sentence than as "Phone a call rings". [phone] is the phone
/// thing's name. Null for a key these do not cover, which then reads the
/// usual way.
String? phoneTriggerWords(String phone, String key, Object? match) {
  final m = match is Map ? match : const {};
  final words = m['words'];
  final app = m['label'] ?? m['package'];
  return switch (key) {
    'alarm_soon' => '${_minutes(m['minutes'])} before the next alarm on $phone',
    'call_ringing' => 'a call rings on $phone',
    'call_answered' => 'a call is answered on $phone',
    'call_ended' => 'a call ends on $phone',
    'media_started' =>
      app == null
          ? 'media starts playing on $phone'
          : '$app starts playing on $phone',
    'media_stopped' =>
      app == null
          ? 'media stops playing on $phone'
          : '$app stops playing on $phone',
    'calendar_started' => 'a calendar event with "$words" starts on $phone',
    'calendar_ended' => 'a calendar event with "$words" ends on $phone',
    'shaken' => '$phone is shaken',
    'started_up' => '$phone starts up',
    'app_installed' =>
      app == null
          ? 'an app is installed on $phone'
          : '$app is installed on $phone',
    'app_updated' =>
      app == null ? 'an app is updated on $phone' : '$app is updated on $phone',
    _ => null,
  };
}

String _minutes(Object? m) {
  if (m is! int) return 'a while';
  if (m >= 60 && m % 60 == 0) return '${m ~/ 60} h';
  return '$m min';
}

/// The words of a phone action step: `Phone says "Dinner is ready"`.
String? phoneStepWords(String phone, String key, Map? params) {
  final p = params ?? const {};
  final value = p['value'];
  return switch (key) {
    'speak' => '$phone says "${p['text']}"',
    'vibrate' =>
      p['pattern'] == 'long'
          ? '$phone vibrates for a while'
          : '$phone vibrates',
    'torch' => switch (value) {
      true => 'turn on the torch on $phone',
      false => 'turn off the torch on $phone',
      _ => 'toggle the torch on $phone',
    },
    'play_sound' => '$phone plays a short sound',
    'ringer' => 'set the ringer on $phone to ${p['mode']}',
    'set_dnd' => switch (value) {
      true => 'turn on Do Not Disturb on $phone',
      false => 'turn off Do Not Disturb on $phone',
      _ => 'toggle Do Not Disturb on $phone',
    },
    'media_volume' => 'set the media volume on $phone to $value%',
    'media' => switch (p['key']) {
      'play' => 'play what is paused on $phone',
      'pause' => 'pause what is playing on $phone',
      'next' => 'skip to the next track on $phone',
      'previous' => 'go back a track on $phone',
      _ => 'play or pause on $phone',
    },
    'open_app' => 'open ${p['package']} on $phone',
    'open_link' =>
      'open ${Uri.tryParse('${p['url']}')?.host ?? p['url']} on $phone',
    'set_alarm' => 'set an alarm for ${p['time']} on $phone',
    'set_timer' => 'set a ${_minutes(p['minutes'])} timer on $phone',
    'show_message' => 'show "${p['title']}" on $phone\'s screen',
    _ => null,
  };
}
