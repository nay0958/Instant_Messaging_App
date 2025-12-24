import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'socket_service.dart';
import 'api.dart';
import 'auth_store.dart';

/// Unified message provider that handles messages from both Socket.io and FCM
/// When socket is disconnected, messages are received via FCM push notifications
class MessageProvider {
  static MessageProvider? _instance;
  static MessageProvider get instance {
    _instance ??= MessageProvider._();
    return _instance!;
  }

  MessageProvider._();

  bool _isInitialized = false;

  /// Initialize message provider
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('MessageProvider already initialized');
      return;
    }

    _isInitialized = true;
    debugPrint('✅ MessageProvider initialized');
  }

  /// Process FCM message when socket is disconnected
  /// Emits the message as if it came from socket, so existing handlers work
  static void processFCMessage(RemoteMessage message) {
    try {
      final data = message.data;
      final messageType = data['type']?.toString() ?? '';
      final isSocketConnected = SocketService.I.isConnected;

      // Only process regular messages (not calls - those are handled separately)
      if (messageType == 'message' || messageType.isEmpty) {
        // Convert FCM message to socket message format
        final socketMessage = _convertFCMToSocketMessage(message);
        debugPrint('📨 FCM message converted: ${socketMessage['_id'] ?? socketMessage['id']}');
        
        if (!isSocketConnected) {
          debugPrint('📱 Socket disconnected - emitting FCM message as socket message');
          // Emit as socket message by directly calling socket handlers
          // This makes FCM messages work with existing socket message handlers
          SocketService.I.emitMessageFromFCM(socketMessage);
        } else {
          debugPrint('📱 Socket connected - FCM message processed as backup (socket may have missed it)');
          // Even if socket is connected, process FCM message as backup
          // This ensures messages aren't lost if socket connection is unstable
          SocketService.I.emitMessageFromFCM(socketMessage);
        }
      }
    } catch (e) {
      debugPrint('❌ Error processing FCM message: $e');
    }
  }

  /// Convert FCM RemoteMessage to socket message format
  /// Note: FCM uses 'senderId' and 'recipientId' instead of 'from' and 'to' (reserved keys)
  /// CRITICAL: Ensure messageId is consistent across FCM and socket handlers
  static Map<String, dynamic> _convertFCMToSocketMessage(RemoteMessage message) {
    final data = message.data;
    
    // CRITICAL: Use consistent messageId format - prefer messageId, then _id, then id
    // This ensures FCM handler and socket handler use the same ID for duplicate detection
    final messageId = data['messageId']?.toString().trim() ?? 
                     data['_id']?.toString().trim() ?? 
                     data['id']?.toString().trim() ?? 
                     DateTime.now().millisecondsSinceEpoch.toString();
    
    return {
      '_id': messageId, // Use same ID for both _id and id fields
      'id': messageId,
      'messageId': messageId, // Also include messageId field for consistency
      // FCM uses 'senderId' and 'recipientId' instead of 'from' and 'to' (reserved keys)
      'from': data['senderId']?.toString() ?? data['from']?.toString() ?? '',
      'to': data['recipientId']?.toString() ?? data['to']?.toString() ?? '',
      'text': data['text']?.toString() ?? 
              data['message']?.toString() ?? 
              message.notification?.body ?? '',
      'conversationId': data['conversationId']?.toString() ?? 
                       data['conversation']?.toString(),
      'conversation': data['conversationId']?.toString() ?? 
                     data['conversation']?.toString(),
      'fileUrl': data['fileUrl']?.toString(),
      'fileName': data['fileName']?.toString(),
      'fileType': data['fileType']?.toString(),
      'createdAt': data['createdAt']?.toString() ?? 
                   DateTime.now().toIso8601String(),
      'replyTo': data['replyTo']?.toString(),
      'replyToMessage': data['replyToMessage'],
      'messageType': data['messageType']?.toString(),
      'callActivity': data['callActivity'] == true,
    };
  }

  /// Dispose and cleanup
  void dispose() {
    _isInitialized = false;
    debugPrint('MessageProvider disposed');
  }
}

/// Update FCM token to backend
Future<bool> updateFCMTokenToBackend(String? fcmToken) async {
  if (fcmToken == null || fcmToken.isEmpty) {
    debugPrint('⚠️ FCM token is empty, cannot update to backend');
    return false;
  }

  try {
    final response = await patchJson('/users/me', {
      'fcmToken': fcmToken,
    });

    if (response.statusCode == 200) {
      debugPrint('✅ FCM token updated to backend successfully');
      return true;
    } else if (response.statusCode == 404) {
      // User doesn't exist in database (e.g., all users were deleted)
      debugPrint('❌ Failed to update FCM token: User not found (404)');
      debugPrint('💡 This usually means:');
      debugPrint('   - User was deleted from database');
      debugPrint('   - Auth token is invalid or expired');
      debugPrint('   - User needs to register/login again');
      debugPrint('💡 FCM token will be saved after user logs in again');
      
      // Optionally clear auth token to force re-login
      // Uncomment the next line if you want to automatically clear auth on 404
      // await AuthStore.clear();
      
      return false;
    } else if (response.statusCode == 401) {
      // Unauthorized - token expired or invalid
      debugPrint('❌ Failed to update FCM token: Unauthorized (401)');
      debugPrint('💡 Auth token is invalid or expired');
      debugPrint('💡 User needs to login again');
      return false;
    } else {
      debugPrint('❌ Failed to update FCM token: ${response.statusCode} - ${response.body}');
      return false;
    }
  } catch (e) {
    debugPrint('❌ Error updating FCM token to backend: $e');
    return false;
  }
}
