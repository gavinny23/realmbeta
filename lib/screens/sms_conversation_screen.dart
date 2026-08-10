import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/sms_bridge_service.dart';
import '../services/app_storage_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/cheat_code_trigger.dart';
import 'chat_conversation_screen.dart' show MessageTicks;

/// One bridged SMS thread. Same visual language as
/// ChatConversationScreen, but every "sent" message goes out as a
/// real text via the gateway phone (see SmsGatewayBridge), and every
/// "received" message is a real SMS reply that phone picked up.
class SmsConversationScreen extends StatefulWidget {
  final String threadId;
  final String gatewayDeviceId;
  final String phoneNumber;
  final String? displayName;

  SmsConversationScreen({
    super.key,
    required this.threadId,
    required this.gatewayDeviceId,
    required this.phoneNumber,
    this.displayName,
  });

  @override
  State<SmsConversationScreen> createState() => _SmsConversationScreenState();
}

class _SmsConversationScreenState extends State<SmsConversationScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  StreamSubscription<List<Map<String, dynamic>>>? _sub;

  List<Map<String, dynamic>> _serverMessages = [];
  List<Map<String, dynamic>> _outbox = [];

  // A brand-new thread (started via "Text a phone number") has no id
  // yet — the server creates it on the first send_sms_message call
  // (find-or-create, see v14-migration.sql). Everything that needs a
  // real thread id waits until this is set.
  late String _threadId;

  bool _loading = true;
  bool _sending = false;
  bool _flushingOutbox = false;
  String? _error;

  String get _cacheKey => 'sms_messages_$_threadId';
  String get _outboxKey => 'sms_outbox_$_threadId';

  List<Map<String, dynamic>> get _messages {
    final merged = <Map<String, dynamic>>[..._serverMessages];
    for (final pending in _outbox) {
      final alreadyLanded = _serverMessages.any((m) =>
          m['direction'] == 'outbound' &&
          m['body'] == pending['body'] &&
          m['created_at'] == pending['created_at']);
      if (!alreadyLanded) merged.add(pending);
    }
    merged.sort((a, b) {
      final at = DateTime.tryParse(a['created_at'] as String? ?? '') ?? DateTime.now();
      final bt = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now();
      return at.compareTo(bt);
    });
    return merged;
  }

  @override
  void initState() {
    super.initState();
    _threadId = widget.threadId;
    _init();
  }

  Future<void> _init() async {
    if (_threadId.isEmpty) {
      // Nothing to fetch/watch yet — just show the empty-state compose
      // screen until the first message creates the thread.
      setState(() => _loading = false);
      return;
    }
    await _attachToThread(_threadId, loadCache: true);
  }

  /// Loads history, marks read, and subscribes to realtime for a real
  /// thread id — called immediately for an existing thread, or once
  /// a brand-new thread's first send comes back with its new id.
  Future<void> _attachToThread(String threadId, {bool loadCache = false}) async {
    if (loadCache) {
      final cachedMessages = await AppStorageService.instance.loadList(_cacheKey);
      final cachedOutbox = await AppStorageService.instance.loadList(_outboxKey);
      if (mounted) {
        setState(() {
          if (cachedMessages != null) _serverMessages = cachedMessages;
          if (cachedOutbox != null) _outbox = cachedOutbox;
          if (cachedMessages != null) _loading = false;
        });
        if (cachedMessages != null) _scrollToEnd();
      }
    }

    try {
      final history =
          await SmsBridgeService.instance.fetchSmsMessages(threadId: threadId);
      if (mounted) {
        setState(() {
          _serverMessages = history;
          _loading = false;
          _error = null;
        });
        _scrollToEnd();
      }
      await AppStorageService.instance.saveList(_cacheKey, history);
    } catch (e) {
      if (mounted && _serverMessages.isEmpty) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }

    await _sub?.cancel();
    _sub = SmsBridgeService.instance
        .watchSmsMessages(threadId: threadId)
        .listen((rows) {
      if (!mounted) return;
      setState(() => _serverMessages = rows);
      AppStorageService.instance.saveList(_cacheKey, rows);
      _scrollToEnd();
      _flushOutbox();
    });

    try {
      await SmsBridgeService.instance.markThreadRead(threadId);
    } catch (_) {
      // Non-critical — worst case the unread badge stays stale until
      // the next successful call.
    }
    _flushOutbox();
  }

  Future<void> _flushOutbox() async {
    if (_flushingOutbox || _outbox.isEmpty) return;
    _flushingOutbox = true;
    try {
      final queue = List<Map<String, dynamic>>.from(_outbox);
      for (final pending in queue) {
        try {
          final resp = await SmsBridgeService.instance.sendSms(
            gatewayDeviceId: widget.gatewayDeviceId,
            phoneNumber: widget.phoneNumber,
            body: pending['body'] as String,
          );
          if (_threadId.isEmpty) {
            final newId = resp['thread_id'] as String?;
            if (newId != null) {
              _threadId = newId;
              unawaited(_attachToThread(newId));
            }
          }
          if (mounted) {
            setState(() => _outbox
                .removeWhere((m) => m['_localId'] == pending['_localId']));
          } else {
            _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
          }
          await AppStorageService.instance.saveList(_outboxKey, _outbox);
        } catch (_) {
          break;
        }
      }
    } finally {
      _flushingOutbox = false;
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _msgCtrl.clear();

    final pending = {
      '_localId': '${DateTime.now().microsecondsSinceEpoch}',
      '_pending': true,
      'direction': 'outbound',
      'body': text,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    };
    setState(() {
      _outbox.add(pending);
      _sending = true;
    });
    await AppStorageService.instance.saveList(_outboxKey, _outbox);
    _scrollToEnd();

    try {
      final resp = await SmsBridgeService.instance.sendSms(
        gatewayDeviceId: widget.gatewayDeviceId,
        phoneNumber: widget.phoneNumber,
        body: text,
      );
      if (_threadId.isEmpty) {
        final newId = resp['thread_id'] as String?;
        if (newId != null) {
          _threadId = newId;
          unawaited(_attachToThread(newId));
        }
      }
      if (mounted) {
        setState(() => _outbox
            .removeWhere((m) => m['_localId'] == pending['_localId']));
      } else {
        _outbox.removeWhere((m) => m['_localId'] == pending['_localId']);
      }
      await AppStorageService.instance.saveList(_outboxKey, _outbox);
    } catch (_) {
      // Left queued — flushed again once we're back online, same as
      // ChatConversationScreen's outbox. From here it's queued in
      // Supabase as a 'pending' row too; the gateway phone (once back
      // online) will pick it up regardless of whether this screen is
      // even open.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _messages;
    final title = widget.displayName ?? widget.phoneNumber;

    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title),
            Text(
              'via SMS · ${widget.phoneNumber}',
              style: TextStyle(fontSize: 11, color: RMColors.textSecondary, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: RMColors.primary))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: RMColors.textSecondary)),
                        ),
                      )
                    : messages.isEmpty
                        ? Center(
                            child: Padding(
                              padding: EdgeInsets.all(28),
                              child: Text(
                                'No messages yet. What you send here goes out as a real text to $title.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: RMColors.textSecondary),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollCtrl,
                            padding: EdgeInsets.all(16),
                            itemCount: messages.length,
                            itemBuilder: (context, i) {
                              final m = messages[i];
                              final mine = m['direction'] == 'outbound';
                              final createdAt = DateTime.tryParse(
                                      m['created_at'] as String? ?? '') ??
                                  DateTime.now();
                              final status = m['status'] as String?;
                              return _SmsBubble(
                                text: m['body'] as String? ?? '',
                                time: createdAt,
                                mine: mine,
                                pending: m['_pending'] == true || status == 'pending' || status == 'sending',
                                failed: status == 'failed',
                              );
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (v) =>
                          CheatCodeTrigger.watch(context, _msgCtrl, v),
                      decoration: InputDecoration(
                        hintText: 'Text message...',
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmsBubble extends StatelessWidget {
  final String text;
  final DateTime time;
  final bool mine;
  final bool pending;
  final bool failed;

  const _SmsBubble({
    required this.text,
    required this.time,
    required this.mine,
    this.pending = false,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: failed
              ? RMColors.surface
              : (mine ? RMColors.primary : RMColors.surface),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: (mine && !failed)
              ? null
              : Border.all(color: failed ? Colors.redAccent : RMColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color: mine && !failed ? Colors.white : RMColors.textPrimary,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (failed)
                  Text('Not delivered — tap to retry',
                      style: TextStyle(color: Colors.redAccent, fontSize: 10))
                else
                  Text(
                    DateFormat('h:mm a').format(time),
                    style: TextStyle(
                      color: mine ? Colors.white70 : RMColors.textHint,
                      fontSize: 10,
                    ),
                  ),
                if (mine && !failed) ...[
                  SizedBox(width: 4),
                  MessageTicks(pending: pending, read: false),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
