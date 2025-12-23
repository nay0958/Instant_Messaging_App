import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketService {
  SocketService._();
  static final I = SocketService._();

  IO.Socket? _s;
  final _handlers = <String, List<Function>>{};
  Timer? _keepAliveTimer;
  bool _isReconnecting = false;
  DateTime? _lastReconnectAttempt;
  DateTime? _lastErrorLog;
  static const _errorLogThrottle = Duration(seconds: 30); // Only log errors every 30 seconds

  void connect({required String baseUrl, required String token, bool force = false}) {
    // Log connection attempt
    debugPrint('🔌 SocketService.connect called:');
    debugPrint('   baseUrl: $baseUrl');
    debugPrint('   force: $force');
    debugPrint('   isReconnecting: $_isReconnecting');
    
    // Prevent multiple simultaneous connection attempts
    if (_isReconnecting && !force) {
      debugPrint('⚠️ Connection attempt already in progress, skipping...');
      return;
    }
    
    // Throttle reconnection attempts (max once per 1 second, or allow if forced)
    if (!force && _lastReconnectAttempt != null) {
      final timeSinceLastAttempt = DateTime.now().difference(_lastReconnectAttempt!);
      if (timeSinceLastAttempt.inSeconds < 1) {
        debugPrint('⚠️ Reconnection throttled (last attempt ${timeSinceLastAttempt.inSeconds}s ago)');
        return;
      }
    }
    
    _isReconnecting = true;
    _lastReconnectAttempt = DateTime.now();
    
    disconnect();
    
    // Try websocket first, fallback to polling if websocket fails
    // This is more reliable across different network configurations
    debugPrint('🔌 Connecting to socket: $baseUrl');
    _s = IO.io(
      baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling']) // Fallback to polling if websocket fails
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(999999) // Keep trying to reconnect indefinitely
          .setReconnectionDelay(1000) // Start with 1 second delay
          .setReconnectionDelayMax(5000) // Max 5 seconds between attempts
          .setTimeout(10000) // Reduced timeout to 10 seconds (fail faster)
          .disableAutoConnect() // We'll call connect() manually
          .build(),
    );

    for (final ev in [
      'chat_request',
      'chat_request_accepted',
      'chat_request_declined',
      'message',
      'message_deleted',
      'typing',
      'message_edited',
      'presence',
      'delivered',
      'read_up_to',
      'call:incoming',
      'call:ringing',
      'call:answer',
      'call:candidate',
      'call:declined',
      'call:ended',
      'callEnded', // Call termination signal (new)
      'call:busy',
      'callCancelled', // Call canceled by caller before receiver answers
      'CANCEL', // CANCEL signal when caller hangs up (critical for dismissing UI)
      'user_profile_updated',
    ]) {
      _s!.on(ev, (data) => _emit(ev, data));
    }

    _s!.onConnect((_) {
      _isReconnecting = false;
      _emit('__connect__', null);
      _startKeepAlive();
      final transport = _s?.io?.engine?.transport?.name ?? 'unknown';
      debugPrint('✅ Socket connected successfully (transport: $transport)');
    });
    _s!.onDisconnect((reason) {
      debugPrint('Socket disconnected: $reason');
      _emit('__disconnect__', reason);
      _stopKeepAlive();
      _isReconnecting = false; // Reset reconnecting flag on disconnect
      
      // Socket.io should auto-reconnect, but log to verify
      final reasonStr = reason.toString().toLowerCase();
      if (reasonStr.contains('transport close') || 
          reasonStr.contains('transport error')) {
        debugPrint('Transport closed - socket.io should auto-reconnect');
      }
    });
    _s!.onReconnect((attemptNumber) {
      _isReconnecting = false;
      debugPrint('✅ Socket reconnected successfully after $attemptNumber attempts');
      _emit('__reconnect__', attemptNumber);
      _startKeepAlive();
    });
    
    _s!.onReconnectAttempt((attemptNumber) {
      debugPrint('🔄 Socket.io reconnection attempt #$attemptNumber');
    });
    
    _s!.onReconnectError((error) {
      debugPrint('❌ Socket.io reconnection error: $error');
      debugPrint('   Connection URL: $baseUrl');
      _isReconnecting = false;
    });
    
    _s!.onReconnectFailed((error) {
      debugPrint('❌ Socket.io reconnection failed - will keep trying: $error');
      _isReconnecting = false;
    });
    _s!.onError((e) {
      _isReconnecting = false;
      _emit('__error__', e);
      _stopKeepAlive();
      debugPrint('❌ Socket error: $e');
      debugPrint('   Socket state: connected=${_s?.connected}, disconnected=${_s?.disconnected}');
    });
    _s!.onConnectError((e) {
      _isReconnecting = false;
      _emit('__error__', e);
      _stopKeepAlive();
      debugPrint('❌ Socket connection error: $e');
      debugPrint('   Attempting to connect to: $baseUrl');
      debugPrint('   Check if server is running and accessible');
    });
    _s!.connect();
  }

  /// Start keep-alive ping to maintain connection in background
  void _startKeepAlive() {
    _stopKeepAlive();
    // Send ping every 20 seconds to keep connection alive (before typical 30s timeout)
    // More frequent pings help maintain connection in background
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 20), (timer) {
      if (_s?.connected == true) {
        try {
          // Socket.io has built-in ping/pong, but we can also send a custom event
          // The socket.io client library handles ping/pong automatically
          // This is just an extra safety measure to ensure connection stays alive
          _s?.emit('__ping__', {'ts': DateTime.now().millisecondsSinceEpoch});
        } catch (e) {
          // If emit fails, connection might be dead - try to reconnect
          debugPrint('Keep-alive ping failed: $e');
          _stopKeepAlive();
          // The socket.io client will auto-reconnect
        }
      } else {
        _stopKeepAlive();
      }
    });
  }

  /// Stop keep-alive timer
  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  void onReconnect(void Function() cb) {
    on('__connect__', (_) => cb());
  }

  void onReconnectAttempt(void Function(int) cb) {
    on('__reconnect__', (data) {
      // data should be the attempt number (int)
      if (data is int) {
        cb(data);
      } else if (data is num) {
        cb(data.toInt());
      }
    });
  }

  void onDisconnect(void Function(dynamic) cb) {
    on('__disconnect__', cb);
  }

  void onError(void Function(dynamic) cb) {
    on('__error__', cb);
  }

  void on(String event, Function(dynamic) cb) {
    _handlers.putIfAbsent(event, () => []).add(cb);
  }

  void off(String event, [Function(dynamic)? cb]) {
    if (!_handlers.containsKey(event)) return;
    if (cb == null) {
      _handlers.remove(event);
    } else {
      _handlers[event]!.remove(cb);
    }
  }

  void _emit(String ev, dynamic data) {
    final list = _handlers[ev];
    if (list == null) return;
    for (final cb in List<Function>.from(list)) {
      cb(data);
    }
  }

  void emit(String event, [dynamic data]) {
    _s?.emit(event, data);
  }

  /// Emit message from FCM (when socket is disconnected)
  /// This allows FCM messages to be processed by existing socket message handlers
  void emitMessageFromFCM(Map<String, dynamic> message) {
    // Emit through internal handler system so existing handlers receive it
    _emit('message', message);
  }

  void disconnect() {
    _isReconnecting = false;
    _stopKeepAlive();
    _s?.dispose();
    _s = null;
    _handlers.clear();
  }

  bool get isConnected => _s?.connected == true;
}
