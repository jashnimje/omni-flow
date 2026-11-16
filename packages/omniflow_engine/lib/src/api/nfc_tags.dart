import 'api_error.dart';
import 'command_args.dart';
import 'device_commands.dart';
import 'engine_core.dart';
import 'things_runtime.dart';
import '../devices/board.dart';
import '../devices/device.dart';
import '../devices/nfc/ndef.dart';
import '../storage/database.dart';

/// The driver id of NFC tag things.
const nfcTagDriverId = 'nfc_tag';

/// The `source` of a scan the phone read.
const phoneScanSource = 'phone';

/// The event a scan raises on the phone that read it.
const phoneNfcEvent = 'nfc_scanned';

final _uidHex = RegExp(r'^(?:[0-9A-F]{2}){4,10}$');
final _uidSeparators = RegExp(r'[\s:-]');

/// An NFC UID as upper-case hex with no separators, or null when [raw] is
/// not 4 to 10 bytes of hex (ISO 14443 UIDs are 4, 7 or 10 bytes, ISO
/// 15693 and FeliCa ids 8).
String? normalizeUid(Object? raw) {
  if (raw is! String || raw.length > 64) return null;
  final hex = raw.replaceAll(_uidSeparators, '').toUpperCase();
  return _uidHex.hasMatch(hex) ? hex : null;
}

/// The thing that read a tag and the event the scan raises on it: the
/// phone's `nfc_scanned`, or a board's `nfc.scanned`. [source] is what the
/// scan reports as its source, `phone` or the board's id.
typedef NfcReader = ({String source, String thing, String event});

/// What one scan resolved to: the tag thing, or null with the `thing.add`
/// candidate that names the tag, or null with the tag whose link the card
/// carries under another UID than the one pinned to it.
typedef NfcScanMatch = ({
  String? tag,
  Map<String, Object?>? add,
  String? mismatch,
});

/// The NFC tag things. A scan from any reader, the phone or a board's
/// RC522 or PN532, finds the tag by the id OmniFlow wrote on it (the
/// `omniflow://tag/<id>` link) and then by its UID, records `last_scanned`
/// and `last_source` (`phone` or the board's id) and raises `scanned` on it, then raises the reader's own event. A tag no
/// thing knows is reported as `tag.unknown` with the `thing.add` candidate
/// that names it.
///
/// The link is trusted on first use: the first scan a link resolves pins
/// the card's UID on a tag that has none, and a later card with that link
/// and another UID raises `tag.mismatch` instead of `scanned`, so copying
/// the link onto a blank card does not fire the tag.
class NfcTags {
  NfcTags(this._core);

  final EngineCore _core;

  DriftDeviceStore get _store => DriftDeviceStore(_core.db);

  Future<List<Device>> tags() async => [
    for (final d in await _store.all())
      if (d.driverId == nfcTagDriverId) d,
  ];

  /// [reader] read the tag with [uid], carrying the OmniFlow link [ndefId]
  /// when it has one. Both are already validated.
  Future<NfcScanMatch> scan({
    required String uid,
    String? ndefId,
    required NfcReader reader,
    required DateTime at,
  }) async {
    final all = await tags();
    final linked = all
        .where((t) => ndefId != null && t.id == ndefId)
        .firstOrNull;
    final pinned = linked == null ? null : normalizeUid(linked.settings['uid']);
    final when = at.toUtc().toIso8601String();
    if (linked != null && pinned != null && pinned != uid) {
      _core.emit({
        'event': 'tag.mismatch',
        'tag': linked.id,
        'expectedUid': pinned,
        'uid': uid,
        'source': reader.source,
      });
      _core.raiseEvent(reader.thing, reader.event, {
        'uid': uid,
        'ndefId': ?ndefId,
        'at': when,
      });
      return (tag: null, add: null, mismatch: linked.id);
    }
    if (linked != null && pinned == null) await _pin(linked, uid, all);
    final tag =
        linked ??
        all.where((t) => normalizeUid(t.settings['uid']) == uid).firstOrNull;
    Map<String, Object?>? add;
    if (tag == null) {
      final idFree = ndefId != null && await _store.get(ndefId) == null;
      add = addFor(uid: uid, id: idFree ? ndefId : null);
      _core.emit({
        'event': 'tag.unknown',
        'uid': uid,
        'ndefId': ?ndefId,
        'source': reader.source,
        'add': add,
      });
    } else {
      await _core.devices.mergeState(tag.id, {
        'last_scanned': when,
        'last_source': reader.source,
      });
      _core.raiseEvent(tag.id, 'scanned', {
        'uid': uid,
        'ndefId': ?ndefId,
        'source': reader.source,
        'at': when,
      });
    }
    _core.raiseEvent(reader.thing, reader.event, {
      'uid': uid,
      'ndefId': ?ndefId,
      'at': when,
      'tag': ?tag?.id,
    });
    return (tag: tag?.id, add: add, mismatch: null);
  }

  /// Pins [uid] on [tag], unless another tag holds it: two tags never share
  /// a UID, so that card stays unpinned and its link alone names the tag.
  Future<void> _pin(Device tag, String uid, List<Device> all) async {
    if (all.any((t) => normalizeUid(t.settings['uid']) == uid)) return;
    await _core.devices.updateDevice(
      tag.id,
      (d) => normalizeUid(d.settings['uid']) != null
          ? d
          : d.copyWith(settings: {...d.settings, 'uid': uid}),
    );
  }

  /// The `thing.add` candidate that makes an unknown tag a thing, under the
  /// id its OmniFlow link names when that id is free.
  static Map<String, Object?> addFor({required String uid, String? id}) => {
    'driver': nfcTagDriverId,
    'id': ?id,
    'settings': {'uid': uid},
  };
}

/// `tag.*` and `nfc.scanned`: the tag registry, what the phone writes on a
/// tag, and the one input every reader's scans arrive at.
class TagCommands {
  TagCommands(this._core, this._things, this._devices);

  final EngineCore _core;
  final ThingsRuntime _things;
  final DeviceCommands _devices;

  NfcTags get _tags => NfcTags(_core);

  DriftDeviceStore get _store => DriftDeviceStore(_core.db);

  Map<String, CommandHandler> get commands => {
    'tag.save': save,
    'tag.list': list,
    'tag.remove': remove,
    'tag.write_payload': writePayload,
    'nfc.scanned': scanned,
  };

  static Map<String, Object?> _json(Device tag) => {
    'id': tag.id,
    'name': tag.name,
    'uid': ?normalizeUid(tag.settings['uid']),
    'lastScanned': ?tag.state['last_scanned'],
    'lastSource': ?tag.state['last_source'],
  };

  Future<Device> _tag(String id) async {
    final device = await _core.device(id);
    if (device.driverId != nfcTagDriverId) {
      throw ApiError('invalid', '$id is not an NFC tag');
    }
    return device;
  }

  static String _tagId(Map<String, Object?> args) {
    final id = stringArg(args, 'id');
    if (!tagIdPattern.hasMatch(id)) {
      throw ApiError(
        'invalid',
        'a tag id is lower snake case, up to 64 characters',
      );
    }
    return id;
  }

  /// `{id, name, uid?}`: adds the tag, or renames it and sets its UID. A
  /// UID left out keeps the one it has, and null clears it. Two tags never
  /// share a UID, so a scan finds one.
  Future<Map<String, Object?>> save(Map<String, Object?> args) async {
    final id = _tagId(args);
    final name = stringArg(args, 'name');
    final rawUid = args['uid'];
    final uid = rawUid == null ? null : normalizeUid(rawUid);
    if (rawUid != null && uid == null) {
      throw ApiError(
        'invalid',
        'uid must be 4 to 10 bytes of hex, like 04:A2:2B:1C',
      );
    }
    final existing = await _store.get(id);
    if (existing != null && existing.driverId != nfcTagDriverId) {
      throw ApiError(
        'exists',
        'a thing $id exists and is not an NFC tag. Pick another id',
      );
    }
    if (uid != null) {
      final holder = (await _tags.tags())
          .where((t) => t.id != id && normalizeUid(t.settings['uid']) == uid)
          .firstOrNull;
      if (holder != null) {
        throw ApiError('exists', 'the tag ${holder.id} has that uid');
      }
    }
    if (existing == null) {
      await _devices.add({
        'id': id,
        'name': name,
        'driver': nfcTagDriverId,
        'settings': {'uid': ?uid},
      });
    } else {
      final settings = {...existing.settings};
      if (uid != null) {
        settings['uid'] = uid;
      } else if (args.containsKey('uid')) {
        settings.remove('uid');
      }
      await _core.devices.updateDevice(
        id,
        (d) => d.copyWith(name: name, settings: settings),
      );
    }
    return {'tag': _json(await _core.device(id)), 'created': existing == null};
  }

  Future<Map<String, Object?>> list(Map<String, Object?> _) async => {
    'tags': [for (final t in await _tags.tags()) _json(t)],
  };

  /// Removes the tag as `device.remove` does: the flows that name it are
  /// disabled.
  Future<Map<String, Object?>> remove(Map<String, Object?> args) async {
    final tag = await _tag(stringArg(args, 'id'));
    return _devices.remove({'id': tag.id});
  }

  /// `{id}`: the NDEF records the phone writes on a tag for the tag thing
  /// [id], so a scan finds it and Android opens the app. The first card
  /// scanned with the link is pinned to the tag. A card written again
  /// answers once `tag.save` with `uid: null` clears the pin, and the next
  /// card scanned is pinned.
  Future<Map<String, Object?>> writePayload(Map<String, Object?> args) async {
    final tag = await _tag(_tagId(args));
    return {
      'id': tag.id,
      'uri': '$tagUriPrefix${tag.id}',
      'androidPackage': omniflowApplicationId,
      'records': tagRecords(tag.id),
    };
  }

  /// `{uid, ndef?, source, phone?, at?}`: a reader saw a tag. [source] is
  /// `phone` (the phone thing `phone` names, or the default phone) or the
  /// id of the board whose reader saw it.
  Future<Map<String, Object?>> scanned(Map<String, Object?> args) async =>
      _scan(args, stringArg(args, 'source'));

  Future<Map<String, Object?>> _scan(
    Map<String, Object?> args,
    String source,
  ) async {
    if (args['uid'] == null) throw ApiError('invalid', 'uid is required');
    final uid =
        normalizeUid(args['uid']) ??
        (throw ApiError(
          'invalid',
          'uid must be 4 to 10 bytes of hex, like 04:A2:2B:1C',
        ));
    final ndefId = tagIdFromNdef(decodeNdef(args['ndef']));
    final at = optDateArg(args, 'at') ?? DateTime.now();
    final NfcReader reader;
    if (source == phoneScanSource) {
      final phone = await _things.phone(optStringArg(args, 'phone'));
      reader = (source: source, thing: phone.id, event: phoneNfcEvent);
    } else {
      final board = await _store.get(source);
      if (board == null || !isBoardDriver(_core.registry[board.driverId])) {
        throw ApiError('invalid', 'source is phone or the id of a board');
      }
      reader = (source: board.id, thing: board.id, event: boardNfcEvent);
    }
    final match = await _tags.scan(
      uid: uid,
      ndefId: ndefId,
      reader: reader,
      at: at,
    );
    return {
      'tag': match.tag,
      'uid': uid,
      'ndefId': ?ndefId,
      'source': reader.source,
      'add': ?match.add,
      'mismatch': ?match.mismatch,
    };
  }
}
