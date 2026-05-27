import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/message.dart';
import '../providers/chat_provider.dart';
import 'settings_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  // ── Speech ──────────────────────────────────────────────────────────────────
  final _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().init();
      _initSpeech();
    });
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onError: (_) => setState(() => _isListening = false),
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
    );
    setState(() => _speechAvailable = available);
  }

  Future<void> _toggleListening() async {
    if (!_speechAvailable) return;

    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }

    // Clear field before new dictation
    _inputController.clear();
    setState(() => _isListening = true);

    await _speech.listen(
      onResult: (result) {
        _inputController.text = result.recognizedWords;
        // Auto-send on final result if model is ready
        if (result.finalResult && result.recognizedWords.isNotEmpty) {
          setState(() => _isListening = false);
          _send();
        }
      },
      localeId: 'ru_RU',
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _speech.cancel();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    context.read<ChatProvider>().sendMessage(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final scheme = Theme.of(context).colorScheme;

    if (chat.messages.isNotEmpty) _scrollToBottom();

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI Assistant',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              chat.statusText,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ],
        ),
        actions: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: chat.isModelReady ? Colors.greenAccent : scheme.outline,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Message list ─────────────────────────────────────────────────────
          Expanded(
            child: chat.messages.isEmpty
                ? _buildEmptyState(scheme)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: chat.messages.length,
                    itemBuilder: (_, i) => _MessageBubble(chat.messages[i]),
                  ),
          ),

          // Error banner
          if (chat.errorText != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chat.errorText!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Listening banner
          if (_isListening)
            _ListeningBanner(onStop: _toggleListening),

          // ── Input bar ────────────────────────────────────────────────────────
          _InputBar(
            controller: _inputController,
            isLoading: chat.isLoading,
            isModelReady: chat.isModelReady,
            isListening: _isListening,
            speechAvailable: _speechAvailable,
            onSend: _send,
            onMic: _toggleListening,
            onStop: () => context.read<ChatProvider>().stopGeneration(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme scheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.psychology_outlined, size: 64, color: scheme.outline),
          const SizedBox(height: 16),
          Text('Чем могу помочь?',
              style: TextStyle(fontSize: 18, color: scheme.outline)),
          const SizedBox(height: 8),
          Text('Запрос выполняется на устройстве',
              style: TextStyle(fontSize: 13, color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}

// ── Listening banner ───────────────────────────────────────────────────────────

class _ListeningBanner extends StatefulWidget {
  final VoidCallback onStop;
  const _ListeningBanner({required this.onStop});

  @override
  State<_ListeningBanner> createState() => _ListeningBannerState();
}

class _ListeningBannerState extends State<_ListeningBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.08 + _pulse.value * 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.mic, color: Colors.red, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Слушаю… говорите',
                style: TextStyle(color: scheme.onSurface, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: widget.onStop,
              child: const Text('Отмена'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Message bubble ─────────────────────────────────────────────────────────────

class _MessageBubble extends StatefulWidget {
  final AppMessage message;
  const _MessageBubble(this.message);

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  Timer? _timer;
  // Set when generation finishes; shown for a few seconds then cleared.
  String? _finalElapsed;

  bool get _isSending =>
      widget.message.status == MessageStatus.sending &&
      !widget.message.isUser;

  @override
  void initState() {
    super.initState();
    if (_isSending) _startTimer();
  }

  @override
  void didUpdateWidget(_MessageBubble old) {
    super.didUpdateWidget(old);
    final wasSending =
        old.message.status == MessageStatus.sending && !old.message.isUser;
    final nowDone = widget.message.status == MessageStatus.done;

    if (wasSending && nowDone) {
      final ms = DateTime.now()
          .difference(widget.message.timestamp)
          .inMilliseconds;
      _finalElapsed = _fmtMs(ms);
      _stopTimer();
      // Keep final time visible for 12 seconds then fade away.
      Future.delayed(const Duration(seconds: 12), () {
        if (mounted) setState(() => _finalElapsed = null);
      });
    }

    if (_isSending && _timer == null) _startTimer();
    if (!_isSending && _timer != null) _stopTimer();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }

  String _fmtMs(int ms) =>
      ms < 1000 ? '${ms} мс' : '${(ms / 1000).toStringAsFixed(1)} с';

  String? get _elapsedLabel {
    if (_isSending) {
      final ms = DateTime.now()
          .difference(widget.message.timestamp)
          .inMilliseconds;
      return '⏱ ${_fmtMs(ms)}';
    }
    if (_finalElapsed != null) return '⏱ $_finalElapsed';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = widget.message;
    final isUser = message.isUser;
    final elapsed = _elapsedLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.psychology,
                  size: 16, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: GestureDetector(
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: message.content));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Скопировано'),
                      duration: Duration(seconds: 1)),
                );
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isUser
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isUser ? 18 : 4),
                    bottomRight: Radius.circular(isUser ? 4 : 18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Main content
                    if (message.status == MessageStatus.sending &&
                        message.content.isEmpty)
                      _TypingIndicator(color: scheme.onSurface)
                    else if (isUser)
                      Text(
                        message.content,
                        style: TextStyle(color: scheme.onPrimaryContainer),
                      )
                    else
                      MarkdownBody(
                        data: message.content.isEmpty ? '…' : message.content,
                        styleSheet:
                            MarkdownStyleSheet.fromTheme(Theme.of(context)),
                      ),
                    // Elapsed time footer (assistant only)
                    if (!isUser && elapsed != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        elapsed,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }
}

// ── Typing indicator ──────────────────────────────────────────────────────────

class _TypingIndicator extends StatefulWidget {
  final Color color;
  const _TypingIndicator({required this.color});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i / 3;
            final opacity =
                ((_ctrl.value - delay).abs() < 0.3) ? 1.0 : 0.3;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isModelReady;
  final bool isListening;
  final bool speechAvailable;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onStop;

  const _InputBar({
    required this.controller,
    required this.isLoading,
    required this.isModelReady,
    required this.isListening,
    required this.speechAvailable,
    required this.onSend,
    required this.onMic,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: [
            // ── Mic button ──────────────────────────────────────────────────
            if (speechAvailable)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: isListening
                        ? Colors.red.withOpacity(0.15)
                        : scheme.surfaceContainerHighest,
                    foregroundColor:
                        isListening ? Colors.red : scheme.onSurface,
                  ),
                  icon: Icon(
                      isListening ? Icons.mic : Icons.mic_none_outlined),
                  onPressed: isModelReady && !isLoading ? onMic : null,
                ),
              ),

            // ── Text field ─────────────────────────────────────────────────
            Expanded(
              child: TextField(
                controller: controller,
                enabled: isModelReady && !isLoading && !isListening,
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: isListening
                      ? 'Слушаю…'
                      : isModelReady
                          ? 'Спроси что-нибудь…'
                          : 'Загрузка модели…',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // ── Send / Stop button ─────────────────────────────────────────
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: isLoading
                  ? IconButton.filled(
                      key: const ValueKey('stop'),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.stop_rounded),
                      onPressed: onStop,
                    )
                  : IconButton.filled(
                      key: const ValueKey('send'),
                      onPressed: isModelReady && !isListening ? onSend : null,
                      icon: const Icon(Icons.send_rounded),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
