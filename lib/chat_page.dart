import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'auth_store.dart';
import 'login_page.dart';
import 'socket_service.dart';
import 'foreground_chat.dart';

class ChatPage extends StatefulWidget {
  final String? peerId; // history GET (pending mode = null)
  final String partnerEmail; // send POST (toEmail)
  final String? peerName; // title

  const ChatPage({
    super.key,
    this.peerId,
    required this.partnerEmail,
    this.peerName,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  String? myId;
  String? peerId;
  bool loading = true;
  bool composerEnabled = false;

  /// စာ ရှိ/မရှိ track
  bool _hasText = false;

  final List<Map<String, dynamic>> _items = [];
  final Set<String> _seenIds = <String>{};

  @override
  void initState() {
    super.initState();
    peerId = widget.peerId;

    // input text ရှိ/မရှိ state update
    _input.addListener(() {
      final nowHasText = _input.text.trim().isNotEmpty;
      if (nowHasText != _hasText) {
        setState(() => _hasText = nowHasText);
      }
    });

    _init();
  }

  Future<void> _init() async {
    final u = await AuthStore.getUser();
    if (u == null) return _logout();
    myId = u['id'].toString();

    SocketService.I.on('message', _onMessage);
    SocketService.I.on('chat_request_accepted', _onAccepted);

    if (peerId != null) {
      ForegroundChat.currentPeerId = peerId;
      composerEnabled = true;
      await _loadHistory();
    } else {
      // ensure request (safe to call repeatedly)
      await postJson('/chat-requests', {
        'from': myId,
        'toEmail': widget.partnerEmail,
      });
      composerEnabled = false;
    }

    setState(() => loading = false);
    _scrollToBottom();
  }

  void _onAccepted(dynamic data) async {
    if (peerId != null) return;
    final map = (data is Map) ? Map<String, dynamic>.from(data) : {};
    final partnerId = map['partnerId']?.toString();
    if (partnerId == null) return;
    peerId = partnerId;
    ForegroundChat.currentPeerId = peerId;
    composerEnabled = true;
    setState(() {});
    await _loadHistory();
    _scrollToBottom();
  }

  void _onMessage(dynamic data) {
    if (peerId == null) return;
    final m = Map<String, dynamic>.from(data);
    final id = (m['_id'] ?? '').toString();
    final from = m['from']?.toString();
    final to = m['to']?.toString();

    final isThisThread =
        (from == peerId && to == myId) || (to == peerId && from == myId);
    if (!isThisThread) return;

    if (id.isNotEmpty && _seenIds.contains(id)) return;
    if (id.isNotEmpty) _seenIds.add(id);

    setState(() => _items.add(m));
    _scrollToBottom();
  }

  Future<void> _loadHistory() async {
    if (peerId == null) return;
    final r = await http.get(
      Uri.parse('$apiBase/messages?userA=$myId&userB=$peerId'),
      headers: await authHeaders(),
    );
    if (r.statusCode == 200) {
      final list = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      _items
        ..clear()
        ..addAll(list);
      _seenIds
        ..clear()
        ..addAll(
          list
              .map((e) => (e['_id'] ?? '').toString())
              .where((e) => e.isNotEmpty),
        );
      setState(() {});
    } else if (r.statusCode == 401) {
      _logout();
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || !composerEnabled) return;
    _input.clear();

    final res = await postJson('/messages', {
      'from': myId,
      'toEmail': widget.partnerEmail,
      'text': text,
    });

    if (res.statusCode != 200) {
      final msg = res.statusCode == 403
          ? 'Receiver has not accepted your request yet.'
          : res.statusCode == 404
          ? 'Recipient not found.'
          : 'Send failed (${res.statusCode})';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    // success → server echoes via socket → _onMessage() adds once (with _id)
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _logout() async {
    await AuthStore.clear();
    SocketService.I.disconnect();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    SocketService.I.off('message', _onMessage);
    SocketService.I.off('chat_request_accepted', _onAccepted);
    ForegroundChat.currentPeerId = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.peerName?.trim().isNotEmpty == true
        ? widget.peerName!.trim()
        : widget.partnerEmail;

    // စာရှိ + accepted ဖြစ်မှပဲ send ခလုတ် enable
    final bool canSend = composerEnabled && _hasText;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: Column(
        children: [
          if (!composerEnabled)
            Container(
              width: double.infinity,
              color: Colors.amber.withOpacity(.2),
              padding: const EdgeInsets.all(12),
              child: const Text('Pending… receiver must accept your request.'),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final m = _items[i];
                      final mine = m['from']?.toString() == myId;
                      final createdAt = _fmtTime(m['createdAt']?.toString());
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: mine ? Colors.blue : Colors.green,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: mine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Text(
                                m['text']?.toString() ?? '',
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                createdAt,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Attach photo',
                  icon: const Icon(Icons.photo),
                  // onPressed: (composerEnabled && !loading) ? _pickAndSendImage : null,
                  onPressed: () {},
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: TextField(
                      controller: _input,
                      enabled: composerEnabled && !loading,
                      onSubmitted: (_) => _send(),
                      textInputAction: TextInputAction.send,
                      decoration: InputDecoration(
                        hintText: composerEnabled
                            ? 'Type a message…'
                            : 'Waiting for acceptance…',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.send,
                    color: canSend
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).disabledColor,
                  ),
                  onPressed: canSend ? _send : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    final h = local.hour == 0
        ? 12
        : (local.hour > 12 ? local.hour - 12 : local.hour);
    final mm = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour >= 12 ? 'pm' : 'am';
    return '$h:$mm $ampm';
  }
}
