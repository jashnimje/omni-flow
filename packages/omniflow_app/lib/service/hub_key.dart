// The engine already depends on dartssh2 and its pinenacl, and the app may
// not add dependencies, so the phone's hub key is made with those two.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

/// This phone's SSH key for the Mac mini hub: the private key as an
/// OpenSSH PEM, which stays in the phone's keystore, and the public key as
/// one `ssh-ed25519 AAAA... comment` line for `omni hub allow`.
class HubKey {
  const HubKey({required this.privatePem, required this.publicLine});

  final String privatePem;
  final String publicLine;

  /// A fresh ed25519 key pair named `omniflow-<phone>`.
  factory HubKey.generate(String phone) {
    final signing = ed25519.SigningKey.generate();
    final public = Uint8List.fromList(signing.verifyKey.asTypedList);
    final private = Uint8List.fromList(signing.asTypedList);
    final comment = 'omniflow-$phone';
    final pair = OpenSSHEd25519KeyPair(public, private, comment);
    final blob = base64.encode(_publicBlob(public));
    return HubKey(
      privatePem: pair.toPem(),
      publicLine: 'ssh-ed25519 $blob $comment',
    );
  }

  /// The SSH wire form of an ed25519 public key: the type name and the key,
  /// each with its 4-byte length.
  static Uint8List _publicBlob(Uint8List key) {
    final type = utf8.encode('ssh-ed25519');
    final out = BytesBuilder();
    for (final part in [type, key]) {
      out.add((ByteData(4)..setUint32(0, part.length)).buffer.asUint8List());
      out.add(part);
    }
    return out.toBytes();
  }

  /// The key type and key, without the comment: what `omni hub allow` takes.
  String get publicKey => publicLine.split(' ').take(2).join(' ');
}

/// The line to run on the Mac mini to let this phone in. The key is quoted
/// because it holds a space.
String hubAllowLine(String phone, HubKey key) =>
    "omni hub allow $phone '${key.publicKey}'";

/// A phone name as the hub keeps it: the id of its phone thing, so a
/// lower case letter first, then letters, digits and underscores, at most
/// 32, the same rule `omni hub allow` checks.
String hubPhoneName(String typed) {
  var name = typed
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^[^a-z]+|_+$'), '');
  if (name.length > 32) {
    name = name.substring(0, 32).replaceAll(RegExp(r'_+$'), '');
  }
  return name;
}
