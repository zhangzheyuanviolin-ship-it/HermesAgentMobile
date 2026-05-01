import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../constants.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  bool _pageReady = false;
  String? _lastError;

  String get _chatUrl => '${AppConstants.apiServerUrl}/openclaw-chat';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loadingProgress = 0;
              _pageReady = false;
              _lastError = null;
            });
          },
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _loadingProgress = progress;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _loadingProgress = 100;
              _pageReady = true;
            });
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _lastError = error.description.isEmpty ? '页面加载失败' : error.description;
            });
          },
        ),
      );
    _loadChat();
  }

  Future<void> _loadChat() async {
    await _controller.loadRequest(Uri.parse(_chatUrl));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showProgress = _loadingProgress > 0 && _loadingProgress < 100;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes Chat'),
        actions: [
          IconButton(
            tooltip: '刷新聊天页',
            icon: const Icon(Icons.refresh),
            onPressed: _loadChat,
          ),
        ],
        bottom: showProgress
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _loadingProgress / 100),
              )
            : null,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: WebViewWidget(controller: _controller),
          ),
          if (!_pageReady && _lastError == null)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.transparent,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          if (_lastError != null)
            Positioned.fill(
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_off, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          '聊天页加载失败',
                          style: theme.textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _lastError!,
                          style: theme.textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _loadChat,
                          child: const Text('重新加载'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
