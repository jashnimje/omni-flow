import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../api/engine_calls.dart' show Json;
import '../../rules/rule_spec.dart';
import '../devices/device_text.dart' show appName;

/// The phone's newer triggers and actions, as the engine's phone driver
/// names them.
abstract final class PhoneMoreKeys {
  static const alarmSoon = 'alarm_soon';
  static const callRinging = 'call_ringing';
  static const callAnswered = 'call_answered';
  static const callEnded = 'call_ended';
  static const mediaStarted = 'media_started';
  static const mediaStopped = 'media_stopped';
  static const calendarStarted = 'calendar_started';
  static const calendarEnded = 'calendar_ended';
  static const shaken = 'shaken';
  static const startedUp = 'started_up';
  static const appInstalled = 'app_installed';
  static const appUpdated = 'app_updated';
  static const headphones = 'headphones';
  static const faceDown = 'face_down';

  static const calls = {callRinging, callAnswered, callEnded};
  static const media = {mediaStarted, mediaStopped};
  static const calendar = {calendarStarted, calendarEnded};
  static const installs = {appInstalled, appUpdated};
  static const switches = {headphones, faceDown};
}

String _minutes(Object? m) {
  if (m is! int) return 'a while';
  if (m >= 60 && m % 60 == 0) return '${m ~/ 60} h';
  return '$m min';
}

/// A newer phone trigger in words, or null for another key.
String? phoneMoreTriggerText(OnTrigger t) {
  final match = t.match ?? const {};
  final package = match['package'];
  final app = package is String ? appName(package) : null;
  final words = match['words'];
  String turns(String on, String off, String either) =>
      switch (t.hasTo ? t.to : null) {
        true => on,
        false => off,
        _ => either,
      };
  return switch (t.key) {
    PhoneMoreKeys.alarmSoon =>
      '${_minutes(match['minutes'])} before my next alarm',
    PhoneMoreKeys.callRinging => 'A call rings',
    PhoneMoreKeys.callAnswered => 'A call is answered',
    PhoneMoreKeys.callEnded => 'A call ends',
    PhoneMoreKeys.mediaStarted =>
      app == null ? 'Media starts playing' : '$app starts playing',
    PhoneMoreKeys.mediaStopped =>
      app == null ? 'Media stops playing' : '$app stops playing',
    PhoneMoreKeys.calendarStarted => 'A calendar event with "$words" starts',
    PhoneMoreKeys.calendarEnded => 'A calendar event with "$words" ends',
    PhoneMoreKeys.shaken => 'The phone is shaken',
    PhoneMoreKeys.startedUp => 'The phone starts up',
    PhoneMoreKeys.appInstalled =>
      app == null ? 'An app is installed' : '$app is installed',
    PhoneMoreKeys.appUpdated =>
      app == null ? 'An app is updated' : '$app is updated',
    PhoneMoreKeys.headphones => turns(
      'Wired headphones are plugged in',
      'Wired headphones are unplugged',
      'Wired headphones are plugged in or out',
    ),
    PhoneMoreKeys.faceDown => turns(
      'The phone is put face down',
      'The phone is picked up',
      'The phone is put face down or picked up',
    ),
    _ => null,
  };
}

/// The icon of a newer phone trigger, or null for another key.
IconData? phoneMoreTriggerIcon(String key) => switch (key) {
  PhoneMoreKeys.alarmSoon => Symbols.alarm_rounded,
  PhoneMoreKeys.callRinging ||
  PhoneMoreKeys.callAnswered ||
  PhoneMoreKeys.callEnded => Symbols.call_rounded,
  PhoneMoreKeys.mediaStarted ||
  PhoneMoreKeys.mediaStopped => Symbols.play_circle_rounded,
  PhoneMoreKeys.calendarStarted ||
  PhoneMoreKeys.calendarEnded => Symbols.event_rounded,
  PhoneMoreKeys.shaken => Symbols.vibration_rounded,
  PhoneMoreKeys.startedUp => Symbols.restart_alt_rounded,
  PhoneMoreKeys.appInstalled ||
  PhoneMoreKeys.appUpdated => Symbols.install_mobile_rounded,
  PhoneMoreKeys.headphones => Symbols.headphones_rounded,
  PhoneMoreKeys.faceDown => Symbols.screen_rotation_rounded,
  _ => null,
};

/// What a phone action step does, after "Phone · ": `say "Hello"`. Null
/// for a capability these do not cover.
String? phoneStepWhat(String capability, Json params) {
  final value = params['value'];
  String onOff(String what) => switch (value) {
    true => '$what on',
    false => '$what off',
    _ => what,
  };
  return switch (capability) {
    'speak' => 'say "${params['text'] ?? ''}"',
    'vibrate' =>
      params['pattern'] == 'long' ? 'vibrate for a while' : 'vibrate',
    'torch' => onOff('torch'),
    'play_sound' => 'play a short sound',
    'ringer' => 'ringer to ${params['mode'] ?? 'normal'}',
    'set_dnd' => onOff('Do Not Disturb'),
    'media_volume' => 'media volume to $value%',
    'media' => switch (params['key']) {
      'play' => 'play what is paused',
      'pause' => 'pause what is playing',
      'next' => 'next track',
      'previous' => 'previous track',
      _ => 'play or pause',
    },
    'open_app' => 'open ${appName('${params['package'] ?? ''}')}',
    'open_link' =>
      'open ${Uri.tryParse('${params['url']}')?.host ?? params['url']}',
    'set_alarm' => 'set an alarm for ${params['time']}',
    'set_timer' => 'set a ${_minutes(params['minutes'])} timer',
    'show_message' => 'show "${params['title'] ?? ''}" on screen',
    _ => null,
  };
}
