import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketService {
  SocketService._();
  static final I = SocketService._();

  IO.Socket? _s;
  final _handlers = <String, List<Function>>{};

  void connect({required String baseUrl, required String token}) {
    disconnect();
    _s = IO.io(
      baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(10)
          .setReconnectionDelay(1000)
          .disableAutoConnect()
          .build(),
    );
    // pipe events to listeners
    for (final ev in [
      'chat_request',
      'chat_request_accepted',
      'chat_request_declined',
      'message',
    ]) {
      _s!.on(ev, (data) => _emit(ev, data));
    }
    _s!.onConnect((_) => _emit('__connect__', null));
    _s!.onDisconnect((_) => _emit('__disconnect__', null));
    _s!.onError((e) => _emit('__error__', e));
    _s!.onConnectError((e) => _emit('__error__', e));
    _s!.connect();
  }

  void on(String event, Function(dynamic) cb) {
    _handlers.putIfAbsent(event, () => []).add(cb);
  }

  void off(String event, [Function(dynamic)? cb]) {
    if (!_handlers.containsKey(event)) return;
    if (cb == null)
      _handlers.remove(event);
    else
      _handlers[event]!.remove(cb);
  }

  void _emit(String ev, dynamic data) {
    final list = _handlers[ev];
    if (list == null) return;
    for (final cb in List<Function>.from(list)) {
      cb(data);
    }
  }

  void disconnect() {
    _s?.dispose();
    _s = null;
    _handlers.clear();
  }
}
