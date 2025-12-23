import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:study1/call_page.dart';
import 'splash_gate.dart';
import 'nav.dart'; // 👈 navigatorKey here
import 'services/theme_service.dart';
import 'services/call_state_service.dart'; // Global call state management
import 'firebase_messaging_handler.dart'; // Contains firebaseMessagingBackgroundHandler
import 'socket_service.dart';
import 'api.dart';
import 'auth_store.dart';
import 'message_provider.dart';

/// Global set to track cancelled call IDs
/// Prevents showing UI for calls that have been cancelled
final Set<String> _cancelledCallIds = <String>{};

/// Handle call cancellation signals - clear state and dismiss UI
/// Uses robust popUntil that specifically checks for 'CallPage' route name
Future<void> _handleCallCancellation(String callId, String source) async {
  debugPrint('🚫 Call cancelled - callId: $callId, source: $source');
  
  // Mark call as cancelled
  _cancelledCallIds.add(callId);
  
  // Clear active call state
  CallStateService.instance.clearActiveCallById(callId);
  
  // Dismiss CallKit UI
  await FlutterCallkitIncoming.endAllCalls();
  FirebaseMessagingHandler.dismissAllCallKit();
  
  // CRITICAL: Robust navigation cleanup - specifically remove CallPage route
  // This ensures no Ghost UI remains when app is resumed
  final navigator = navigatorKey.currentState;
  if (navigator != null) {
    try {
      // Strategy: Pop until we reach home, but specifically check for CallPage routes
      // This ensures CallPage is removed even if it's not the top route
      bool foundCallPage = false;
      
      // First pass: Pop until we find and remove CallPage
      navigator.popUntil((route) {
        final settings = route.settings;
        final routeName = settings.name;
        
        // If we find CallPage, mark it and keep popping
        if (routeName == 'CallPage') {
          foundCallPage = true;
          return false; // Keep popping to remove CallPage
        }
        
        // If we've reached home and haven't found CallPage, stop
        if (route.isFirst) {
          return true; // Stop at home
        }
        
        // Keep popping for other routes
        return false;
      });
      
      // Second pass: If we found CallPage, ensure we're back at home
      if (foundCallPage) {
        navigator.popUntil((route) => route.isFirst);
      }
      
      // Final safety: Pop until home to ensure clean state
      // This handles edge cases where CallPage might be nested
      navigator.popUntil((route) {
        final settings = route.settings;
        // If current route is CallPage, keep popping
        if (settings.name == 'CallPage') {
          return false;
        }
        // Stop at home
        return route.isFirst;
      });
    } catch (e) {
      // Fallback: Simple pop until home if popUntil fails
      try {
        navigator.popUntil((route) => route.isFirst);
      } catch (e2) {
        // Last resort: Single pop if available
        if (navigator.canPop()) {
          try {
            navigator.pop();
          } catch (_) {}
        }
      }
    }
  }
}

/// Socket listener for CANCEL signal
void _onCancelSignal(dynamic data) async {
  final callData = Map<String, dynamic>.from(data ?? {});
  final callId = callData['callId']?.toString() ?? '';
  if (callId.isNotEmpty) {
    await _handleCallCancellation(callId, 'CANCEL');
  }
}

/// Socket listener for callCancelled signal
void _onCallCancelledSignal(dynamic data) async {
  final callData = Map<String, dynamic>.from(data ?? {});
  final callId = callData['callId']?.toString() ?? '';
  if (callId.isNotEmpty) {
    await _handleCallCancellation(callId, 'callCancelled');
  }
}

/// Socket listener for callEnded signal
void _onCallEndedSignal(dynamic data) async {
  final callData = Map<String, dynamic>.from(data ?? {});
  final callId = callData['callId']?.toString() ?? '';
  if (callId.isNotEmpty) {
    await _handleCallCancellation(callId, 'callEnded');
  }
}

/// Setup socket listeners for call cancellation events
void _setupCallCancellationListeners() {
  // Remove existing listeners to prevent duplicates
  SocketService.I.off('CANCEL', _onCancelSignal);
  SocketService.I.off('callCancelled', _onCallCancelledSignal);
  SocketService.I.off('callEnded', _onCallEndedSignal);
  
  // Register listeners for call cancellation events
  SocketService.I.on('CANCEL', _onCancelSignal);
  SocketService.I.on('callCancelled', _onCallCancelledSignal);
  SocketService.I.on('callEnded', _onCallEndedSignal);
}

/// Telegram/Viber-style incoming call handler
/// DO NOT push CallPage when app is in background - only show CallKit banner
/// Store call data in global state, verify with backend on app resume
Future<void> onIncomingCall(dynamic data) async {
  // CRITICAL: Check AppLifecycleState FIRST - return early if in background
  // This prevents unnecessary processing and logging when app is in background
  final lifecycleState = WidgetsBinding.instance.lifecycleState;
  final isAppInForeground = lifecycleState == AppLifecycleState.resumed;
  
  final m = Map<String, dynamic>.from(data ?? {});
  final callId = (m['callId'] ?? '').toString();
  final from = (m['from'] ?? '').toString();
  
  // If app is in background, do minimal processing and return early
  if (!isAppInForeground) {
    // Quick validation
    if (from.isEmpty || callId.isEmpty) {
      return;
    }
    
    // CRITICAL: Check if this call was already cancelled
    if (_cancelledCallIds.contains(callId)) {
      debugPrint('❌ Call $callId was already cancelled - not storing in background');
      return;
    }
    
    final sdpObj = (m['sdp'] is Map)
        ? Map<String, dynamic>.from(m['sdp'])
        : <String, dynamic>{};
    if (sdpObj.isEmpty) {
      return;
    }
    
    // Parse minimal data for state storage
    final kindRaw = m['kind'] ?? m['type'] ?? 'audio';
    final kind = kindRaw.toString().toLowerCase().trim();
    final timestamp = m['timestamp'];
    int? callTimestamp = timestamp is int 
        ? timestamp 
        : (timestamp is num ? timestamp.toInt() : null);
    callTimestamp ??= DateTime.now().millisecondsSinceEpoch;
    
    // CRITICAL: Check timestamp even in background - don't store expired calls
    if (callTimestamp != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final difference = now - callTimestamp;
      const maxAgeSeconds = 5;
      const maxAgeMs = maxAgeSeconds * 1000;
      
      if (difference > maxAgeMs) {
        debugPrint('❌ Call expired in background - callId: $callId, difference: ${difference}ms');
        _cancelledCallIds.add(callId); // Mark as cancelled
        return; // Don't store expired calls
      }
    }
    
    // Store in global state (will verify on resume)
    CallStateService.instance.setActiveCall(
      callId: callId,
      from: from,
      sdp: sdpObj,
      kind: kind,
      timestamp: callTimestamp,
    );
    
    return; // CallKit banner shown by FCM handler
  }
  
  // App is in FOREGROUND - process call
  // Parse timestamp
  int? callTimestamp;
  final timestamp = m['timestamp'];
  if (timestamp != null) {
    callTimestamp = timestamp is int 
        ? timestamp 
        : (timestamp is num ? timestamp.toInt() : null);
    
    if (callTimestamp != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final difference = now - callTimestamp;
      const maxAgeSeconds = 5;
      const maxAgeMs = maxAgeSeconds * 1000;
      
      if (difference > maxAgeMs) {
        debugPrint('❌ Call expired (${difference}ms > ${maxAgeMs}ms) - callId: $callId');
        FirebaseMessagingHandler.dismissAllCallKit();
        return;
      }
    }
  }
  callTimestamp ??= DateTime.now().millisecondsSinceEpoch;
  
  // Parse call data
  final kindRaw = m['kind'] ?? m['type'] ?? 'audio';
  final kind = kindRaw.toString().toLowerCase().trim();
  final isVideo = kind == 'video' || kind.contains('video');
  final sdpObj = (m['sdp'] is Map)
      ? Map<String, dynamic>.from(m['sdp'])
      : <String, dynamic>{};

  if (from.isEmpty || callId.isEmpty || sdpObj.isEmpty) {
    return; // Invalid call data
  }

  // Store in global state
  CallStateService.instance.setActiveCall(
    callId: callId,
    from: from,
    sdp: sdpObj,
    kind: kind,
    timestamp: callTimestamp,
  );
  
  // Verify with backend before pushing CallPage
  try {
    final callStatus = await checkCallStatus(callId);
    if (callStatus['active'] != true) {
      debugPrint('❌ Call $callId inactive - backend confirmed ended');
      CallStateService.instance.clearActiveCallById(callId);
      await FlutterCallkitIncoming.endAllCalls();
      FirebaseMessagingHandler.dismissAllCallKit();
      return;
    }
  } catch (e) {
    debugPrint('⚠️ Error checking call status: $e');
    // Proceed anyway (fail-open)
  }
  
  // Final check: Ensure call wasn't cancelled
  if (_cancelledCallIds.contains(callId)) {
    debugPrint('❌ Call $callId was cancelled - not showing CallPage');
    CallStateService.instance.clearActiveCallById(callId);
    await FlutterCallkitIncoming.endAllCalls();
    FirebaseMessagingHandler.dismissAllCallKit();
    return;
  }
  
  if (!CallStateService.instance.hasActiveCall || 
      CallStateService.instance.activeCallId != callId) {
    await FlutterCallkitIncoming.endAllCalls();
    FirebaseMessagingHandler.dismissAllCallKit();
    return;
  }

  // CRITICAL: Multiple checks to strictly prevent navigation in background
  final currentLifecycleState = WidgetsBinding.instance.lifecycleState;
  if (currentLifecycleState != AppLifecycleState.resumed) {
    debugPrint('⚠️ App no longer in foreground - skipping CallPage navigation');
    return;
  }
  
  // Additional safety check - verify navigator is available and app is truly in foreground
  final navigator = navigatorKey.currentState;
  if (navigator == null) {
    debugPrint('⚠️ Navigator not available - skipping CallPage navigation');
    return;
  }
  
  // Final check - ensure we're not in background (triple check)
  final finalLifecycleCheck = WidgetsBinding.instance.lifecycleState;
  if (finalLifecycleCheck != AppLifecycleState.resumed) {
    debugPrint('⚠️ App state changed to background - skipping CallPage navigation');
    return;
  }

  debugPrint('📞 Pushing CallPage - callId: $callId, video: $isVideo');
  navigator.push(
    MaterialPageRoute(
      settings: const RouteSettings(name: 'CallPage'), // Named route for easy identification
      builder: (_) => CallPage(
        peerId: from,
        peerName: 'Incoming call',
        outgoing: false,
        video: isVideo,
        initialCallId: callId,
        initialOffer: sdpObj,
      ),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // CRITICAL: Register background message handler BEFORE Firebase initialization
  // This must be a top-level function and registered before runApp()
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  debugPrint('✅ Background message handler registered');
  
  // Initialize Firebase (optional - app works without it)
  bool firebaseInitialized = false;
  try {
    // Check if Firebase is already initialized (e.g., from hot reload)
    try {
      Firebase.app();
      firebaseInitialized = true;
      debugPrint('✅ Firebase was already initialized');
    } catch (_) {
      // Firebase not initialized, try to initialize it
      // This will automatically use google-services.json if present
      await Firebase.initializeApp();
      firebaseInitialized = true;
      debugPrint('✅ Firebase initialized successfully');
    }
  } catch (e) {
    // Firebase initialization failed - this is OK, app works without Firebase
    debugPrint('⚠️ Firebase not configured or initialization failed: $e');
    debugPrint('💡 App will continue without Firebase features (push notifications will not work)');
    debugPrint('💡 To enable Firebase:');
    debugPrint('   1. Create a Firebase project at https://console.firebase.google.com/');
    debugPrint('   2. Add google-services.json to android/app/');
    debugPrint('   3. Add GoogleService-Info.plist to ios/Runner/');
    debugPrint('   4. Rebuild the app');
    // Continue without Firebase - app will work but push notifications won't work
  }
  
  // Initialize Firebase Messaging (only if Firebase was initialized)
  if (firebaseInitialized) {
    try {
      await FirebaseMessagingHandler.initialize();
      debugPrint('✅ Firebase Messaging initialized successfully');
      
      // Initialize MessageProvider for unified message handling
      await MessageProvider.instance.initialize();
    } catch (e) {
      debugPrint('❌ Error initializing Firebase Messaging: $e');
      // Continue even if Firebase Messaging initialization fails
    }
  } else {
    debugPrint('⚠️ Skipping Firebase Messaging initialization (Firebase not initialized)');
  }
  
  // Setup call cancellation listeners
  _setupCallCancellationListeners();
  
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final ThemeService _themeService = ThemeService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeService.loadPreferences();
    _themeService.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeService.removeListener(_onThemeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // CRITICAL: When app resumes, immediately check for cancellation signals
        // This ensures we catch any cancellation that happened while app was in background
        // Then check active call state
      Future.delayed(const Duration(milliseconds: 800), () {
          _checkActiveCallOnResume();
        });
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // No logging for normal lifecycle transitions
        break;
    }
  }
  
  /// Telegram/Viber Logic: Check active call state when app resumes
  /// Verify with backend API if call is still active before navigating to CallPage
  /// AGGRESSIVE: Clear stale calls immediately to prevent ghost UI
  Future<void> _checkActiveCallOnResume() async {
    if (!CallStateService.instance.hasActiveCall) {
      return;
    }
    
    final activeCallData = CallStateService.instance.activeCallData;
    if (activeCallData == null) {
      return;
    }
    
    final callId = activeCallData['callId']?.toString() ?? '';
    if (callId.isEmpty) {
      CallStateService.instance.clearActiveCall();
      return;
    }
    
    debugPrint('🔍 App resumed - checking active call: $callId');
    
    // AGGRESSIVE: First check - if call has been stored for more than 5 seconds, clear immediately
    // This prevents showing stale UI even if backend says it's active
    final receivedAt = activeCallData['receivedAt'];
    if (receivedAt != null) {
      final receivedAtMs = receivedAt is int 
          ? receivedAt 
          : (receivedAt is num ? receivedAt.toInt() : null);
      
      if (receivedAtMs != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final storedFor = now - receivedAtMs;
        const aggressiveClearSeconds = 5; // Clear if stored for more than 5 seconds
        const aggressiveClearMs = aggressiveClearSeconds * 1000;
        
        if (storedFor > aggressiveClearMs) {
          debugPrint('❌ AGGRESSIVE CLEAR: Call $callId stored for ${storedFor}ms (>${aggressiveClearMs}ms) - clearing immediately');
          _cancelledCallIds.add(callId);
          CallStateService.instance.clearActiveCall();
          await FlutterCallkitIncoming.endAllCalls();
          FirebaseMessagingHandler.dismissAllCallKit();
          return; // Don't proceed with any checks
        }
      }
    }
    
    // CRITICAL: 1. Check if call was already cancelled
    if (_cancelledCallIds.contains(callId)) {
      debugPrint('❌ Call $callId was cancelled - clearing state');
      CallStateService.instance.clearActiveCall();
      await FlutterCallkitIncoming.endAllCalls();
      FirebaseMessagingHandler.dismissAllCallKit();
      return;
    }
    
    // CRITICAL: 2. Timestamp validation - check if call is expired (more aggressive)
    final timestamp = activeCallData['timestamp'];
    // receivedAt already declared above (line 382)
    
    final now = DateTime.now().millisecondsSinceEpoch;
    bool isExpired = false;
    
    // Check original call timestamp (when call was initiated)
    if (timestamp != null) {
      final callTimestamp = timestamp is int 
          ? timestamp 
          : (timestamp is num ? timestamp.toInt() : null);
      
      if (callTimestamp != null) {
        final difference = now - callTimestamp;
        const maxAgeSeconds = 3; // Reduced to 3 seconds - more aggressive
        const maxAgeMs = maxAgeSeconds * 1000;
        
        if (difference > maxAgeMs) {
          debugPrint('❌ Call $callId expired on resume (original timestamp) - difference: ${difference}ms (>${maxAgeMs}ms)');
          isExpired = true;
        }
      }
    }
    
    // Check how long we've been storing this call locally (receivedAt)
    if (!isExpired && receivedAt != null) {
      final receivedAtMs = receivedAt is int 
          ? receivedAt 
          : (receivedAt is num ? receivedAt.toInt() : null);
      
      if (receivedAtMs != null) {
        final storedFor = now - receivedAtMs;
        const maxStoredSeconds = 10; // If stored for more than 10 seconds, consider stale
        const maxStoredMs = maxStoredSeconds * 1000;
        
        if (storedFor > maxStoredMs) {
          debugPrint('❌ Call $callId stored too long - stored for: ${storedFor}ms (>${maxStoredMs}ms)');
          isExpired = true;
        }
      }
    }
    
    if (isExpired) {
      _cancelledCallIds.add(callId); // Mark as cancelled
      CallStateService.instance.clearActiveCall();
      await FlutterCallkitIncoming.endAllCalls();
      FirebaseMessagingHandler.dismissAllCallKit();
      return;
    }
    
    // CRITICAL: 3. Verify with backend API if call is still active
    // Also check if call state is "ringing" for too long (stale call)
    try {
      final callStatus = await checkCallStatus(callId);
      if (callStatus['active'] != true) {
        debugPrint('❌ Call $callId inactive - backend confirmed ended');
        CallStateService.instance.clearActiveCall();
        await FlutterCallkitIncoming.endAllCalls();
        FirebaseMessagingHandler.dismissAllCallKit();
        return;
      }
      
      // CRITICAL: If call is still in "ringing" state, check how long it's been ringing
      // If it's been ringing for too long, it's likely stale (caller probably cancelled)
      final callState = callStatus['state']?.toString();
      if (callState == 'ringing') {
        // Parse startedAt (backend returns ISO string or timestamp)
        final startedAt = callStatus['startedAt'];
        int? startedAtMs;
        
        if (startedAt != null) {
          if (startedAt is int) {
            startedAtMs = startedAt;
          } else if (startedAt is num) {
            startedAtMs = startedAt.toInt();
          } else if (startedAt is String) {
            // Try parsing ISO string
            try {
              final dateTime = DateTime.parse(startedAt);
              startedAtMs = dateTime.millisecondsSinceEpoch;
            } catch (e) {
              debugPrint('⚠️ Could not parse startedAt ISO string: $startedAt');
            }
          }
        }
        
        if (startedAtMs != null) {
          final ringingFor = now - startedAtMs;
          const maxRingingSeconds = 10; // Max 10 seconds in ringing state (more aggressive)
          const maxRingingMs = maxRingingSeconds * 1000;
          
          if (ringingFor > maxRingingMs) {
            debugPrint('❌ Call $callId stuck in ringing state - ringing for: ${ringingFor}ms (>${maxRingingMs}ms)');
            _cancelledCallIds.add(callId); // Mark as cancelled
            CallStateService.instance.clearActiveCall();
            await FlutterCallkitIncoming.endAllCalls();
            FirebaseMessagingHandler.dismissAllCallKit();
            return;
          }
        } else {
          // If we can't determine startedAt, use receivedAt as fallback
          final receivedAt = activeCallData['receivedAt'];
          if (receivedAt != null) {
            final receivedAtMs = receivedAt is int 
                ? receivedAt 
                : (receivedAt is num ? receivedAt.toInt() : null);
            
            if (receivedAtMs != null) {
              final storedFor = now - receivedAtMs;
              const maxStoredSeconds = 8; // If stored for more than 8 seconds, consider stale
              const maxStoredMs = maxStoredSeconds * 1000;
              
              if (storedFor > maxStoredMs) {
                debugPrint('❌ Call $callId in ringing state but stored too long - stored for: ${storedFor}ms (>${maxStoredMs}ms)');
                _cancelledCallIds.add(callId);
                CallStateService.instance.clearActiveCall();
                await FlutterCallkitIncoming.endAllCalls();
                FirebaseMessagingHandler.dismissAllCallKit();
                return;
              }
            }
          }
        }
      }
      
      // CRITICAL: 4. Verify app is still in foreground before navigation
      final currentLifecycleState = WidgetsBinding.instance.lifecycleState;
      if (currentLifecycleState != AppLifecycleState.resumed) {
        debugPrint('⚠️ App no longer in foreground - skipping CallPage navigation');
        return;
      }
      
      // CRITICAL: 5. Final check - ensure call wasn't cancelled while checking backend
      if (_cancelledCallIds.contains(callId)) {
        debugPrint('❌ Call $callId was cancelled during backend check - clearing state');
        CallStateService.instance.clearActiveCall();
        await FlutterCallkitIncoming.endAllCalls();
        FirebaseMessagingHandler.dismissAllCallKit();
        return;
      }
      
      // All checks passed - navigate to CallPage
      final from = activeCallData['from']?.toString() ?? '';
      final sdp = activeCallData['sdp'];
      final kind = activeCallData['kind']?.toString() ?? 'audio';
      final isVideo = kind == 'video' || kind.contains('video');
      
      final navigator = navigatorKey.currentState;
      if (navigator != null) {
        // CRITICAL: Final check - ensure app is still in foreground before navigation
        final finalLifecycleCheck = WidgetsBinding.instance.lifecycleState;
        if (finalLifecycleCheck != AppLifecycleState.resumed) {
          debugPrint('⚠️ App no longer in foreground - skipping CallPage navigation on resume');
          return;
        }
        
        navigator.push(
          MaterialPageRoute(
            settings: const RouteSettings(name: 'CallPage'), // Named route for easy identification
            builder: (_) => CallPage(
              peerId: from,
              peerName: 'Incoming call',
              outgoing: false,
              video: isVideo,
              initialCallId: callId,
              initialOffer: sdp is Map ? Map<String, dynamic>.from(sdp) : <String, dynamic>{},
            ),
          ),
        );
        debugPrint('✅ Navigated to CallPage - callId: $callId');
      }
      
    } catch (e) {
      debugPrint('⚠️ Error checking call status: $e');
      // On error, clear state to prevent showing stale UI
      CallStateService.instance.clearActiveCall();
      await FlutterCallkitIncoming.endAllCalls();
      FirebaseMessagingHandler.dismissAllCallKit();
    }
  }

  Future<void> _ensureSocketConnection() async {
    try {
      // Check if Socket.io is connected, reconnect if needed
      if (!SocketService.I.isConnected) {
        final token = await AuthStore.getToken();
        if (token != null) {
          debugPrint('Socket.io not connected, reconnecting...');
          SocketService.I.connect(baseUrl: apiBase, token: token);
        }
      } else {
        debugPrint('Socket.io is already connected');
      }
    } catch (e) {
      debugPrint('Error ensuring socket connection: $e');
    }
  }

  void _onThemeChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeService,
      builder: (context, child) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey, // 👈 IMPORTANT
          theme: _themeService.getLightTheme(),
          darkTheme: _themeService.getDarkTheme(),
          themeMode: _themeService.themeMode,
      home: const SplashGate(),
        );
      },
    );
  }
}
