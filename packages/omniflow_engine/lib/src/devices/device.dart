/// A physical or virtual device: one instance of a driver.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.driverId,
    required this.host,
    this.port,
    this.room,
    this.stableId,
    this.settings = const {},
    this.state = const {},
    this.lastSeen,
  });

  final String id;
  final String name;
  final String driverId;

  /// IP address or host name, `local` for this machine, or a serial port path.
  final String host;

  /// Overrides the driver's default port when set.
  final int? port;
  final String? room;

  /// The id that survives an IP change (MAC, Tuya devId), used to find the
  /// device again through discovery.
  final String? stableId;

  /// Non-secret settings. Secrets live in the secret store.
  final Map<String, Object?> settings;
  final Map<String, Object?> state;
  final DateTime? lastSeen;

  bool isOnline(DateTime now, Duration window) =>
      lastSeen != null && now.difference(lastSeen!) <= window;

  Device copyWith({
    String? host,
    Map<String, Object?>? state,
    DateTime? lastSeen,
  }) => Device(
    id: id,
    name: name,
    driverId: driverId,
    host: host ?? this.host,
    port: port,
    room: room,
    stableId: stableId,
    settings: settings,
    state: state ?? this.state,
    lastSeen: lastSeen ?? this.lastSeen,
  );
}

/// Where devices are kept. The drift-backed store replaces the in-memory one
/// once storage lands; both satisfy the same contract tests.
abstract interface class DeviceStore {
  Future<Device?> get(String id);
  Future<List<Device>> all();
  Future<void> put(Device device);
  Future<bool> remove(String id);
}

class InMemoryDeviceStore implements DeviceStore {
  final _devices = <String, Device>{};

  @override
  Future<Device?> get(String id) async => _devices[id];

  @override
  Future<List<Device>> all() async => _devices.values.toList();

  @override
  Future<void> put(Device device) async => _devices[device.id] = device;

  @override
  Future<bool> remove(String id) async => _devices.remove(id) != null;
}
