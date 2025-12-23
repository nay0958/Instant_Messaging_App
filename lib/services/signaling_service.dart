import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth_store.dart';
import '../socket_service.dart';
import '../call_page.dart';
import '../nav.dart';

/// Central place for starting WebRTC signaling flows (outgoing calls).
class SignalingService {
  SignalingService._();
  static final SignalingService I = SignalingService._();

  static final Uuid _uuid = const Uuid();

  /// Start a new outgoing **video** call to [receiverId].
  ///
  /// - Emits a `phone` event over Socket.io with:
  ///   - `uuid`        – unique call/session id
  ///   - `callerName`  – current user's display name (if available)
  ///   - `receiverId`  – callee user id
  /// - Navigates to the call UI (`CallPage`) which:
  ///   - opens local WebRTC media (camera + mic)
  ///   - starts the WebRTC offer/answer handshake using the existing flow
  Future<void> startVideoCall(String receiverId) async {
    try {
      // Resolve caller name (best‑effort; fall back to "You")
      String callerName = 'You';
      try {
        final me = await AuthStore.getUser();
        final rawName = me?['name']?.toString().trim();
        if (rawName != null && rawName.isNotEmpty) {
          callerName = rawName;
        }
      } catch (_) {
        // Non‑fatal – keep default callerName
      }

      // Ensure socket is connected before emitting
      if (!SocketService.I.isConnected) {
        final token = await AuthStore.getToken();
        if (token != null && token.isNotEmpty) {
          SocketService.I.connect(baseUrl: apiBase, token: token, force: true);
        } else {
          debugPrint('⚠️ startVideoCall: no auth token available, socket may not connect');
        }
      }

      // Generate unique call/session id
      final callUuid = _uuid.v4();

      // Emit the phone event so the backend / callee knows about the call
      try {
        SocketService.I.emit('phone', {
          'uuid': callUuid,
          'callerName': callerName,
          'receiverId': receiverId,
          'kind': 'video',
        });
        debugPrint('📞 startVideoCall: emitted phone event uuid=$callUuid to=$receiverId');
      } catch (e) {
        debugPrint('❌ startVideoCall: error emitting phone event: $e');
      }

      // CRITICAL: Only navigate to CallPage when app is in foreground
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState != AppLifecycleState.resumed) {
        debugPrint('⚠️ startVideoCall: App not in foreground - cannot navigate to CallPage');
        return;
      }

      // Navigate to the streaming / call screen.
      // In this codebase `CallPage` is the video call screen that:
      //  - opens local WebRTC stream in _openMedia()
      //  - performs WebRTC signaling via Socket.io
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        debugPrint('❌ startVideoCall: navigatorKey.currentState is null, cannot navigate');
        return;
      }

      navigator.push(
        MaterialPageRoute(
          builder: (_) => CallPage(
            peerId: receiverId,
            peerName: callerName,
            outgoing: true,
            video: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ startVideoCall: unexpected error: $e');
    }
  }
}

