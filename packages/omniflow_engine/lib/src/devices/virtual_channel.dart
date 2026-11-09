import 'channels.dart';

/// The channel for things with the `virtual` transport. Nothing goes on a
/// wire: a command is accepted as sent, so the engine's optimistic state
/// becomes the thing's state, and inputs reach the thing through
/// `DeviceService.mergeState` and `thing.event`.
class VirtualChannel implements DriverChannel {
  const VirtualChannel();

  @override
  Future<ChannelReply> send(ChannelRequest request) async =>
      const ChannelReply({});
}
