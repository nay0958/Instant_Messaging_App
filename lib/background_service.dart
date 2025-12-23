import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'socket_service.dart';
import 'api.dart';
import 'auth_store.dart';

/// Service to keep the app active in background
/// This helps maintain socket connections and keep users online
class BackgroundService {
  static BackgroundService? _instance;
  static BackgroundService get instance {
    _instance ??= BackgroundService._();
    return _instance!;
  }

  BackgroundService._();

  bool _isActive = false;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;

  /// Start keeping the app active in background
  Future<void> start() async {
    if (_isActive) {
      debugPrint('BackgroundService already active');
      return;
    }

    try {
      // Enable wakelock to prevent device from sleeping
      await WakelockPlus.enable();
      _isActive = true;
      debugPrint('✅ BackgroundService started - app will stay active in background');

      // Monitor socket connection status
      // Note: Android blocks network access in background, so socket will disconnect
      // This is expected behavior - FCM will handle messages when socket is disconnected
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
        if (!_isActive) {
          timer.cancel();
          return;
        }

        final isConnected = SocketService.I.isConnected;
        if (!isConnected) {
          // Socket disconnected in background - this is normal Android behavior
          // FCM will handle all messages when socket is disconnected
          if (timer.tick % 2 == 0) { // Log every 60 seconds
            debugPrint('⚠️ BackgroundService: Socket disconnected (normal in background)');
            debugPrint('💡 FCM push notifications will handle messages');
          }
          // Don't try to reconnect aggressively - Android blocks network in background
          // Socket will reconnect automatically when app comes to foreground
        } else {
          // Connection is alive - log periodically
          if (timer.tick % 2 == 0) { // Log every 60 seconds
            debugPrint('✅ BackgroundService: Socket connection is active');
          }
        }
      });

      // Immediate check on start
      if (!SocketService.I.isConnected) {
        debugPrint('⚠️ BackgroundService: Socket not connected on start, reconnecting...');
        _reconnectSocket();
      }
    } catch (e) {
      debugPrint('❌ Error starting BackgroundService: $e');
    }
  }

  /// Reconnect socket (only when app comes to foreground)
  /// In background, Android blocks network, so we rely on FCM
  Future<void> _reconnectSocket() async {
    // Don't try to reconnect in background - Android blocks network access
    // Socket.io's built-in reconnection will handle it when app comes to foreground
    // FCM will handle all messages when socket is disconnected
    debugPrint('💡 BackgroundService: Socket reconnection skipped (Android blocks network in background)');
    debugPrint('💡 FCM push notifications will deliver messages');
  }

  /// Stop keeping the app active
  Future<void> stop() async {
    if (!_isActive) {
      return;
    }

    try {
      await WakelockPlus.disable();
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _isActive = false;
      debugPrint('BackgroundService stopped');
    } catch (e) {
      debugPrint('❌ Error stopping BackgroundService: $e');
    }
  }

  bool get isActive => _isActive;
}
