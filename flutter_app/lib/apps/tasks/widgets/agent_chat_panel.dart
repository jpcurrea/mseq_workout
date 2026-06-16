// Reusable collapsible agent chat panel with voice STT/TTS support.
//
// Usage:
//   AgentChatPanel(
//     title: 'AI Assistant',
//     entries: _entries,
//     isLoading: _sending,
//     isExpanded: _expanded,
//     onToggleExpand: () => setState(() => _expanded = !_expanded),
//     onSend: _handleSend,
//     onClear: _handleClear,
//     scrollController: _scrollCtrl,
//   )
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

class AgentChatEntry {
  final String role; // 'user' | 'assistant' | 'error'
  final String content;

  const AgentChatEntry({required this.role, required this.content});
}

class AgentChatPanel extends StatefulWidget {
  final String title;
  final List<AgentChatEntry> entries;
  final bool isLoading;
  final bool isExpanded;
  final VoidCallback onToggleExpand;
  final Future<void> Function(String message) onSend;
  final VoidCallback? onClear;
  final VoidCallback? onOpenAiSettings;
  final ScrollController scrollController;
  final TextEditingController? textController;
  /// Whether server-side memory / summary exists for this thread.
  final bool hasMemory;
  /// Badge shown in header when approval mode is active.
  final bool requiresApproval;
  /// Placeholder shown when the message list is empty.
  final String emptyStateHint;

  const AgentChatPanel({
    super.key,
    required this.title,
    required this.entries,
    required this.isLoading,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.onSend,
    required this.scrollController,
    this.onClear,
    this.onOpenAiSettings,
    this.textController,
    this.hasMemory = false,
    this.requiresApproval = false,
    this.emptyStateHint = 'Ask me anything about your tasks.',
  });

  @override
  State<AgentChatPanel> createState() => _AgentChatPanelState();
}

class _AgentChatPanelState extends State<AgentChatPanel> {
  late final TextEditingController _ctrl;
  bool _ownCtrl = false;

  // ── TTS ─────────────────────────────────────────────────────────────────────
  final FlutterTts _tts = FlutterTts();
  bool _ttsEnabled = true;
  bool _ttsPlaying = false;

  // ── STT ─────────────────────────────────────────────────────────────────────
  final SpeechToText _stt = SpeechToText();
  bool _sttAvailable = false;
  bool _sttListening = false;

  @override
  void initState() {
    super.initState();
    _ctrl = widget.textController ?? TextEditingController();
    _ownCtrl = widget.textController == null;
    _initVoice();
  }

  Future<void> _initVoice() async {
    _sttAvailable = await _stt.initialize(
      onError: (_) => setState(() => _sttListening = false),
      onStatus: (s) {
        if (!mounted) return;
        setState(() => _sttListening = s == 'listening');
      },
    );
    await _tts.setSharedInstance(true);
    await _tts.awaitSpeakCompletion(true);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _ttsPlaying = false);
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_ownCtrl) _ctrl.dispose();
    _stt.cancel();
    _tts.stop();
    super.dispose();
  }

  // ── Voice helpers ────────────────────────────────────────────────────────────
  Future<void> _startListening() async {
    if (!_sttAvailable) return;
    await _stt.listen(
      onResult: (r) {
        if (!mounted) return;
        _ctrl.text = r.recognizedWords;
        _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
      },
      listenOptions: SpeechListenOptions(partialResults: true),
    );
    setState(() => _sttListening = true);
  }

  Future<void> _stopListening() async {
    await _stt.stop();
    setState(() => _sttListening = false);
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled || text.isEmpty) return;
    // Strip markdown for cleaner speech
    final plain = text
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'#+\s'), '')
        .replaceAll(RegExp(r'`+'), '')
        .trim();
    setState(() => _ttsPlaying = true);
    await _tts.speak(plain);
  }

  Future<void> _stopSpeaking() async {
    await _tts.stop();
    setState(() => _ttsPlaying = false);
  }

  // ── Send ─────────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || widget.isLoading) return;
    _ctrl.clear();
    if (_sttListening) await _stopListening();
    await widget.onSend(text);
    // Speak the last assistant reply (added by parent after await)
    final last = widget.entries.lastOrNull;
    if (last != null && last.role == 'assistant') {
      await _speak(last.content);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(theme),
        if (widget.isExpanded) _buildBody(theme),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return InkWell(
      onTap: widget.onToggleExpand,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.requiresApproval) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('Approval On', style: TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 6),
            ],
            if (widget.hasMemory) ...[
              Tooltip(
                message: 'Earlier turns are summarized into memory',
                child: Icon(Icons.psychology_outlined, size: 16, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 4),
            ],
            if (widget.isLoading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
              ),
            if (!widget.isLoading && widget.onClear != null)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                tooltip: 'Clear conversation',
                onPressed: widget.onClear,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            if (widget.onOpenAiSettings != null)
              IconButton(
                icon: Icon(Icons.tune, size: 16, color: theme.colorScheme.onSurfaceVariant),
                tooltip: 'AI provider settings',
                onPressed: widget.onOpenAiSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            IconButton(
              icon: Icon(
                _ttsEnabled ? Icons.volume_up : Icons.volume_off,
                size: 16,
                color: _ttsEnabled ? theme.colorScheme.primary : theme.colorScheme.outline,
              ),
              tooltip: _ttsEnabled ? 'Mute voice' : 'Enable voice',
              onPressed: () async {
                if (_ttsPlaying) await _stopSpeaking();
                setState(() => _ttsEnabled = !_ttsEnabled);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
            Icon(
              widget.isExpanded ? Icons.expand_more : Icons.expand_less,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return Container(
      height: 320,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        children: [
          Expanded(child: _buildMessageList(theme)),
          _buildInputRow(theme),
        ],
      ),
    );
  }

  Widget _buildMessageList(ThemeData theme) {
    if (widget.entries.isEmpty) {
      return Center(
        child: Text(
          widget.emptyStateHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: widget.entries.length,
      itemBuilder: (_, i) => _buildBubble(theme, widget.entries[i]),
    );
  }

  Future<void> _copyMessage(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied'), duration: Duration(seconds: 1)),
    );
  }

  Widget _buildBubble(ThemeData theme, AgentChatEntry entry) {
    final isUser = entry.role == 'user';
    final isError = entry.role == 'error';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _copyMessage(context, entry.content),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isError
                ? theme.colorScheme.errorContainer
                : isUser
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            entry.content,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isError
                  ? theme.colorScheme.onErrorContainer
                  : isUser
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
            ),
            contextMenuBuilder: (context, editableState) =>
                AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: editableState),
          ),
        ),
      ),
    );
  }

  Widget _buildInputRow(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        color: theme.colorScheme.surface,
      ),
      child: Row(
        children: [
          if (_sttAvailable) ...[
            GestureDetector(
              onLongPressStart: (_) => _startListening(),
              onLongPressEnd: (_) => _stopListening(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _sttListening
                      ? theme.colorScheme.error
                      : theme.colorScheme.primaryContainer,
                ),
                child: Icon(
                  _sttListening ? Icons.mic : Icons.mic_none,
                  size: 18,
                  color: _sttListening
                      ? theme.colorScheme.onError
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  if (!widget.isLoading) _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _ctrl,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: _sttListening ? 'Listening…' : 'Message…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (_ttsPlaying)
            IconButton(
              icon: Icon(Icons.stop_circle, color: theme.colorScheme.error),
              onPressed: _stopSpeaking,
              tooltip: 'Stop speaking',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            )
          else
            IconButton(
              icon: Icon(
                Icons.send_rounded,
                color: widget.isLoading ? theme.colorScheme.outline : theme.colorScheme.primary,
              ),
              onPressed: widget.isLoading ? null : _send,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
        ],
      ),
    );
  }
}
