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
    this.favourite = false,
    this.order,
  });

  final String id;
  final String name;
  final String driverId;

  /// IP address or host name, `local` for this machine, or a serial port path.
  final String host;

  /// Overrides the driver's default port when set.
  final int? port;

  /// The id of the room record the device is in.
  final String? room;

  /// The id that survives an IP change (MAC, Tuya devId), used to find the
  /// device again through discovery.
  final String? stableId;

  /// Non-secret settings. Secrets live in the secret store.
  final Map<String, Object?> settings;
  final Map<String, Object?> state;
  final DateTime? lastSeen;

  /// Whether the user pinned the device to the home screen.
  final bool favourite;

  /// Where the user placed it among its room's devices, lowest first.
  final int? order;

  bool isOnline(DateTime now, Duration window) =>
      lastSeen != null && now.difference(lastSeen!) <= window;

  Device copyWith({
    String? name,
    String? host,
    int? port,
    String? stableId,
    Map<String, Object?>? settings,
    Map<String, Object?>? state,
    DateTime? lastSeen,
    bool? favourite,
  }) => Device(
    id: id,
    name: name ?? this.name,
    driverId: driverId,
    host: host ?? this.host,
    port: port ?? this.port,
    room: room,
    stableId: stableId ?? this.stableId,
    settings: settings ?? this.settings,
    state: state ?? this.state,
    lastSeen: lastSeen ?? this.lastSeen,
    favourite: favourite ?? this.favourite,
    order: order,
  );

  /// The device in [room] at [order]. Null clears either.
  Device placed({required String? room, required int? order}) => Device(
    id: id,
    name: name,
    driverId: driverId,
    host: host,
    port: port,
    room: room,
    stableId: stableId,
    settings: settings,
    state: state,
    lastSeen: lastSeen,
    favourite: favourite,
    order: order,
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
