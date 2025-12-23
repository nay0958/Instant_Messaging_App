// lib/call_page.dart — UI/animation-focused makeover only
// NOTE: Signaling/WebRTC methods and flows remain unchanged. This patch
// only improves visuals, layout and micro-interactions.

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'auth_store.dart';
import 'socket_service.dart';
import 'services/call_log_service.dart';
import 'models/call_log.dart';
import 'api.dart';
import 'chat_page.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

enum CallPhase { ringing, connecting, active, ended }

class CallPage extends StatefulWidget {
  final String peerId;
  final String peerName;
  final bool outgoing;

  // incoming only – navigator မှာ push လုပ်တဲ့အခါ ဖြည့်ပေးဖို့
  final String? initialCallId;
  final Map<String, dynamic>? initialOffer;

  // video call on/off (default: true = video call)
  final bool video;

  // Auto-accept call (for CallKit integration)
  final bool autoAccept;

  const CallPage({
    super.key,
    required this.peerId,
    required this.peerName,
    required this.outgoing,
    this.initialCallId,
    this.initialOffer,
    this.video = true,
    this.autoAccept = false,
  });

  @override
  State<CallPage> createState() => _CallPageState();
}

class _WavesPainter extends CustomPainter {
  final double progress;
  _WavesPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withOpacity(.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    const waves = 3;
    for (int i = 0; i < waves; i++) {
      final p = ((progress + i / waves) % 1.0);
      final radius = lerpDouble(40, size.shortestSide * .6, p)!;
      paint.color = Colors.white.withOpacity((1 - p) * .12);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavesPainter oldDelegate) =>
      oldDelegate.progress != progress;

  double? lerpDouble(num a, num b, double t) => a + (b - a) * t;
}

class _CallPageState extends State<CallPage> with TickerProviderStateMixin {
  // Signaling
  String? _myId;
  String? _callId;
  
  // Call tracking
  DateTime? _callStartTime;
  bool _callAccepted = false;
  String? _peerEmail;
  String? _peerAvatarUrl;
  bool _callLogged = false; // Prevent duplicate logging
  String? _myEmail; // Current user's email for display
  String? _myName; // Current user's name for display

  // WebRTC
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  // UI / state
  CallPhase _phase = CallPhase.ringing;
  bool _micOn = true;
  bool _camOn = true; // for video
  bool _speakerOn = true;
  bool _frontCamera = true;
  bool _isConnected = true; // Internet connection status
  
  // Call duration timer
  Timer? _callDurationTimer;
  Duration _callDuration = Duration.zero;
  
  // Call timeout timer (for unanswered calls)
  Timer? _callTimeoutTimer;
  static const Duration _callTimeoutDuration = Duration(seconds: 60); // 60 seconds timeout
  
  // Connectivity check timer
  Timer? _connectivityTimer;

  // STUN/TURN
  final Map<String, dynamic> _iceConfig = const {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      // {'urls':'turn:YOUR_TURN:3478','username':'u','credential':'p'},
    ],
  };

  // --- Animation controllers (UI only) -------------------------------------
  late final AnimationController
  _ringPulse; // accept/reject pulse while ringing
  late final AnimationController _titleBlink; // subtle connecting blink
  late final AnimationController _fabNudge; // small nudge on primary button

  // Draggable local preview position
  final Offset _pipOffset = const Offset(12, 12);

  // ---- lifecycle ------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    // Hide system status bar completely - use manual mode to hide only status bar
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.bottom], // Only show navigation bar, hide status bar completely
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
      ),
    );

    _ringPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
      lowerBound: .94,
      upperBound: 1.06,
    )..repeat(reverse: true);

    _titleBlink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _fabNudge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _boot();
  }

  @override
  void dispose() {
    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    
    _ringPulse.dispose();
    _titleBlink.dispose();
    _fabNudge.dispose();
    _callDurationTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _connectivityTimer?.cancel();

    SocketService.I.off('call:ringing', _onRinging);
    SocketService.I.off('call:answer', _onAnswer);
    SocketService.I.off('call:candidate', _onRemoteCandidate);
    SocketService.I.off('call:declined', _onDeclined);
    SocketService.I.off('call:ended', _onEnded);
    SocketService.I.off('CANCEL', _onCancelSignal);
    SocketService.I.off('callCancelled', _onCallCancelled);
    SocketService.I.off('callEnded', _onCallEndedSignal);

    _pc?.close();
    _localStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }
  
  void _startCallDurationTimer() {
    if (_callStartTime == null) return;
    _callDurationTimer?.cancel();
    _callDuration = Duration.zero;
    _callDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_callStartTime != null && _phase == CallPhase.active) {
        setState(() {
          _callDuration = DateTime.now().difference(_callStartTime!);
        });
      } else {
        timer.cancel();
      }
    });
    
    // Start connectivity check timer
    _startConnectivityCheck();
  }
  
  void _startConnectivityCheck() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_phase != CallPhase.active) {
        timer.cancel();
        return;
      }
      _checkConnectivity();
    });
  }
  
  Future<void> _checkConnectivity() async {
    try {
      // Simple connectivity check - try to reach a reliable server
      final response = await http.get(
        Uri.parse('https://www.google.com'),
      ).timeout(const Duration(seconds: 2));
      final isConnected = response.statusCode == 200;
      if (mounted && _isConnected != isConnected) {
        setState(() {
          _isConnected = isConnected;
        });
      }
    } catch (e) {
      if (mounted && _isConnected) {
        setState(() {
          _isConnected = false;
        });
      }
    }
  }
  
  /// Start timeout timer for unanswered calls
  void _startCallTimeout() {
    // Cancel any existing timeout timer
    _callTimeoutTimer?.cancel();
    
    // Start new timeout timer
    _callTimeoutTimer = Timer(_callTimeoutDuration, () {
      // Check if call is still ringing and not accepted
      if (mounted && _phase == CallPhase.ringing && !_callAccepted && !_callLogged) {
        debugPrint('Call timeout: call was not answered within ${_callTimeoutDuration.inSeconds} seconds');
        
        // Determine the correct status based on call direction
        // For outgoing calls: cancelled (caller cancelled/no answer)
        // For incoming calls: missed (receiver missed the call)
        final status = widget.outgoing ? CallStatus.cancelled : CallStatus.missed;
        
        // Notify the other party that the call has ended due to timeout
        if (_callId != null) {
          SocketService.I.emit('call:hangup', {'callId': _callId});
        }
        
        // Log the call with the appropriate status
        _logCallEnded(status).then((_) {
          // Update UI and end the call
          if (mounted) {
            setState(() => _phase = CallPhase.ended);
            _toast(widget.outgoing ? 'Call not answered' : 'Missed call');
            
            // Wait a moment to show the message, then close
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (mounted) {
                _endLocal(skipLogging: true); // Skip logging since we already logged
              }
            });
          }
        });
      }
    });
  }
  
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ---- setup ---------------------------------------------------------------

  Future<void> _boot() async {
    final u = await AuthStore.getUser();
    _myId = u?['id']?.toString();
    _myName = u?['name']?.toString(); // Use name only

    // Load peer profile info for call log
    await _loadPeerProfile();

    await _localRenderer.initialize();
    await _remoteRenderer.initialize();

    // Open media (camera opens for all video calls, but UI won't show it for incoming during ringing)
    await _openMedia();
    
    // Track call start
    _callStartTime = DateTime.now();

    // PeerConnection
    _pc = await createPeerConnection(_iceConfig);

    // add local tracks
    if (_localStream != null) {
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
      }
    }

    // remote tracks
    _pc!.onTrack = (RTCTrackEvent ev) async {
      debugPrint('=== onTrack event ===');
      debugPrint('Track kind: ${ev.track.kind}');
      debugPrint('Streams: ${ev.streams.length}');
      
      if (ev.streams.isNotEmpty) {
        _remoteStream = ev.streams.first;
        _remoteRenderer.srcObject = _remoteStream;
        
        debugPrint('Remote stream ID: ${_remoteStream?.id}');
        debugPrint('Video tracks: ${_remoteStream?.getVideoTracks().length}');
        debugPrint('Audio tracks: ${_remoteStream?.getAudioTracks().length}');
        
        // Ensure video tracks are enabled
        for (final track in _remoteStream!.getVideoTracks()) {
          track.enabled = true;
          debugPrint('Video track: id=${track.id}, enabled=${track.enabled}');
        }
        
        // Force UI update - try multiple times to ensure it renders
        if (mounted) {
          setState(() {
            debugPrint('State updated - remote video stream received');
          });
          // Also update after delays to ensure renderer is ready
          Future.delayed(const Duration(milliseconds: 200), () {
            if (mounted) {
              setState(() {
                debugPrint('First delayed update for remote video');
              });
            }
          });
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                debugPrint('Second delayed update for remote video');
              });
            }
          });
        }
      } else {
        debugPrint('Track without stream: ${ev.track.kind}');
      }
      if (mounted) {
        setState(() {});
      }
    
    };

    // ICE
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      if (_callId == null) return;
      SocketService.I.emit('call:candidate', {
        'callId': _callId,
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      });
    };

    // audio route (video calls usually speaker on)
    await Helper.setSpeakerphoneOn(_speakerOn);

    // register signaling (⚠️ call:incoming ကို မနားထောင်!)
    SocketService.I.on('call:ringing', _onRinging);
    SocketService.I.on('call:answer', _onAnswer);
    SocketService.I.on('call:candidate', _onRemoteCandidate);
    SocketService.I.on('call:declined', _onDeclined);
    SocketService.I.on('call:ended', _onEnded);
    // CRITICAL: Listen for CANCEL, callCancelled, and callEnded signals
    // These are emitted when the caller cancels/ends the call
    SocketService.I.on('CANCEL', _onCancelSignal);
    SocketService.I.on('callCancelled', _onCallCancelled);
    SocketService.I.on('callEnded', _onCallEndedSignal);

    // flows
    if (widget.outgoing) {
      await _startOutgoing();
    } else {
      // incoming → use initial offer
      _callId = widget.initialCallId;
      final sdp = widget.initialOffer ?? const {};
      if (_callId == null || sdp.isEmpty) {
        _toast('No call session'); // defensive
        _endLocal(endRemote: false);
        return;
      }
      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdp['sdp'], sdp['type']),
      );
      setState(() => _phase = CallPhase.ringing);
      
      // Auto-accept if coming from CallKit
      if (widget.autoAccept) {
        debugPrint('Auto-accepting call from CallKit');
        // Small delay to ensure everything is set up
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _accept();
          }
        });
      } else {
        // Start timeout timer for incoming calls (only if not auto-accepting)
      _startCallTimeout();
      }
    }
  }

  Future<void> _openMedia() async {
    final constraints = <String, dynamic>{
      'audio': true,
      'video': widget.video
          ? {
              'facingMode': _frontCamera ? 'user' : 'environment',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24},
            }
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    _localRenderer.srcObject = _localStream;
  }

  // ---- signaling (handlers) -----------------------------------------------

  void _onRinging(dynamic data) {
    // for caller; server echoes that callee is ringing + returns callId
    final m = Map<String, dynamic>.from(data ?? {});
    final to = (m['to'] ?? '').toString();
    if (to != widget.peerId) return;
    final cid = (m['callId'] ?? '').toString();
    if (cid.isNotEmpty) _callId = cid;
    setState(() => _phase = CallPhase.ringing);
    
    // Start timeout timer for outgoing calls
    if (widget.outgoing) {
      _startCallTimeout();
    }
  }

  Future<void> _onAnswer(dynamic data) async {
    // for caller; callee accepted and sent answer SDP
    final m = Map<String, dynamic>.from(data ?? {});
    final from = (m['from'] ?? '').toString();
    if (from != widget.peerId) return;
    final sdp = Map<String, dynamic>.from(m['sdp'] ?? {});
    if (sdp.isEmpty) return;
    await _pc?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'], sdp['type']),
    );
    setState(() {
      _phase = CallPhase.active;
      _callAccepted = true;
    });
    // Cancel timeout timer since call was answered
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    // Start call duration timer
    _startCallDurationTimer();
    // Check connectivity immediately
    _checkConnectivity();
  }

  Future<void> _onRemoteCandidate(dynamic data) async {
    final m = Map<String, dynamic>.from(data ?? {});
    final from = (m['from'] ?? '').toString();
    if (from != widget.peerId) return;
    final c = Map<String, dynamic>.from(m['candidate'] ?? {});
    if (c.isEmpty) return;
    await _pc?.addCandidate(
      RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
    );
  }

  void _onDeclined(dynamic _) {
    if (_callLogged) return; // Prevent duplicate handling
    // Cancel timeout timer since call was declined
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    setState(() => _phase = CallPhase.ended);
    _toast('Call declined');
    
    // Log the call
    _logCallEnded(CallStatus.rejected).then((_) {
      // Wait a moment to show the message, then close
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          _endLocal(skipLogging: true); // Skip logging since we already logged
        }
      });
    });
  }

  void _onEnded(dynamic data) {
    // Check if this event is for the current call
    final callId = (data is Map) ? (data['callId']?.toString() ?? '') : '';
    if (callId.isNotEmpty && _callId != null && callId != _callId) {
      debugPrint('⚠️ call:ended event for different call (current: $_callId, received: $callId) - ignoring');
      return; // Not for this call
    }
    
    if (_callLogged) return; // Prevent duplicate handling
    // Cancel timeout timer since call was ended
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    setState(() => _phase = CallPhase.ended);
    
    // Determine the correct status:
    // - If call was accepted and active: completed
    // - If call was never accepted (timeout/no answer): missed (incoming) or cancelled (outgoing)
    final status = _callAccepted 
        ? CallStatus.completed 
        : (widget.outgoing ? CallStatus.cancelled : CallStatus.missed);
    
    _toast(status == CallStatus.completed 
        ? 'Call ended' 
        : (widget.outgoing ? 'Call not answered' : 'Missed call'));
    
    // Log the call with the appropriate status
    _logCallEnded(status).then((_) {
      // Wait a moment to show the message, then close
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          _endLocal(skipLogging: true); // Skip logging since we already logged
        }
      });
    });
  }
  
  /// Handle CANCEL signal - when caller cancels the call
  void _onCancelSignal(dynamic data) {
    if (!mounted || _callId == null) return;
    
    final callData = Map<String, dynamic>.from(data ?? {});
    final receivedCallId = callData['callId']?.toString() ?? '';
    
    // Only handle if this is for the current call
    if (receivedCallId != _callId) {
      debugPrint('⚠️ CANCEL signal for different call (current: $_callId, received: $receivedCallId) - ignoring');
      return;
    }
    
    debugPrint('🚫 CANCEL signal received for call $_callId - closing CallPage immediately');
    
    // For incoming calls, if caller cancels, log as cancelled/missed
    if (!widget.outgoing && !_callAccepted) {
      if (!_callLogged) {
        _logCallEnded(CallStatus.missed);
      }
    }
    
    // Cancel timeout timer
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    
    // CRITICAL: Immediately pop CallPage when cancel is received
    // This works even if app is in background because we use Navigator.pop(context)
    if (mounted) {
      setState(() => _phase = CallPhase.ended);
      // Call _endLocal which will pop the page and clean up resources
      _endLocal(skipLogging: true);
      debugPrint('✅ CallPage closed immediately on CANCEL signal');
    }
  }
  
  /// Handle callCancelled signal - when caller cancels before receiver answers
  void _onCallCancelled(dynamic data) {
    if (!mounted || _callId == null) return;
    
    final callData = Map<String, dynamic>.from(data ?? {});
    final receivedCallId = callData['callId']?.toString() ?? '';
    
    // Only handle if this is for the current call
    if (receivedCallId != _callId) {
      debugPrint('⚠️ callCancelled signal for different call (current: $_callId, received: $receivedCallId) - ignoring');
      return;
    }
    
    debugPrint('🚫 callCancelled signal received for call $_callId - closing CallPage immediately');
    
    // For incoming calls, if caller cancels, log as missed
    if (!widget.outgoing && !_callAccepted) {
      if (!_callLogged) {
        _logCallEnded(CallStatus.missed);
      }
    }
    
    // Cancel timeout timer
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    
    // CRITICAL: Immediately pop CallPage when cancel is received
    // This works even if app is in background because we use Navigator.pop(context)
    if (mounted) {
      setState(() => _phase = CallPhase.ended);
      // Call _endLocal which will pop the page and clean up resources
      _endLocal(skipLogging: true);
      debugPrint('✅ CallPage closed immediately on callCancelled signal');
    }
  }
  
  /// Handle callEnded signal - proper termination signal
  void _onCallEndedSignal(dynamic data) {
    if (!mounted || _callId == null) return;
    
    final callData = Map<String, dynamic>.from(data ?? {});
    final receivedCallId = callData['callId']?.toString() ?? '';
    
    // Only handle if this is for the current call
    if (receivedCallId != _callId) {
      debugPrint('⚠️ callEnded signal for different call (current: $_callId, received: $receivedCallId) - ignoring');
      return;
    }
    
    debugPrint('🚫 callEnded signal received for call $_callId - closing CallPage');
    
    // Cancel timeout timer
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    
    // Set phase to ended and close
    if (mounted) {
      setState(() => _phase = CallPhase.ended);
      if (!_callLogged) {
        final status = _callAccepted 
            ? CallStatus.completed 
            : (widget.outgoing ? CallStatus.cancelled : CallStatus.missed);
        _logCallEnded(status).then((_) {
          if (mounted) {
            _endLocal(skipLogging: true);
          }
        });
      } else {
        _endLocal(skipLogging: true);
      }
    }
  }

  // ---- flows ---------------------------------------------------------------

  Future<void> _startOutgoing() async {
    setState(() => _phase = CallPhase.connecting);

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': widget.video ? 1 : 0,
    });
    await _pc!.setLocalDescription(offer);

    SocketService.I.emit('call:invite', {
      'to': widget.peerId,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
      'kind': widget.video ? 'video' : 'audio', // ⬅️ Tell backend it's a video call
    });
    debugPrint('Call invite sent: to=${widget.peerId}, kind=${widget.video ? 'video' : 'audio'}');

    // server will emit `call:ringing` with callId back
    setState(() => _phase = CallPhase.ringing);
    
    // Start timeout timer for outgoing calls
    _startCallTimeout();
  }

  Future<void> _accept() async {
    if (_callId == null) {
      _toast('No call session');
      return;
    }
    // Cancel timeout timer since call was accepted
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    setState(() {
      _phase = CallPhase.connecting;
      _callAccepted = true;
    });

    final answer = await _pc!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': widget.video ? 1 : 0,
    });
    await _pc!.setLocalDescription(answer);

    SocketService.I.emit('call:answer', {
      'callId': _callId,
      'accept': true,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });

    setState(() {
      _phase = CallPhase.active;
      _callAccepted = true;
      debugPrint('Receiver accepted call - phase: $_phase, video: ${widget.video}');
    });
    // Start call duration timer
    _startCallDurationTimer();
    // Check connectivity immediately
    _checkConnectivity();
  }

  Future<void> _reject() async {
    if (_callLogged) return; // Prevent duplicate handling
    // Cancel timeout timer since call was rejected
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    if (_callId != null) {
      SocketService.I.emit('call:answer', {'callId': _callId, 'accept': false});
    }
    _logCallEnded(CallStatus.rejected);
    _endLocal(skipLogging: true); // Skip logging since we already logged
  }

  Future<void> _hangup() async {
    if (_callLogged) return; // Prevent duplicate handling
    // Cancel timeout timer since call was hung up
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    if (_callId != null) {
      SocketService.I.emit('call:hangup', {'callId': _callId});
    }
    _logCallEnded(_callAccepted ? CallStatus.completed : CallStatus.cancelled);
    _endLocal(skipLogging: true); // Skip logging since we already logged
  }

  void _endLocal({bool endRemote = true, bool skipLogging = false}) {
    // Cancel timeout timer
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    
    // If call was ringing but never accepted, log as missed (for incoming) or cancelled (for outgoing)
    if (!skipLogging && _callStartTime != null && !_callAccepted && _phase == CallPhase.ringing && !_callLogged) {
      final status = widget.outgoing ? CallStatus.cancelled : CallStatus.missed;
      _logCallEnded(status);
    }
    
    // Clean up resources
    try {
      _pc?.close();
      _localStream?.dispose();
    } catch (_) {}
    _pc = null;
    _localStream = null;
    
    // Navigate back
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
  
  /// Load peer profile information
  Future<void> _loadPeerProfile() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBase/users/by-ids?ids=${widget.peerId}'),
        headers: await authHeaders(),
      );
      if (response.statusCode == 200) {
        final map = Map<String, dynamic>.from(jsonDecode(response.body));
        final peerData = map[widget.peerId];
        if (peerData != null) {
          _peerEmail = peerData['email']?.toString();
          _peerAvatarUrl = peerData['avatarUrl']?.toString();
        }
      }
    } catch (e) {
      debugPrint('Error loading peer profile: $e');
    }
  }
  
  /// Log call when it ends
  Future<void> _logCallEnded(CallStatus status) async {
    if (_callStartTime == null || _callLogged) {
      debugPrint('Skipping duplicate call log: startTime=$_callStartTime, logged=$_callLogged');
      return;
    }
    _callLogged = true; // Prevent duplicate logging
    
    final endTime = DateTime.now();
    final duration = endTime.difference(_callStartTime!);
    
    // Use server-provided callId if available, otherwise generate one
    // The callId should be the same for both participants (from server)
    final callId = _callId ?? '${_myId}_${widget.peerId}_${_callStartTime!.millisecondsSinceEpoch}';
    
    debugPrint('Logging call: id=$callId, status=$status, duration=${duration.inSeconds}s, type=${widget.outgoing ? "outgoing" : "incoming"}');
    
    // Only include duration for completed calls
    final callDuration = (status == CallStatus.completed && duration.inSeconds > 0) 
        ? duration 
        : null;
    
    await CallLogService.logCall(
      callId: callId,
      peerId: widget.peerId,
      peerName: widget.peerName,
      peerEmail: _peerEmail,
      peerAvatarUrl: _peerAvatarUrl,
      type: widget.outgoing ? CallType.outgoing : CallType.incoming,
      status: status,
      startTime: _callStartTime!,
      endTime: endTime,
      duration: callDuration,
      isVideoCall: widget.video,
    );
  }

  // ---- controls ------------------------------------------------------------

  void _toggleMic() {
    _micOn = !_micOn;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = _micOn);
    setState(() {});
  }

  Future<void> _toggleCam() async {
    if (!widget.video) return;
    _camOn = !_camOn;
    for (final t in _localStream?.getVideoTracks() ?? []) {
      t.enabled = _camOn;
    }
    setState(() {});
  }

  Future<void> _switchCamera() async {
    if (!widget.video) return;
    _frontCamera = !_frontCamera;
    final videoTrack = _localStream?.getVideoTracks().firstOrDefault;
    if (videoTrack != null) {
      await Helper.switchCamera(videoTrack);
    }
    setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    await Helper.setSpeakerphoneOn(_speakerOn);
    setState(() {});
  }

  // ---- ui ------------------------------------------------------------------

  Widget _buildStatusBar() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 360;
    final iconSize = isSmallScreen ? 16.0 : 18.0;
    final fontSize = isSmallScreen ? 14.0 : 16.0;
    final smallFontSize = isSmallScreen ? 12.0 : 14.0;
    final isCaller = widget.outgoing;
    
    return Column(
      children: [
        // Top status bar with time, camera notch area, battery
        Container(
      padding: EdgeInsets.only(
            top: 8, // Fixed padding since system status bar is hidden
        left: isSmallScreen ? 8 : 16,
        right: isSmallScreen ? 8 : 16,
            bottom: 4,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
              // Left side: Time (and icons for incoming)
              Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                  Text(
                      _getCurrentTime(),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (!isCaller) ...[
                  const SizedBox(width: 4),
                    const Icon(Icons.security, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                    Icon(Icons.settings, color: Colors.white, size: iconSize),
                  ],
                ],
              ),
              // Center: Camera notch area - show time with gear for outgoing, empty for incoming
              if (isCaller)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _getCurrentTime(),
                        style: TextStyle(
                          color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w500,
                        ),
                      ),
                    const SizedBox(width: 4),
                    Icon(Icons.settings, color: Colors.white, size: iconSize),
                ],
                )
              else
                const SizedBox(width: 80), // Spacer for camera notch
              // Right side: Signal, WiFi, Battery
              Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                  Icon(Icons.signal_cellular_alt, color: Colors.white, size: iconSize),
                  SizedBox(width: isSmallScreen ? 4 : 6),
                Icon(Icons.wifi, color: Colors.white, size: iconSize),
                  SizedBox(width: isSmallScreen ? 4 : 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '97%',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: smallFontSize,
                    ),
                  ),
                ),
                SizedBox(width: isSmallScreen ? 2 : 4),
                Icon(Icons.battery_full, color: Colors.white, size: iconSize),
              ],
              ),
            ],
          ),
        ),
        // Second row: Time with shield, gear, copyright icons (matches image)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _getCurrentTime(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.security, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Icon(Icons.settings, color: Colors.white, size: iconSize),
              const SizedBox(width: 6),
              // Copyright icon (C in circle)
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: const Center(
                  child: Text(
                    'C',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
            ),
          ),
        ],
      ),
        ),
      ],
    );
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute;
    final period = hour >= 12 ? 'PM' : 'AM';
    final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
    return '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
  }

  Widget _buildAvatar() {
    // Get first letter of peer name for initial
    final initial = widget.peerName.isNotEmpty 
        ? widget.peerName[0].toUpperCase() 
        : '?';
    
    return AnimatedBuilder(
      animation: _ringPulse,
      builder: (context, child) {
        final pulseValue = _ringPulse.value;
    return Container(
      width: 200,
      height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer ring (darker purple) - pulsing
              Container(
                width: 200 + (pulseValue - 1.0) * 20,
                height: 200 + (pulseValue - 1.0) * 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
                  color: const Color(0xFF7A5A9A).withOpacity(0.3 * (2.0 - pulseValue)),
                ),
              ),
              // Middle ring (lighter purple) - pulsing
              Container(
                width: 180 + (pulseValue - 1.0) * 15,
                height: 180 + (pulseValue - 1.0) * 15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFB19CD9).withOpacity(0.4 * (2.0 - pulseValue)),
                ),
              ),
              // Inner circle (teal/turquoise) with initial
              Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF4ECDC4), // Light teal/turquoise
        boxShadow: [
          BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 20,
                      spreadRadius: 2,
          ),
        ],
      ),
      child: _peerAvatarUrl != null && _peerAvatarUrl!.isNotEmpty
          ? ClipOval(
              child: Image.network(
                _peerAvatarUrl!,
                fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => _buildAvatarPlaceholder(initial),
              ),
            )
                    : _buildAvatarPlaceholder(initial),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAvatarPlaceholder(String initial) {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFF4ECDC4), // Light teal/turquoise
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 72,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
  
  // Check if remote video is available - simplified check
  bool _hasRemoteVideo() {
    try {
      final stream = _remoteRenderer.srcObject;
      if (stream == null) {
        return false;
      }
      final videoTracks = stream.getVideoTracks();
      // If there are video tracks, assume video is available (even if not yet enabled)
      return videoTracks.isNotEmpty;
    } catch (e) {
      debugPrint('Error checking remote video: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCaller = widget.outgoing;
    debugPrint('Build: phase=$_phase, video=${widget.video}, isCaller=$isCaller, showingVideoUI=${widget.video && (_phase == CallPhase.active || _phase == CallPhase.connecting || (_phase == CallPhase.ringing && !isCaller))}');
    final statusText = switch (_phase) {
      CallPhase.ringing => widget.outgoing 
          ? (widget.video ? 'Ringing....' : 'Ringing....')
          : (widget.video ? 'Video call incoming' : 'Incoming call'),
      CallPhase.connecting => widget.video ? 'Video call Connecting...' : 'Connecting...',
      CallPhase.active => 'IN CALL',
      CallPhase.ended => widget.outgoing ? 'CALL DECLINED' : 'CALL ENDED',
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: Container(
          width: double.infinity,
          height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
                const Color(0xFFE6D5F5), // Soft lavender-purple (top)
                const Color(0xFF9B7BB8), // Deeper indigo-purple (bottom)
            ],
          ),
        ),
          child: Column(
            children: [
              // Main content area - Video call shows video feed, audio call shows avatar
              // Show video UI only when: video call is active OR connecting (NOT during incoming call ringing)
              Expanded(
                child: (widget.video && (_phase == CallPhase.active || _phase == CallPhase.connecting))
                    ? Stack(
                        children: [
                          // Remote video (full screen during active video call)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(color: Colors.black),
                              child: (_remoteRenderer.srcObject != null)
                                      ? RTCVideoView(
                                          _remoteRenderer,
                                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                                        )
                                      : Center(
                                          // Show placeholder if no remote video yet
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              _buildAvatar(),
                                              const SizedBox(height: 24),
                                              Text(
                                                widget.peerName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                'Connecting video...',
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.7),
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                            ),
                          ),
                          
                          // Top bar overlay for video calls (like the image)
                          // Show during active call or connecting
                          if (widget.video && (_phase == CallPhase.active || _phase == CallPhase.connecting))
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withOpacity(0.6),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                                child: SafeArea(
                                  bottom: false,
                                  child: Stack(
                                    children: [
                                      // Left side: Back button
                                      Positioned(
                                        left: 0,
                                        child: IconButton(
                                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                                          onPressed: () => Navigator.of(context).pop(),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ),
                                      // Center: Caller name and duration (centered)
                                      Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              widget.peerName,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            // Show call duration only during active call
                                            if (_phase == CallPhase.active)
                                              Text(
                                                _formatDuration(_callDuration),
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.8),
                                                  fontSize: 14,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      // Right side: Menu button (only during active call)
                                      if (_phase == CallPhase.active)
                                        Positioned(
                                          right: 0,
                                          child: IconButton(
                                            icon: const Icon(Icons.more_vert, color: Colors.white),
                                            onPressed: () {
                                              // Show menu options
                                              _toast('Menu');
                                            },
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          
                          // Local preview (fixed position bottom right - like the image)
                          // Only show during active call or connecting (for outgoing calls)
                          if (_phase == CallPhase.active || (_phase == CallPhase.connecting && isCaller && widget.video))
                            Positioned(
                              right: 16,
                              bottom: 120, // Above the control buttons
                              width: 110,
                              height: 150,
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.3),
                                          width: 1.5,
                                        ),
                                      ),
                                      child: RTCVideoView(
                                        _localRenderer,
                                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                                        mirror: _frontCamera,
                                      ),
                                    ),
                                  ),
                                  // Camera switch button (top right of local preview)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: GestureDetector(
                                      onTap: _switchCamera,
                                      child: Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.6),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.flip_camera_ios,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // For incoming calls: Show caller name, avatar, then status
                          if (!isCaller && _phase == CallPhase.ringing) ...[
                            // Caller name - Large white text at top
                                    Text(
                              widget.peerName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 42,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                                ),
                              ),
                            const SizedBox(height: 32),
                            
                            // Avatar - Large circular with pulsing rings
                            _buildAvatar(),
                            
                            const SizedBox(height: 24),
                            
                            // Call status - "calling → [current user name]"
                            Text(
                              'calling → ${_myName ?? 'you'}...',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ] else ...[
                            // For outgoing calls or other phases
                            // Caller name - Large white text
                            Text(
                              widget.peerName,
                              style: const TextStyle(
                                color: Colors.white,
                              fontSize: 42,
                                fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                              ),
                            ),
                          const SizedBox(height: 32),
                          
                            // Avatar - Large circular
                          AnimatedScale(
                            scale: _phase == CallPhase.ringing
                                ? 0.95 + 0.05 * math.sin(_ringPulse.value * 2 * math.pi)
                                : 1.0,
                            duration: const Duration(milliseconds: 200),
                            child: _buildAvatar(),
                          ),
                          ],
                          
                          // Internet connection and timing under avatar (only when call is active)
                          // Only show status text for outgoing calls or other phases, NOT for incoming calls during ringing
                          if (_phase == CallPhase.active) ...[
                            const SizedBox(height: 16),
                            // Internet connection status
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isConnected ? Icons.signal_cellular_alt : Icons.signal_cellular_off,
                                  color: _isConnected ? Colors.green : Colors.red,
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _isConnected ? 'Connected' : 'No Internet',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.9),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // Call duration (timing)
                            Text(
                              _formatDuration(_callDuration),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ] else if (!(!isCaller && _phase == CallPhase.ringing)) ...[
                            // Status text below avatar (for non-active phases, but NOT for incoming calls during ringing)
                          const SizedBox(height: 24),
                            AnimatedBuilder(
                              animation: _titleBlink,
                              builder: (_, __) {
                                final blink = (_phase == CallPhase.connecting)
                                    ? (0.7 + 0.3 * (0.5 + 0.5 * math.sin(_titleBlink.value * 2 * math.pi)))
                                    : 1.0;
                                return Opacity(
                                  opacity: blink,
                                child: Text(
                                        statusText,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.w500,
                                    letterSpacing: 1.0,
                                              ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
              ),
              
              // Action buttons (for incoming calls during ringing phase) - matches right side screen
              if (!isCaller && _phase == CallPhase.ringing)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Accept and Decline buttons (row)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Accept button (left) - Green
                            ScaleTransition(
                              scale: _ringPulse,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.green,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.green.withOpacity(0.4),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Transform.rotate(
                                  angle: -0.5, // Rotate phone icon to point left (matches image)
                                  child: IconButton(
                                    icon: const Icon(
                                      Icons.call,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                    onPressed: _accept,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 80),
                            // Decline button (right) - Red
                            ScaleTransition(
                              scale: _ringPulse,
                              child: Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.red,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.red.withOpacity(0.4),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Transform.rotate(
                                  angle: 0.5, // Rotate phone icon to point left (matches image)
                                  child: IconButton(
                                    icon: const Icon(
                                      Icons.call_end,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                    onPressed: _reject,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              // Action buttons (for outgoing calls during ringing/connecting phase)
              else if (isCaller && (_phase == CallPhase.ringing || _phase == CallPhase.connecting))
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Speaker button (left) - Light blue-grey translucent
                        _buildCallerControlButton(
                          icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                          onTap: _toggleSpeaker,
                          active: _speakerOn,
                        ),
                        
                        // Mute button - Light blue-grey translucent
                        _buildCallerControlButton(
                          icon: _micOn ? Icons.mic : Icons.mic_off,
                          onTap: _toggleMic,
                          active: !_micOn,
                        ),
                        
                        // Video camera button (only for video calls) - Purple/lilac with white border
                        if (widget.video)
                          _buildVideoCameraButton(
                            icon: _camOn ? Icons.videocam : Icons.videocam_off,
                            onTap: _toggleCam,
                            active: _camOn,
                          ),
                        
                        // End Call button (right) - Solid red with glow
                        ScaleTransition(
                          scale: _ringPulse,
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.red,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.red.withOpacity(0.6),
                                  blurRadius: 20,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _hangup,
                                borderRadius: BorderRadius.circular(32),
                                  child: Container(
                                  width: 64,
                                  height: 64,
                                    alignment: Alignment.center,
                                    child: Transform.rotate(
                                    angle: 0.5,
                                      child: const Icon(
                                        Icons.call_end,
                                        color: Colors.white,
                                      size: 32,
                                      ),
                                    ),
                                  ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_phase == CallPhase.active || _phase == CallPhase.connecting)
                // Video call controls at bottom - flexible and responsive design
                SafeArea(
                  top: false,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: MediaQuery.of(context).size.width * 0.05, // 5% of screen width
                      vertical: 20,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.6),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Speaker button
                            _buildFlexibleControlButton(
                              icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                              onTap: _toggleSpeaker,
                              active: _speakerOn,
                          size: 64,
                            ),
                            
                            // Mute button
                            _buildFlexibleControlButton(
                              icon: _micOn ? Icons.mic : Icons.mic_off,
                              onTap: _toggleMic,
                              active: !_micOn,
                          size: 64,
                            ),
                            
                            // Video toggle button (only for video calls)
                            if (widget.video)
                              _buildFlexibleControlButton(
                                icon: _camOn ? Icons.videocam : Icons.videocam_off,
                                onTap: _toggleCam,
                                active: _camOn,
                            size: 64,
                              ),
                            
                        // End Call button - Red button (same size as others)
                            _buildFlexibleEndButton(
                          size: 64,
                            ),
                          ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // Video call control button (matching the image design)
  Widget _buildVideoCallControlButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(50),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(active ? 0.3 : 0.2),
          border: Border.all(
            color: Colors.white.withOpacity(active ? 0.8 : 0.5),
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  // Flexible control button that adapts to screen size
  Widget _buildFlexibleControlButton({
    required IconData icon,
    required VoidCallback onTap,
    required double size,
    bool active = false,
  }) {
    final iconSize = (size * 0.43).clamp(20.0, 28.0);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(active ? 0.3 : 0.2),
            border: Border.all(
              color: Colors.white.withOpacity(active ? 0.8 : 0.5),
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  // Caller control button - Light blue-grey translucent with white outline (matches image)
  Widget _buildCallerControlButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(32),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFB0C4DE).withOpacity(0.3), // Light blue-grey translucent
            border: Border.all(
              color: Colors.white.withOpacity(0.9),
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: 28,
          ),
        ),
      ),
    );
  }

  // Video camera button - Purple/lilac with white border (matches image)
  Widget _buildVideoCameraButton({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(32),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFB19CD9).withOpacity(0.4), // Purple/lilac translucent
            border: Border.all(
              color: Colors.white.withOpacity(0.9),
              width: 1.5,
            ),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: 28,
          ),
        ),
      ),
    );
  }

  // Flexible end call button that adapts to screen size
  Widget _buildFlexibleEndButton({
    required double size,
  }) {
    final iconSize = (size * 0.5).clamp(24.0, 32.0);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _hangup,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red,
            boxShadow: [
              BoxShadow(
                color: Colors.red.withOpacity(0.5),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            Icons.call_end,
            color: Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  // Viber-style control button (for active call controls)
  Widget _buildViberControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? activeColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(50),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active 
                  ? (activeColor ?? Colors.blue).withOpacity(0.2)
                  : Colors.white.withOpacity(0.2),
              border: Border.all(
                color: active 
                    ? (activeColor ?? Colors.blue)
                    : Colors.white.withOpacity(0.5),
                width: active ? 2 : 1,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: (activeColor ?? Colors.blue).withOpacity(0.3),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
            ),
            child: Icon(
              icon,
              color: active 
                  ? (activeColor ?? Colors.blue)
                  : Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // Action button for the grid (Contact, Mute, etc.)
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool isBottomBar = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(50),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: isBottomBar ? 48 : 56,
            height: isBottomBar ? 48 : 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              icon,
              color: active ? Colors.blue.shade700 : Colors.blue.shade900,
              size: isBottomBar ? 24 : 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // keep icon API; add subtle glow when active
  Widget _roundIcon({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          shape: BoxShape.circle,
          boxShadow: active
              ? [
                  BoxShadow(
                    color: Colors.white.withOpacity(.4),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }

  // ringing waves painter
  // purely visual; uses black background so only subtle lines appear over video
  // progress 0..1

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }
}

// small helper
extension _X on List<MediaStreamTrack> {
  MediaStreamTrack? get firstOrDefault => isEmpty ? null : first;
}

// helpers for pip drag bounds (prevent negative offsets during gesture)
double rightPaddingClamp(double v) => v;
double bottomPaddingClamp(double v) => v;
