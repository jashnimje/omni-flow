/// OmniFlow engine: the one core API shared by the omni CLI and the app.
library;

export 'src/api/command_bar.dart';
export 'src/api/local_client.dart'
    show
        EngineConnection,
        InProcessConnection,
        LocalClient,
        LocalSocketException,
        localSocketPath;
export 'src/api/local_server.dart' show LocalServer, preparePrivateHome;
export 'src/api/nfc_tags.dart' show normalizeUid, nfcTagDriverId;
export 'src/api/adb_phone_connection.dart';
export 'src/api/agent_policy.dart';
export 'src/api/omni_engine.dart';
export 'src/api/thing_setup.dart'
    show nextSetupStep, pairingProofSecret, settingPresent;
export 'src/cli/omni_command_runner.dart';
export 'src/codecs/crc32.dart';
export 'src/codecs/tuya_codec.dart';
export 'src/dag/cards.dart';
export 'src/dag/conditions.dart';
export 'src/dag/executor.dart';
export 'src/dag/flow_engine.dart';
export 'src/dag/links.dart';
export 'src/dag/migrate.dart';
export 'src/dag/expression.dart';
export 'src/dag/flow.dart';
export 'src/dag/node_types.dart';
export 'src/dag/rule_shorthand.dart';
export 'src/dag/rules.dart';
export 'src/dag/transformers.dart';
export 'src/dag/validator.dart';
export 'src/devices/adb/adb_channel.dart';
export 'src/devices/adb/adb_commands.dart' show AdbAction, TvShell, shellQuote;
export 'src/devices/adb/tv_keys.dart' show tvKeyCodes, tvKeyGroups;
export 'src/devices/adb/adb_key.dart' show adbHostKeySecret;
export 'src/devices/board.dart';
export 'src/devices/channels.dart';
export 'src/devices/device.dart';
export 'src/devices/device_service.dart';
export 'src/devices/discovery.dart';
export 'src/devices/discovery/mdns_discovery.dart';
export 'src/devices/discovery/tuya_broadcast.dart';
export 'src/devices/http_channel.dart';
export 'src/devices/mqtt_channel.dart';
export 'src/devices/nfc/ndef.dart';
export 'src/devices/serial_channel.dart';
export 'src/devices/tuya_channel.dart';
export 'src/devices/virtual_channel.dart';
export 'src/devices/tv/tv_channel.dart';
export 'src/devices/tv/tv_socket.dart'
    show TvPairingException, TvCertificateMismatchException, certificateSha256;
export 'src/devices/wiz_push.dart';
export 'src/manifest/capability.dart';
export 'src/mcp/omni_mcp.dart';
export 'src/manifest/driver_manifest.dart';
export 'src/manifest/driver_registry.dart';
export 'src/manifest/param_spec.dart';
export 'src/manifest/validation.dart';
export 'src/storage/database.dart';
export 'src/storage/keychain_secret_store.dart';
export 'src/storage/secret_store.dart';
export 'src/template/template_renderer.dart';
export 'src/transports/host_exec.dart';
export 'src/transports/ndjson.dart';
export 'src/transports/packet_tap.dart';
export 'src/transports/ssh_executor.dart';
export 'src/transports/udp_transport.dart';
export 'src/version.dart';
export 'src/zones/zones.dart';
