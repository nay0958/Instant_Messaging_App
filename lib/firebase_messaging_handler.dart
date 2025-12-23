import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'nav.dart';
import 'call_page.dart';
import 'auth_store.dart';
import 'socket_service.dart';
import 'notifications.dart';
import 'api.dart';
import 'message_provider.dart';

/// Helper function to parse SDP from FCM data (may be stringified JSON)
/// This is a top-level function that can be called from background isolates
@pragma('vm:entry-point')
dynamic parseSdpFromData(dynamic sdpData) {
  if (sdpData == null) return null;
  if (sdpData is Map) return sdpData; // Already a Map
  if (sdpData is String) {
    try {
      return jsonDecode(sdpData); // Try to parse JSON string
    } catch (e) {
      debugPrint('Failed to parse SDP string: $e');
      return null;
    }
  }
  return sdpData;
}

/// Helper function to mask sensitive tokens in logs
/// Shows first 8 and last 8 characters, masks the middle
String maskToken(String? token) {
  if (token == null || token.isEmpty) return 'null';
  if (token.length <= 16) return '${'*' * token.length}';
  final start = token.substring(0, 8);
  final end = token.substring(token.length - 8);
  return '$start...$end';
}

/// Top-level function for background message handler
/// Must be a top-level function, not a class method
/// This runs in a separate isolate when app is in background or terminated
/// 
/// Shows call banner immediately when type == 'CALL' using:
/// - 'call_id': Call ID from FCM payload
/// - 'caller_name': Caller name from FCM payload
/// - 'avatar': Avatar URL of the caller
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('🚀 BACKGROUND HANDLER CALLED - App is in background/terminated state');
  debugPrint('📱 Message received in background isolate');
  
  // Initialize Firebase in background isolate (if not already initialized)
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase initialized in background isolate');
  } catch (e) {
    // Firebase might already be initialized, or initialization might fail
    debugPrint('⚠️ Firebase initialization in background: $e');
  }
  
  // Initialize local notifications in background isolate
  await Noti.init();
  
  // Create CallKit notification channel in background isolate (if not already created)
  try {
    if (Platform.isAndroid) {
      final plugin = FlutterLocalNotificationsPlugin();
      final androidImplementation = plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidImplementation != null) {
        const channel = AndroidNotificationChannel(
          'calls',  // Channel ID for incoming calls
          'Incoming Calls',
          description: 'High priority notifications for incoming calls',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          showBadge: true,
        );
        await androidImplementation.createNotificationChannel(channel);
        debugPrint('✅ Created notification channel "calls" in background isolate');
      }
    }
  } catch (e) {
    debugPrint('❌ Error creating CallKit channel in background: $e');
  }
  
  // Handle the message - check if it's a call notification
  final data = message.data;
  final messageType = data['type']?.toString().toUpperCase() ?? '';
  
  // Log all data for debugging - CRITICAL for troubleshooting
  debugPrint('📱 Background FCM message received:');
  debugPrint('   MessageId: ${message.messageId}');
  debugPrint('   Data: $data');
  debugPrint('   Data keys: ${data.keys.toList()}');
  debugPrint('   Type: "$messageType" (original: ${data['type']})');
  debugPrint('   Type == "CALL": ${messageType == 'CALL'}');
  debugPrint('   Has notification: ${message.notification != null}');
  
  // Check if this is a call termination notification (CANCEL, CALL_ENDED, or CALL_CANCELLED)
  final isCallEnded = messageType == 'CANCEL' ||
                      messageType == 'CALL_ENDED' || 
                      messageType == 'CALL_CANCELLED' ||
                      data['action']?.toString().toLowerCase() == 'dismiss';
  
  if (isCallEnded) {
    // Call was ended/cancelled - dismiss CallKit UI immediately
    debugPrint('📞 Call termination notification received (type: $messageType) - dismissing CallKit UI');
    final callId = data['call_id']?.toString() ?? '';
    final timestamp = data['timestamp'];
    
    debugPrint('   Call ID: $callId');
    debugPrint('   Timestamp: $timestamp');
    
    try {
      await FlutterCallkitIncoming.endAllCalls();
      debugPrint('✅ All CallKit UI dismissed due to call termination (callId: $callId)');
      
      // Note: Cannot access _pendingCalls/_processedCallIds from top-level function
      // These will be cleaned up when the main handler processes the message
    } catch (e) {
      debugPrint('⚠️ Error dismissing CallKit UI on termination: $e');
      // Try to end specific call if endAllCalls fails
      if (callId.isNotEmpty) {
        try {
          await FlutterCallkitIncoming.endCall(callId);
          debugPrint('✅ CallKit UI dismissed for specific call: $callId');
        } catch (e2) {
          debugPrint('⚠️ Error dismissing specific call UI: $e2');
        }
      }
    }
    return; // Don't process further
  }
  
  // Check if this is a call notification - Support both 'CALL' and lowercase 'call'
  // Also check for call-related fields as fallback
  final isCallNotification = messageType == 'CALL' ||
      messageType == 'VOICE' ||
      messageType == 'VIDEO' ||
      data.containsKey('caller_name') ||
      data.containsKey('nameCaller') ||
      data['call_id'] != null ||
      data['callId'] != null;
  
  if (isCallNotification) {
    debugPrint('📞 Call notification detected - checking validity...');
    
    // Extract required fields from FCM payload (call_id, caller_name, avatar)
    final callId = data['call_id']?.toString() ?? 
                   DateTime.now().millisecondsSinceEpoch.toString();
    final callerName = data['caller_name']?.toString() ?? 'Unknown Caller';
    final avatar = data['avatar']?.toString();
    final callerId = data['callerId']?.toString() ?? data['from']?.toString() ?? '';
    
    // Check timestamp to prevent showing expired calls
    final timestamp = data['timestamp'];
    if (timestamp != null) {
      final callTimestamp = timestamp is int 
          ? timestamp 
          : (timestamp is num ? timestamp.toInt() : null);
      
      if (callTimestamp != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final difference = now - callTimestamp;
        const maxAgeSeconds = 5; // 5 seconds max age for call signals
        const maxAgeMs = maxAgeSeconds * 1000;
        
        if (difference > maxAgeMs) {
          debugPrint('❌ Call expired in background handler - timestamp: $callTimestamp, now: $now, difference: ${difference}ms (>${maxAgeMs}ms)');
          debugPrint('Call expired');
          // Clean up any existing call UI for this expired call
          try {
            await FlutterCallkitIncoming.endAllCalls();
            debugPrint('✅ Cleaned up expired call UI');
          } catch (e) {
            debugPrint('⚠️ Error cleaning up expired call: $e');
          }
          return; // Don't show expired call
        } else {
          debugPrint('✅ Call is valid - timestamp: $callTimestamp, now: $now, difference: ${difference}ms (<=${maxAgeMs}ms)');
        }
      }
    }
    
    // Determine if video call
    final isVideo = data['isVideoCall']?.toString().toLowerCase() == 'true' || 
                   data['kind']?.toString().toLowerCase() == 'video';
    
    debugPrint('   Call ID: $callId');
    debugPrint('   Caller Name: $callerName');
    debugPrint('   Avatar: ${avatar ?? "not provided"}');
    debugPrint('   Type: ${isVideo ? "video" : "voice"}');
    
    // CRITICAL: End all existing calls before showing new one
    // This prevents multiple old banners from appearing
    debugPrint('🧹 Ending all existing calls before showing new call banner...');
    try {
      await FlutterCallkitIncoming.endAllCalls();
      debugPrint('✅ All existing call UI dismissed');
    } catch (e) {
      debugPrint('⚠️ Error ending existing calls: $e');
      // Try to end specific call if endAllCalls fails
      if (callId.isNotEmpty) {
        try {
          await FlutterCallkitIncoming.endCall(callId);
          debugPrint('✅ Existing call UI dismissed for callId: $callId');
        } catch (e2) {
          debugPrint('⚠️ Error ending specific call: $e2');
        }
      }
    }
    
    // Show CallKit banner IMMEDIATELY - do NOT wait for socket connection
    // The phone must ring immediately when call notification arrives
    try {
      final params = CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'Messaging App',
        avatar: avatar,
        handle: callerId.isNotEmpty ? callerId : callId,
        type: isVideo ? 1 : 0, // 1 = video, 0 = voice
        duration: 30000, // 30 seconds timeout
        textAccept: 'Accept',
        textDecline: 'Decline',
        textMissedCall: 'Missed Call',
        textCallback: 'Call Back',
        extra: <String, dynamic>{
          'callerId': callerId,
          'callerName': callerName,
          'isVideo': isVideo,
          'callId': callId,
          'call_id': callId,
          'caller_name': callerName,
          'avatar': avatar ?? '',
          'sdp': parseSdpFromData(data['sdp']),
          'kind': isVideo ? 'video' : 'voice',
        },
        headers: <String, dynamic>{},
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          ringtonePath: 'system_default',
          backgroundColor: '#FFB19CD9',
          backgroundUrl: avatar,
          actionColor: '#0955fa',
        ),
        ios: IOSParams(
          iconName: 'CallKitLogo',
          handleType: 'generic',
          supportsVideo: isVideo,
          maximumCallGroups: 2,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'default',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: true,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );
      
      // CRITICAL: End any existing pending calls before showing new one
      // This prevents CallKit from blocking new calls when there's leftover state
      debugPrint('🧹 Cleaning up any existing pending calls before showing new call...');
      try {
        // Try to end any existing calls by attempting to end calls from pending list
        // Note: In background isolate, we don't have access to _pendingCalls, so we skip this
        // The main handler will handle cleanup
        debugPrint('   Background handler: Skipping cleanup (handled by main handler)');
      } catch (e) {
        debugPrint('   ⚠️ Error during cleanup: $e');
        // Continue even if cleanup fails
      }

      // Show CallKit banner immediately using FlutterCallkitIncoming.showCallkitIncoming()
      // NO socket operations - banner shows and phone rings immediately
      debugPrint('📞 Attempting to show CallKit banner in background...');
      try {
        await FlutterCallkitIncoming.showCallkitIncoming(params);
        debugPrint('✅ CallKit banner shown successfully - phone should be ringing');
      } catch (callKitError) {
        debugPrint('❌ Error calling FlutterCallkitIncoming.showCallkitIncoming: $callKitError');
        debugPrint('💡 This might be due to Android background restrictions');
        // Re-throw to trigger fallback
        rethrow;
      }
    } catch (e) {
      debugPrint('❌ Error showing CallKit banner: $e');
      debugPrint('💡 Stack trace: ${StackTrace.current}');
      
      // Fallback: Show high-priority local notification with full-screen intent
      // This will wake the screen and can launch CallKit activity
      try {
        final plugin = FlutterLocalNotificationsPlugin();
        final androidImplementation = plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        
        if (androidImplementation != null) {
          // Create full-screen intent to launch CallKit activity
          const androidDetails = AndroidNotificationDetails(
            'calls',
            'Incoming Calls',
            channelDescription: 'High priority notifications for incoming calls',
            importance: Importance.max,
            priority: Priority.max,
            fullScreenIntent: true, // This wakes the screen and shows full-screen
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.call,
          );
          
          await plugin.show(
            callId.hashCode,
            'Incoming Call',
            callerName,
            NotificationDetails(android: androidDetails),
            payload: jsonEncode(data.map((key, value) => MapEntry(key, value.toString()))),
          );
          debugPrint('✅ Fallback full-screen notification shown - should wake screen');
        } else {
          // Fallback to regular notification
          await Noti.show(
            title: 'Incoming Call',
            body: callerName,
            payload: data.map((key, value) => MapEntry(key, value.toString())),
          );
          debugPrint('✅ Fallback local notification shown');
        }
      } catch (notifError) {
        debugPrint('❌ Failed to show fallback local notification: $notifError');
      }
    }
  } else {
    // Regular message - handle normally
    await FirebaseMessagingHandler.handleBackgroundMessage(message);
  }
}

/// Show CallKit incoming call UI from background handler
/// This is a top-level function that can be called from the background isolate
/// Do NOT perform any socket operations in this function - only show the banner
@pragma('vm:entry-point')
Future<void> _showCallKitIncomingFromBackground(RemoteMessage message) async {
  try {
    final data = message.data;
    
    // Extract call information from FCM payload
    // Backend sends: call_id, caller_name, callerId
    // Use the exact field names from the FCM payload
    final callId = data['call_id']?.toString() ?? 
                   DateTime.now().millisecondsSinceEpoch.toString();
    final callerName = data['caller_name']?.toString() ?? 
                       'Unknown Caller';
    final callerId = data['callerId']?.toString() ?? 
                     data['from']?.toString() ?? 
                     '';
    final avatarUrl = data['avatar']?.toString();
    
    // Determine if video call from data fields
    final isVideo = data['isVideoCall']?.toString().toLowerCase() == 'true' || 
                   data['kind']?.toString().toLowerCase() == 'video';

    // Validate required fields
    if (callId.isEmpty) {
      debugPrint('⚠️ Cannot show call UI: call_id is empty');
      return;
    }
    
    if (callerName.isEmpty || callerName == 'Unknown Caller') {
      debugPrint('⚠️ Warning: caller_name is empty or unknown');
    }

    debugPrint('📞 Background call notification - showing CallKit banner:');
    debugPrint('   Call ID: $callId');
    debugPrint('   Caller Name: $callerName');
    debugPrint('   Caller ID: $callerId');
    debugPrint('   Type: ${isVideo ? "video" : "voice"}');
    debugPrint('   Avatar: $avatarUrl');

    // Build CallKit parameters - do NOT perform socket operations here
    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'Messaging App',
      avatar: avatarUrl,
      handle: callerId.isNotEmpty ? callerId : callId,
      type: isVideo ? 1 : 0, // 1 = video, 0 = voice
      duration: 30000, // 30 seconds timeout
      textAccept: 'Accept',
      textDecline: 'Decline',
      textMissedCall: 'Missed Call',
      textCallback: 'Call Back',
      extra: <String, dynamic>{
        'callerId': callerId,
        'callerName': callerName,
        'isVideo': isVideo,
        'callId': callId,
        'call_id': callId, // Store both for compatibility
        'caller_name': callerName, // Store both for compatibility
        'sdp': parseSdpFromData(data['sdp']), // SDP offer if available
        'kind': isVideo ? 'video' : 'voice',
      },
      headers: <String, dynamic>{},
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: true,
        ringtonePath: 'system_default',
        backgroundColor: '#FFB19CD9',
        backgroundUrl: avatarUrl,
        actionColor: '#0955fa',
      ),
      ios: IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    // Show CallKit banner immediately - no socket operations before this
    await FlutterCallkitIncoming.showCallkitIncoming(params);
    debugPrint('✅ CallKit incoming call banner shown for: $callerName');
  } catch (e) {
    debugPrint('❌ Error showing CallKit incoming from background: $e');
  }
}

class FirebaseMessagingHandler {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final Uuid _uuid = const Uuid();
  static StreamSubscription? _callKitSubscription;
  static Map<String, Map<String, dynamic>> _pendingCalls = {};
  static final Set<String> _processedCallIds = <String>{}; // Track processed call IDs to prevent loops

  /// Initialize Firebase Messaging
  static Future<void> initialize() async {
    // Verify Firebase is initialized
    try {
      Firebase.app(); // This will throw if Firebase is not initialized
    } catch (e) {
      debugPrint('❌ Firebase not initialized before FirebaseMessagingHandler.initialize()');
      throw Exception('Firebase must be initialized before FirebaseMessagingHandler.initialize()');
    }
    
    // Initialize local notifications first
    await Noti.init(onTap: _handleNotificationTap);
    
    // Create high-importance notification channel for CallKit
    await _createCallKitNotificationChannel();
    
    // Request System Alert Window permission for Android (required for banner overlay)
    if (Platform.isAndroid) {
      await _requestSystemAlertWindowPermission();
    }
    
    // Request permission
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('✅ User granted notification permission');
    } else if (settings.authorizationStatus == AuthorizationStatus.provisional) {
      debugPrint('⚠️ User granted provisional notification permission');
    } else {
      debugPrint('❌ User declined or has not accepted notification permission');
    }

    // Background message handler is registered in main.dart before Firebase initialization
    // This ensures it's available for background messages
    // FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler); // Moved to main.dart

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle notification taps when app is in background/terminated
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // Check if app was opened from a terminated state
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App opened from terminated state via notification');
      _handleMessageOpenedApp(initialMessage);
    }

    // Set up global CallKit event listener
    _setupGlobalCallKitListener();
    
    // Set up socket listener for call cancellation
    _setupCallCancelledListener();

    // Get FCM token and update to backend
    String? token;
    try {
      token = await _messaging.getToken();
      debugPrint('✅ FCM Token retrieved: ${maskToken(token)}');
    } catch (e) {
      debugPrint('❌ Error getting FCM token: $e');
      token = null;
    }
    
    // Diagnose why token might be null
    if (token == null) {
      debugPrint('⚠️ FCM Token is NULL - Diagnosing issue...');
      
      // Check platform
      if (Platform.isIOS) {
        debugPrint('   Platform: iOS');
        // Check if running on simulator
        try {
          // iOS Simulators don't support FCM tokens
          debugPrint('   ⚠️ iOS Simulator detected - FCM tokens only work on real iOS devices');
          debugPrint('   💡 To get FCM token, test on a real iOS device');
        } catch (_) {
          debugPrint('   💡 If running on iOS Simulator, FCM tokens are not supported');
        }
      } else if (Platform.isAndroid) {
        debugPrint('   Platform: Android');
        debugPrint('   💡 Check that google-services.json is properly configured');
        debugPrint('   💡 Verify Firebase project is set up correctly');
      }
      
      // Check permission status
      final currentSettings = await _messaging.getNotificationSettings();
      debugPrint('   Notification permission status: ${currentSettings.authorizationStatus}');
      if (currentSettings.authorizationStatus != AuthorizationStatus.authorized &&
          currentSettings.authorizationStatus != AuthorizationStatus.provisional) {
        debugPrint('   ⚠️ Notification permission not granted - this may cause token to be null');
        debugPrint('   💡 User needs to grant notification permissions');
      }
      
      // Check Firebase initialization
      try {
        final app = Firebase.app();
        debugPrint('   ✅ Firebase app initialized: ${app.name}');
      } catch (e) {
        debugPrint('   ❌ Firebase app not properly initialized: $e');
      }
      
      debugPrint('   💡 FCM token will be retried when token refresh event fires');
      debugPrint('   💡 Token may become available after permissions are granted');
    } else {
      // Token is available - update to backend
      await updateFCMTokenToBackend(token);
    }
    
    // Listen for token refresh (this will fire when token becomes available)
    _messaging.onTokenRefresh.listen((newToken) async {
      debugPrint('🔄 FCM Token refreshed: ${maskToken(newToken)}');
      if (newToken != null && newToken.isNotEmpty) {
        // Update new token to backend
        await updateFCMTokenToBackend(newToken);
      } else {
        debugPrint('⚠️ Token refresh event fired but token is still null/empty');
      }
    });
  }
  
  /// Create high-importance notification channel for CallKit
  /// This channel will be used for incoming call notifications
  static Future<void> _createCallKitNotificationChannel() async {
    if (!Platform.isAndroid) return;
    
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      final androidImplementation = plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidImplementation != null) {
        // Create channel with maximum importance for heads-up display
        const channel = AndroidNotificationChannel(
          'calls', // Channel ID for incoming calls
          'Incoming Calls', // Channel name
          description: 'High priority notifications for incoming calls',
          importance: Importance.max, // Maximum importance for heads-up display
          playSound: true,
          enableVibration: true,
          showBadge: true,
        );
        
        await androidImplementation.createNotificationChannel(channel);
        debugPrint('✅ CallKit notification channel created:');
        debugPrint('   Channel ID: calls');
        debugPrint('   Importance: MAX (heads-up display enabled)');
        debugPrint('   Sound: enabled');
        debugPrint('   Vibration: enabled');
      } else {
        debugPrint('⚠️ Could not get Android notification implementation');
      }
    } catch (e) {
      debugPrint('❌ Error creating CallKit notification channel: $e');
    }
  }
  
  /// Request System Alert Window permission (required for drawing over other apps)
  static Future<bool> _requestSystemAlertWindowPermission() async {
    try {
      final status = await Permission.systemAlertWindow.status;
      
      if (status.isGranted) {
        debugPrint('✅ System Alert Window permission already granted');
        return true;
      }
      
      if (status.isDenied) {
        debugPrint('⚠️ System Alert Window permission denied - requesting...');
        final result = await Permission.systemAlertWindow.request();
        
        if (result.isGranted) {
          debugPrint('✅ System Alert Window permission granted');
          return true;
        } else {
          debugPrint('❌ System Alert Window permission denied by user');
          debugPrint('💡 Call banner may not work properly without this permission');
          debugPrint('💡 User can enable it manually in app settings');
          return false;
        }
      }
      
      // Permission is permanently denied, need to open settings
      if (status.isPermanentlyDenied) {
        debugPrint('⚠️ System Alert Window permission permanently denied');
        debugPrint('💡 Opening app settings for user to enable permission');
        await openAppSettings();
        return false;
      }
      
      return false;
    } catch (e) {
      debugPrint('❌ Error checking System Alert Window permission: $e');
      return false;
    }
  }
  
  /// Check if System Alert Window permission is granted
  static Future<bool> hasSystemAlertWindowPermission() async {
    if (!Platform.isAndroid) return true; // Not needed on iOS
    
    try {
      final status = await Permission.systemAlertWindow.status;
      return status.isGranted;
    } catch (e) {
      debugPrint('Error checking System Alert Window permission: $e');
      return false;
    }
  }
  
  /// Handle notification tap
  static void _handleNotificationTap(String payload) {
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      debugPrint('Notification tapped with payload: $data');
      
      // Handle different notification types
      final type = data['type']?.toString();
      if (type == 'message') {
        // Navigate to chat page
        final peerId = data['from']?.toString() ?? data['peerId']?.toString();
        if (peerId != null && peerId.isNotEmpty) {
          // Navigation will be handled by the app's routing
          debugPrint('Should navigate to chat with: $peerId');
        }
      } else if (type == 'call') {
        // Navigate to call page
        _navigateToCallPage(data);
      }
    } catch (e) {
      debugPrint('Error handling notification tap: $e');
    }
  }

  /// Set up global CallKit event listener
  static void _setupGlobalCallKitListener() {
    // Cancel existing subscription if any
    _callKitSubscription?.cancel();
    
    // Listen to all CallKit events globally
    _callKitSubscription = FlutterCallkitIncoming.onEvent.listen((event) async {
      if (event == null) return;

      final callId = event.body?['id']?.toString() ?? 
                    event.body?['uuid']?.toString() ?? '';
      
      if (callId.isEmpty) {
        return; // Silent skip - no callId
      }

      // CRITICAL: Prevent processing the same event multiple times (infinite loop protection)
      // Use a more specific key that includes timestamp to prevent stale events
      final eventKey = '${event.event}_$callId';
      if (_processedCallIds.contains(eventKey)) {
        return; // Silent skip - already processed (prevents infinite loops)
      }
      // Mark as processed BEFORE processing to prevent race conditions
      _processedCallIds.add(eventKey);
      
      // Clean up old processed IDs (keep last 50 to prevent memory leak)
      if (_processedCallIds.length > 50) {
        final idsList = _processedCallIds.toList();
        idsList.removeRange(0, 25);
        _processedCallIds.clear();
        _processedCallIds.addAll(idsList);
      }

      // Get pending call data
      // First try from _pendingCalls (for foreground calls)
      Map<String, dynamic>? callData = _pendingCalls[callId];
      
      // If not found, try to get from CallKit extra data (for background calls)
      if (callData == null) {
        final extra = event.body?['extra'];
        if (extra is Map) {
          callData = Map<String, dynamic>.from(extra);
          // Store it for future reference
          _pendingCalls[callId] = callData;
        }
      }
      
      // If still not found, try to extract from event body
      if (callData == null) {
        final body = event.body;
        if (body is Map) {
          callData = {
            'callerId': body['handle']?.toString() ?? body['callerId']?.toString() ?? '',
            'callerName': body['nameCaller']?.toString() ?? body['callerName']?.toString() ?? 'Unknown',
            'isVideo': (body['type'] == 1) || (body['isVideo'] == true),
            'callId': callId,
          };
          debugPrint('📱 Extracted call data from event body for callId: $callId');
          // Store it for future reference
          _pendingCalls[callId] = callData;
        }
      }
      
      if (callData == null) {
        // Use minimal data to at least allow call to be handled
        callData = {
          'callerId': event.body?['handle']?.toString() ?? '',
          'callerName': event.body?['nameCaller']?.toString() ?? 'Unknown Caller',
          'isVideo': (event.body?['type'] == 1),
          'callId': callId,
        };
      }

      switch (event.event) {
        case Event.ACTION_CALL_ACCEPT:
          await FlutterCallkitIncoming.endCall(callId);
          // Navigate to call page and start signaling
          await _handleCallAccept(callId, callData);
          break;

        case Event.ACTION_CALL_DECLINE:
          await FlutterCallkitIncoming.endCall(callId);
          _pendingCalls.remove(callId);
          // Clean up processed call IDs for this call to allow future calls with same ID
          _processedCallIds.removeWhere((key) => key.contains(callId));
          // Optionally notify backend that call was declined via Socket.io
          _notifyCallDeclined(callId, callData);
          break;

        case Event.ACTION_CALL_ENDED:
          // CRITICAL: Don't remove processed IDs - keep them to prevent infinite loops
          // The event is already marked as processed above, so this won't be processed again
          // Remove from pending calls
          _pendingCalls.remove(callId);
          // DO NOT call endCall here - it will trigger another ACTION_CALL_ENDED event
          // The call is already ended, we just need to clean up our state
          break;

        case Event.ACTION_CALL_TIMEOUT:
          // Remove from pending calls
          _pendingCalls.remove(callId);
          // DO NOT call endCall here - timeout already ended the call
          // Calling endCall would trigger another event
          break;

        case Event.ACTION_CALL_CALLBACK:
          debugPrint('Call back requested: $callId');
          // Navigate to call page to initiate a call back
          _navigateToCallPage({
            'callId': '',
            'from': callData['callerId']?.toString() ?? '',
            'callerName': callData['callerName']?.toString() ?? 'Unknown',
            'isVideo': callData['isVideo'] ?? false,
          });
          break;

        default:
          break;
      }
    });
  }
  
  /// Set up socket listener for call cancellation and call ended
  /// When caller cancels/ends the call, dismiss CallKit UI
  static void _setupCallCancelledListener() {
    // Remove existing listeners to prevent duplicates
    SocketService.I.off('CANCEL', _handleCancelSignal);
    SocketService.I.off('callCancelled', _handleCallCancelled);
    SocketService.I.off('call:ended', _handleCallEnded);
    SocketService.I.off('callEnded', _handleCallEndedSignal);
    
    // CRITICAL: Listen for CANCEL signal (when caller hangs up)
    SocketService.I.on('CANCEL', _handleCancelSignal);
    
    // Listen for call cancellation event (when caller cancels before receiver answers)
    SocketService.I.on('callCancelled', _handleCallCancelled);
    
    // Listen for callEnded signal (new proper termination signal)
    SocketService.I.on('callEnded', _handleCallEndedSignal);
    
    // Also listen for call:ended (legacy support)
    SocketService.I.on('call:ended', _handleCallEnded);
    debugPrint('✅ Call termination listeners registered (CANCEL, callEnded, callCancelled, call:ended)');
  }
  
  /// Handle CANCEL signal from socket (critical for dismissing UI when caller hangs up)
  static Future<void> _handleCancelSignal(dynamic data) async {
    try {
      final callData = Map<String, dynamic>.from(data ?? {});
      final callId = callData['callId']?.toString() ?? '';
      final by = callData['by']?.toString() ?? '';
      final reason = callData['reason']?.toString() ?? 'unknown';
      
      debugPrint('🚫 CANCEL signal received: callId=$callId, by=$by, reason=$reason');
      debugPrint('   Dismissing all CallKit UI immediately');
      
      // CRITICAL: Immediately dismiss all CallKit UI when CANCEL is received
      // This ensures User B knows the call is cancelled even if they're in background
      await _dismissCallKitUI(callId, 'cancelled_via_cancel_signal');
    } catch (e) {
      debugPrint('❌ Error handling CANCEL signal: $e');
    }
  }
  
  /// Handle call cancellation from socket
  /// Dismisses all CallKit UI when caller cancels before receiver answers
  static Future<void> _handleCallCancelled(dynamic data) async {
    try {
      final callData = Map<String, dynamic>.from(data ?? {});
      final callId = callData['callId']?.toString() ?? '';
      final by = callData['by']?.toString() ?? '';
      
      debugPrint('📞 Call cancelled by caller: callId=$callId, by=$by');
      
      // Dismiss CallKit UI
      await _dismissCallKitUI(callId, 'cancelled');
    } catch (e) {
      debugPrint('❌ Error handling call cancellation: $e');
    }
  }
  
  /// Handle callEnded signal from socket (new proper termination signal)
  /// This is the primary signal for call termination
  static Future<void> _handleCallEndedSignal(dynamic data) async {
    try {
      final callData = Map<String, dynamic>.from(data ?? {});
      final callId = callData['callId']?.toString() ?? '';
      final by = callData['by']?.toString() ?? '';
      final timestamp = callData['timestamp'];
      final state = callData['state']?.toString() ?? '';
      
      debugPrint('📞 CallEnded signal received: callId=$callId, by=$by, state=$state, timestamp=$timestamp');
      
      // Always dismiss CallKit UI when callEnded signal is received
      // This ensures User B knows the call is terminated
      if (callId.isNotEmpty) {
        debugPrint('📞 Dismissing CallKit UI for terminated call: $callId');
        await _dismissCallKitUI(callId, 'ended_signal');
      }
    } catch (e) {
      debugPrint('❌ Error handling callEnded signal: $e');
    }
  }
  
  /// Handle call ended from socket (legacy support)
  /// Dismisses CallKit UI when call ends (e.g., caller hangs up)
  static Future<void> _handleCallEnded(dynamic data) async {
    try {
      final callData = Map<String, dynamic>.from(data ?? {});
      final callId = callData['callId']?.toString() ?? '';
      final by = callData['by']?.toString() ?? '';
      
      debugPrint('📞 Call ended (legacy): callId=$callId, by=$by');
      
      // Only dismiss CallKit UI if this is for an incoming call that's still showing
      // Check if we have this call in pending calls (meaning it's an incoming call)
      if (callId.isNotEmpty && _pendingCalls.containsKey(callId)) {
        debugPrint('📞 Dismissing CallKit UI for ended incoming call: $callId');
        await _dismissCallKitUI(callId, 'ended');
      } else {
        debugPrint('📞 Call ended but not in pending calls (may be outgoing or already handled): $callId');
      }
    } catch (e) {
      debugPrint('❌ Error handling call ended: $e');
    }
  }
  
  /// Public method to dismiss all CallKit UI (for use in top-level functions)
  static Future<void> dismissAllCallKit() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
      debugPrint('✅ All CallKit UI dismissed');
    } catch (e) {
      debugPrint('⚠️ Error dismissing all CallKit UI: $e');
    }
  }
  
  /// Dismiss CallKit UI for a specific call or all calls
  static Future<void> _dismissCallKitUI(String callId, String reason) async {
    // Remove from pending calls
    if (callId.isNotEmpty) {
      _pendingCalls.remove(callId);
      // Clean up processed call IDs
      _processedCallIds.removeWhere((key) => key.contains(callId));
    }
    
    // Dismiss all CallKit UI - this works even if app was just opened from background
    // endAllCalls() dismisses all active call UI, which is what we want when caller cancels/ends
    try {
      await FlutterCallkitIncoming.endAllCalls();
      debugPrint('✅ All CallKit UI dismissed (reason: $reason)');
    } catch (e) {
      debugPrint('⚠️ Error dismissing all CallKit UI: $e');
      // Try to end specific call if endAllCalls fails
      if (callId.isNotEmpty) {
        try {
          await FlutterCallkitIncoming.endCall(callId);
          debugPrint('✅ CallKit UI dismissed for specific call: $callId (reason: $reason)');
        } catch (e2) {
          debugPrint('⚠️ Error dismissing specific call UI: $e2');
        }
      }
    }
  }

  /// Handle call accept - navigate and start WebRTC signaling
  static Future<void> _handleCallAccept(
    String callId,
    Map<String, dynamic> callData,
  ) async {
    final callerId = callData['callerId']?.toString() ?? '';
    final callerName = callData['callerName']?.toString() ?? 'Unknown';
    final isVideo = callData['isVideo'] == true;
    final sdpOffer = callData['sdp'];

    if (callerId.isEmpty) {
      debugPrint('Cannot accept call: callerId is empty');
      return;
    }

    // Ensure Socket.io is connected before navigating to the call screen
    try {
      if (!SocketService.I.isConnected) {
        debugPrint('📞 Call accept: socket not connected, attempting reconnect...');
        final token = await AuthStore.getToken();
        if (token != null && token.isNotEmpty) {
          SocketService.I.connect(baseUrl: apiBase, token: token, force: true);
          // Give the socket a brief moment to connect; CallPage will also handle retries
          await Future.delayed(const Duration(milliseconds: 500));
        } else {
          debugPrint('⚠️ Call accept: no auth token available, cannot connect socket');
        }
      } else {
        debugPrint('📞 Call accept: socket already connected');
      }
    } catch (e) {
      debugPrint('❌ Call accept: error while ensuring socket connection: $e');
    }

    // Navigate to call page with auto-accept flag
    _navigateToCallPageWithAutoAccept({
      'callId': callId,
      'from': callerId,
      'callerName': callerName,
      'isVideo': isVideo,
      'sdp': sdpOffer,
      'kind': isVideo ? 'video' : 'audio',
    });

    // Remove from pending calls
    _pendingCalls.remove(callId);
  }

  /// Notify backend that call was declined
  static void _notifyCallDeclined(
    String callId,
    Map<String, dynamic> callData,
  ) {
    try {
      if (SocketService.I.isConnected) {
        SocketService.I.emit('call:answer', {
          'callId': callId,
          'accept': false,
        });
        debugPrint('Notified backend that call $callId was declined');
      } else {
        debugPrint('Socket not connected, cannot notify call declined');
      }
    } catch (e) {
      debugPrint('Error notifying call declined: $e');
    }
  }

  /// Handle foreground messages
  static void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('📱 Foreground message received: ${message.messageId}');
    debugPrint('Data: ${message.data}');
    debugPrint('Data keys: ${message.data.keys.toList()}');
    debugPrint('Notification: ${message.notification?.title} - ${message.notification?.body}');
    
    final data = message.data;
    final messageType = data['type']?.toString().toUpperCase() ?? '';
    
    debugPrint('📱 Foreground message type: $messageType');
    
    // Check if this is a call cancellation notification
    // Check if this is a call termination notification (CALL_ENDED or CALL_CANCELLED)
    final isCallEnded = messageType == 'CALL_ENDED' || 
                        messageType == 'CALL_CANCELLED' ||
                        data['action']?.toString().toLowerCase() == 'dismiss';
    
    if (isCallEnded) {
      // Call was ended/cancelled - dismiss CallKit UI immediately
      debugPrint('📞 Call termination notification received in foreground (type: $messageType) - dismissing CallKit UI');
      final callId = data['call_id']?.toString() ?? '';
      _dismissCallKitUI(callId, 'terminated_via_fcm');
      return; // Don't process further
    }
    
    final messageTypeLower = messageType.toLowerCase();
    
    // Check if this is a call notification
    // Backend sends type: 'CALL' (becomes 'call' when lowercased)
    // Also check for call-related fields: caller_name, call_id
    if (messageTypeLower == 'call' ||
        messageTypeLower == 'voice' || 
        messageTypeLower == 'video' ||
        data.containsKey('caller_name') ||
        data.containsKey('nameCaller') || 
        data['call_id'] != null ||
        data['callId'] != null) {
      // CRITICAL: Do NOT show CallKit banner in foreground
      // In foreground, Socket.io will handle the call and navigate directly to CallPage
      // CallKit banner should ONLY be shown when app is in background
      debugPrint('📞 Foreground call notification received - NOT showing CallKit banner');
      debugPrint('   CallId: ${data['call_id'] ?? data['callId']}');
      debugPrint('   Caller: ${data['caller_name'] ?? data['nameCaller'] ?? data['callerName']}');
      debugPrint('   Type: $messageType');
      debugPrint('💡 Call will be handled by Socket.io listener (onIncomingCall)');
      // Do NOT call _showCallKitIncoming in foreground
      // Socket.io listener in main.dart will handle navigation to CallPage
    } else if (messageType == 'message' || messageType.isEmpty) {
      // Always process FCM messages (even if socket is connected, as a backup)
      // This ensures messages are received even if socket connection is unstable
      debugPrint('📱 Processing FCM message (socket status: ${SocketService.I.isConnected ? "connected" : "disconnected"})');
      _processFCMessage(message);
      // Also show notification
      _showLocalNotificationForMessage(message);
    }
  }
  
  /// Process FCM message when socket is disconnected
  /// Converts FCM message to socket format and processes it
  static void _processFCMessage(RemoteMessage message) {
    try {
      final isSocketConnected = SocketService.I.isConnected;
      
      if (!isSocketConnected) {
        // Socket is disconnected - process via MessageProvider
        debugPrint('📱 Socket disconnected - processing FCM message via MessageProvider');
        MessageProvider.processFCMessage(message);
        debugPrint('✅ FCM message processed and emitted as socket message');
      } else {
        // Socket is connected - message should come via socket, but process FCM as backup
        debugPrint('📱 Socket connected - FCM message processed as backup');
        MessageProvider.processFCMessage(message);
      }
    } catch (e) {
      debugPrint('❌ Error processing FCM message: $e');
      // Fallback to just showing notification
      _showLocalNotificationForMessage(message);
    }
  }
  
  /// Show local notification for regular messages
  static Future<void> _showLocalNotificationForMessage(RemoteMessage message) async {
    try {
      final notification = message.notification;
      final data = message.data;
      
      final title = notification?.title ?? 
                   data['title']?.toString() ?? 
                   'New Message';
      final body = notification?.body ?? 
                  data['body']?.toString() ?? 
                  data['message']?.toString() ?? 
                  'You have a new message';
      
      final messageId = message.messageId ?? 
                       data['messageId']?.toString() ?? 
                       DateTime.now().millisecondsSinceEpoch.toString();
      
      // Show local notification
      await Noti.showIfNew(
        messageId: messageId,
        title: title,
        body: body,
        payload: {
          'type': data['type']?.toString() ?? 'message',
          'from': data['from']?.toString() ?? '',
          'peerId': data['peerId']?.toString() ?? data['from']?.toString() ?? '',
          'messageId': messageId,
          ...data,
        },
      );
      
      debugPrint('✅ Local notification shown: $title - $body');
    } catch (e) {
      debugPrint('❌ Error showing local notification: $e');
    }
  }

  /// Handle message opened from background/terminated state
  static void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('📱 Message opened app: ${message.messageId}');
    debugPrint('Data: ${message.data}');
    debugPrint('Data keys: ${message.data.keys.toList()}');
    
    final data = message.data;
    final messageType = data['type']?.toString().toLowerCase() ?? '';
    
    debugPrint('📱 Message type detected: $messageType');
    
    // Check if this is a call notification
    // Backend sends type: 'CALL' (becomes 'call' when lowercased)
    // Also check for call-related fields: caller_name, call_id
    if (messageType == 'call' ||
        messageType == 'voice' || 
        messageType == 'video' ||
        data.containsKey('caller_name') ||
        data.containsKey('nameCaller') || 
        data['call_id'] != null ||
        data['callId'] != null) {
      // When app is opened from background/terminated via notification
      // Check if app is in foreground - if yes, navigate to CallPage directly
      // If in background, show CallKit banner
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState == AppLifecycleState.resumed) {
        debugPrint('📞 Call notification opened app - app is in foreground');
        debugPrint('   Navigating to CallPage directly (not showing CallKit banner)');
        _navigateToCallPage(data);
      } else {
        debugPrint('📞 Call notification opened app - app is in background');
        debugPrint('   Showing CallKit banner');
        _showCallKitIncoming(message);
      }
    } else {
      // Regular message - navigate to chat
      _navigateToCallPage(data);
    }
  }

  /// Handle background message
  /// This is called from the top-level background handler for non-call messages
  static Future<void> handleBackgroundMessage(RemoteMessage message) async {
    debugPrint('🔔 Background message received: ${message.messageId}');
    debugPrint('Data: ${message.data}');
    debugPrint('Notification: ${message.notification?.title} - ${message.notification?.body}');
    
    final messageType = message.data['type']?.toString().toLowerCase() ?? '';
    
    // Check if this is a call notification
    // Backend sends type: 'CALL' (becomes 'call' when lowercased)
    // Also check for call-related fields: caller_name, call_id
    // Note: Call notifications are handled directly in firebaseMessagingBackgroundHandler
    if (messageType == 'call' ||
        messageType == 'voice' || 
        messageType == 'video' ||
        message.data.containsKey('caller_name') ||
        message.data.containsKey('nameCaller')) {
      // This should have been handled by the top-level handler
      // But if it reaches here, show CallKit anyway
      await _showCallKitIncoming(message);
    } else if (messageType == 'message' || messageType.isEmpty || messageType == 'call') {
      // Process FCM message (will be handled by socket handlers if socket reconnects)
      // Also show local notification
      MessageProvider.processFCMessage(message);
      await _showLocalNotificationForMessage(message);
    }
  }

  /// Show native incoming call UI using CallKit
  /// ONLY shows banner when app is in BACKGROUND state
  /// In foreground, Socket.io will handle navigation to CallPage
  static Future<void> _showCallKitIncoming(RemoteMessage message) async {
    // CRITICAL: Only show CallKit banner when app is in BACKGROUND
    // In foreground, Socket.io listener will handle the call
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.resumed) {
      debugPrint('⚠️ _showCallKitIncoming: App is in foreground - NOT showing CallKit banner');
      debugPrint('   Call will be handled by Socket.io listener (onIncomingCall)');
      return; // Don't show banner in foreground
    }
    
    try {
      final data = message.data;
      
      // Extract call information - Backend sends: call_id, caller_name, callerId
      // Also support legacy: callId, nameCaller for backward compatibility
      final callId = data['call_id']?.toString() ?? 
                     data['callId']?.toString() ?? 
                     data['uuid']?.toString() ?? 
                     _uuid.v4();
      final callerId = data['callerId']?.toString() ?? 
                       data['from']?.toString() ?? 
                       data['handle']?.toString() ?? '';
      
      // Use 'caller_name' as the primary key (backend sends this), fallback to legacy keys
      final callerName = data['caller_name']?.toString() ?? 
                         data['nameCaller']?.toString() ?? 
                         data['callerName']?.toString() ?? 
                         data['name']?.toString() ?? 
                         'Unknown Caller';
      
      // Use 'avatar' as the primary key, fallback to 'avatarUrl'
      final avatarUrl = data['avatar']?.toString() ?? 
                        data['avatarUrl']?.toString();
      
      // Determine call type from 'type' field: 'voice' or 'video'
      final callType = data['type']?.toString().toLowerCase() ?? '';
      final isVideo = callType == 'video' || 
                     data['isVideo'] == true || 
                     data['kind']?.toString().toLowerCase() == 'video';

      if (callerId.isEmpty) {
        debugPrint('⚠️ Cannot show call UI: callerId is empty');
        return;
      }

    debugPrint('📞 Background call notification - showing CallKit banner:');
    debugPrint('   CallId: $callId');
    debugPrint('   CallerId: $callerId');
    debugPrint('   CallerName: $callerName');
    debugPrint('   Type: ${isVideo ? "video" : "voice"}');
    debugPrint('   Avatar: $avatarUrl');

      // Check timestamp to prevent showing expired calls
      final timestamp = data['timestamp'];
      bool isExpired = false;
      if (timestamp != null) {
        final callTimestamp = timestamp is int 
            ? timestamp 
            : (timestamp is num ? timestamp.toInt() : null);
        
        if (callTimestamp != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
      final difference = now - callTimestamp;
      const maxAgeSeconds = 8; // 5-10 seconds range - using 8 seconds as safe middle ground
      const maxAgeMs = maxAgeSeconds * 1000;
      
      if (difference > maxAgeMs) {
        debugPrint('❌ Call expired in foreground handler - timestamp: $callTimestamp, now: $now, difference: ${difference}ms (>${maxAgeMs}ms)');
        debugPrint('Call expired - User A has likely already hung up');
        isExpired = true;
      } else {
        debugPrint('✅ Call is valid - timestamp: $callTimestamp, now: $now, difference: ${difference}ms (<=${maxAgeMs}ms)');
      }
        }
      }
      
      // If call is expired or same call ID exists, clean up first
      if (isExpired || _pendingCalls.containsKey(callId)) {
        debugPrint('🧹 Cleaning up expired/duplicate call before showing new banner...');
        try {
          await FlutterCallkitIncoming.endAllCalls();
          debugPrint('✅ All existing call UI dismissed (expired or duplicate)');
          // Remove from pending calls
          _pendingCalls.remove(callId);
          _processedCallIds.removeWhere((key) => key.contains(callId));
        } catch (e) {
          debugPrint('⚠️ Error cleaning up expired/duplicate call: $e');
        }
        
        // If expired, don't show the banner
        if (isExpired) {
          debugPrint('❌ Not showing expired call banner');
          return;
        }
      }
      
      // CRITICAL: End any existing pending calls before showing new one
      // This prevents CallKit from blocking new calls when there's leftover state
      debugPrint('🧹 Cleaning up any other existing pending calls before showing new call...');
      final pendingCallIds = List<String>.from(_pendingCalls.keys);
      for (final pendingCallId in pendingCallIds) {
        if (pendingCallId != callId) {
          debugPrint('   Ending previous pending call: $pendingCallId');
          try {
            await FlutterCallkitIncoming.endCall(pendingCallId);
            _pendingCalls.remove(pendingCallId);
            // Also clean up processed call IDs for the ended call
            _processedCallIds.removeWhere((key) => key.contains(pendingCallId));
          } catch (e) {
            debugPrint('   ⚠️ Error ending previous call $pendingCallId: $e');
            // Continue even if ending previous call fails
          }
        }
      }

    // Validate required fields
    if (callId.isEmpty) {
      debugPrint('⚠️ CallId is empty, generating new one');
    }
    if (callerId.isEmpty) {
      debugPrint('❌ Cannot show CallKit: callerId is empty');
      return;
    }
    if (callerName.isEmpty || callerName == 'Unknown Caller') {
      debugPrint('⚠️ Caller name is missing or unknown');
    }

    final params = CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'Messaging App',
        avatar: avatarUrl,
        handle: callerId,
        type: isVideo ? 1 : 0, // 1 = video, 0 = voice
        duration: 30000, // 30 seconds timeout
        textAccept: 'Accept',
        textDecline: 'Decline',
        textMissedCall: 'Missed Call',
        textCallback: 'Call Back',
      extra: <String, dynamic>{
        'callerId': callerId,
        'callerName': callerName,
        'isVideo': isVideo,
        'callId': callId,
        'sdp': parseSdpFromData(data['sdp']),
        'kind': isVideo ? 'video' : 'voice',
      },
        headers: <String, dynamic>{},
        android: AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          ringtonePath: 'system_default',
          backgroundColor: '#FFB19CD9',
          backgroundUrl: avatarUrl,
          actionColor: '#0955fa',
          // Note: notificationChannelId is not available in this version
          // The channel will be created separately and used automatically
        ),
        ios: IOSParams(
          iconName: 'CallKitLogo',
          handleType: 'generic',
          supportsVideo: isVideo,
          maximumCallGroups: 2,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'default',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: true,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      debugPrint('📞 Attempting to show CallKit with params:');
      debugPrint('   id: $callId');
      debugPrint('   nameCaller: $callerName');
      debugPrint('   handle: $callerId');
      debugPrint('   type: ${isVideo ? "video" : "voice"}');
      debugPrint('   avatar: $avatarUrl');
      
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      
      // Store call data for when user accepts
      _pendingCalls[callId] = {
        'callerId': callerId,
        'callerName': callerName,
        'isVideo': isVideo,
        'sdp': parseSdpFromData(data['sdp']),
        'kind': isVideo ? 'video' : 'voice',
      };
      
      debugPrint('✅ CallKit showCallkitIncoming called successfully for: $callerName');
    } catch (e) {
      debugPrint('❌ Error showing CallKit incoming: $e');
    }
  }


  /// Navigate to call page with auto-accept (from CallKit)
  static void _navigateToCallPageWithAutoAccept(Map<String, dynamic> data) {
    final callerId = data['from']?.toString() ?? data['callerId']?.toString() ?? '';
    final callerName = data['callerName']?.toString() ?? data['name']?.toString() ?? 'Unknown';
    final callId = data['callId']?.toString();
    final isVideo = data['isVideo'] == true || 
                   data['kind']?.toString().toLowerCase() == 'video';

    if (callerId.isEmpty) {
      debugPrint('Cannot navigate to call page: callerId is empty');
      return;
    }

    final sdp = data['sdp'];
    final sdpObj = (sdp is Map)
        ? Map<String, dynamic>.from(sdp)
        : <String, dynamic>{};

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => CallPage(
          peerId: callerId,
          peerName: callerName,
          outgoing: false,
          video: isVideo,
          initialCallId: callId,
          initialOffer: sdpObj.isNotEmpty ? sdpObj : null,
          autoAccept: true, // Flag to auto-accept the call
        ),
      ),
    );
  }

  /// Navigate to call page (regular navigation)
  static void _navigateToCallPage(Map<String, dynamic> data) {
    // CRITICAL: Only navigate to CallPage when app is in foreground
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != AppLifecycleState.resumed) {
      debugPrint('⚠️ _navigateToCallPage: App not in foreground - skipping navigation');
      return;
    }

    final callerId = data['from']?.toString() ?? data['callerId']?.toString() ?? '';
    final callerName = data['callerName']?.toString() ?? data['name']?.toString() ?? 'Unknown';
    final callId = data['callId']?.toString();
    final isVideo = data['isVideo'] == true || 
                   data['kind']?.toString().toLowerCase() == 'video';

    if (callerId.isEmpty) {
      debugPrint('Cannot navigate to call page: callerId is empty');
      return;
    }

    final sdp = data['sdp'];
    final sdpObj = (sdp is Map)
        ? Map<String, dynamic>.from(sdp)
        : <String, dynamic>{};

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => CallPage(
          peerId: callerId,
          peerName: callerName,
          outgoing: false,
          video: isVideo,
          initialCallId: callId,
          initialOffer: sdpObj.isNotEmpty ? sdpObj : null,
        ),
      ),
    );
  }

  /// Get FCM token
  static Future<String?> getToken() async {
    try {
      final token = await _messaging.getToken();
      debugPrint('📱 FCM Token retrieved via getToken(): ${maskToken(token)}');
      return token;
    } catch (e) {
      debugPrint('❌ Error getting FCM token via getToken(): $e');
      return null;
    }
  }
  
  /// Retry getting FCM token (useful when token was null initially)
  /// This can be called after permissions are granted or when needed
  static Future<String?> retryGetToken() async {
    debugPrint('🔄 Retrying to get FCM token...');
    try {
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        debugPrint('✅ FCM Token retrieved on retry: ${maskToken(token)}');
        await updateFCMTokenToBackend(token);
        return token;
      } else {
        debugPrint('⚠️ FCM Token is still null/empty after retry');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error retrying FCM token: $e');
      return null;
    }
  }

  /// Subscribe to a topic
  static Future<void> subscribeToTopic(String topic) async {
    await _messaging.subscribeToTopic(topic);
  }

  /// Unsubscribe from a topic
  static Future<void> unsubscribeFromTopic(String topic) async {
    await _messaging.unsubscribeFromTopic(topic);
  }
}
