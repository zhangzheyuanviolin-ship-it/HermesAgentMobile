import 'package:flutter/material.dart';
import '../services/native_bridge.dart';

class ProviderPreset {
  final String provider;
  final String label;
  final String endpoint;
  final String apiMode;
  final String keyEnv;

  const ProviderPreset({
    required this.provider,
    required this.label,
    required this.endpoint,
    required this.apiMode,
    required this.keyEnv,
  });
}

class ModelSettingsScreen extends StatefulWidget {
  const ModelSettingsScreen({super.key});

  @override
  State<ModelSettingsScreen> createState() => _ModelSettingsScreenState();
}

class _ModelSettingsScreenState extends State<ModelSettingsScreen> {
  static const List<ProviderPreset> _presets = [
    ProviderPreset(
      provider: 'openrouter',
      label: 'OpenRouter',
      endpoint: 'https://openrouter.ai/api/v1',
      apiMode: 'chat_completions',
      keyEnv: 'OPENROUTER_API_KEY',
    ),
    ProviderPreset(
      provider: 'anthropic',
      label: 'Anthropic',
      endpoint: 'https://api.anthropic.com',
      apiMode: 'anthropic_messages',
      keyEnv: 'ANTHROPIC_API_KEY',
    ),
    ProviderPreset(
      provider: 'gemini',
      label: 'Google Gemini',
      endpoint: 'https://generativelanguage.googleapis.com/v1beta',
      apiMode: 'chat_completions',
      keyEnv: 'GOOGLE_API_KEY',
    ),
    ProviderPreset(
      provider: 'deepseek',
      label: 'DeepSeek',
      endpoint: 'https://api.deepseek.com/v1',
      apiMode: 'chat_completions',
      keyEnv: 'DEEPSEEK_API_KEY',
    ),
    ProviderPreset(
      provider: 'zai',
      label: 'Z.AI / GLM',
      endpoint: 'https://api.z.ai/api/paas/v4',
      apiMode: 'chat_completions',
      keyEnv: 'GLM_API_KEY',
    ),
    ProviderPreset(
      provider: 'kimi-coding',
      label: 'Kimi / Moonshot',
      endpoint: 'https://api.moonshot.ai/v1',
      apiMode: 'chat_completions',
      keyEnv: 'KIMI_API_KEY',
    ),
    ProviderPreset(
      provider: 'minimax',
      label: 'MiniMax',
      endpoint: 'https://api.minimax.io/anthropic',
      apiMode: 'anthropic_messages',
      keyEnv: 'MINIMAX_API_KEY',
    ),
    ProviderPreset(
      provider: 'alibaba',
      label: 'Alibaba / DashScope',
      endpoint: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
      apiMode: 'chat_completions',
      keyEnv: 'DASHSCOPE_API_KEY',
    ),
    ProviderPreset(
      provider: 'huggingface',
      label: 'Hugging Face',
      endpoint: 'https://router.huggingface.co/v1',
      apiMode: 'chat_completions',
      keyEnv: 'HF_TOKEN',
    ),
    ProviderPreset(
      provider: 'openai-codex',
      label: 'OpenAI Codex',
      endpoint: 'https://chatgpt.com/backend-api/codex',
      apiMode: 'codex_responses',
      keyEnv: 'OPENAI_API_KEY',
    ),
    ProviderPreset(
      provider: 'custom',
      label: 'Custom Endpoint',
      endpoint: 'https://api.openai.com/v1',
      apiMode: 'chat_completions',
      keyEnv: 'OPENAI_API_KEY',
    ),
  ];

  final _modelController = TextEditingController();
  final _endpointController = TextEditingController();
  final _keyController = TextEditingController();

  String _provider = _presets.first.provider;
  String _apiMode = 'chat_completions';
  String _envKeyName = 'OPENROUTER_API_KEY';
  bool _saving = false;
  bool _loading = true;
  bool _hideKey = true;

  @override
  void initState() {
    super.initState();
    _loadCurrentValues();
  }

  @override
  void dispose() {
    _modelController.dispose();
    _endpointController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentValues() async {
    try {
      final configText =
          await NativeBridge.readRootfsFile('root/.hermes/config.yaml') ?? '';
      final envText = await NativeBridge.readRootfsFile('root/.hermes/.env') ?? '';

      final provider = _extractModelField(configText, 'provider');
      final model = _extractModelField(configText, 'default') ??
          _extractModelField(configText, 'model');
      final baseUrl = _extractModelField(configText, 'base_url');
      final apiMode = _extractModelField(configText, 'api_mode');

      final preset = _findPreset(provider) ?? _presets.first;

      _provider = preset.provider;
      _apiMode = apiMode?.trim().isNotEmpty == true ? apiMode!.trim() : preset.apiMode;
      _envKeyName = preset.keyEnv;
      _modelController.text = model?.trim() ?? '';
      _endpointController.text = baseUrl?.trim().isNotEmpty == true
          ? baseUrl!.trim()
          : preset.endpoint;

      final envMap = _parseEnv(envText);
      _keyController.text = envMap[preset.keyEnv] ?? '';
    } catch (_) {
      // Ignore load failures and keep defaults.
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  ProviderPreset? _findPreset(String? provider) {
    if (provider == null || provider.trim().isEmpty) return null;
    for (final p in _presets) {
      if (p.provider == provider.trim()) return p;
    }
    return null;
  }

  String? _extractModelField(String yaml, String key) {
    final lines = yaml.split('\n');
    var inModel = false;
    int modelIndent = 0;

    for (final raw in lines) {
      final line = raw.replaceAll('\t', '  ');
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }

      final indent = line.length - line.trimLeft().length;

      if (!inModel) {
        if (trimmed == 'model:') {
          inModel = true;
          modelIndent = indent;
        }
        continue;
      }

      if (indent <= modelIndent) {
        break;
      }

      if (trimmed.startsWith('$key:')) {
        final value = trimmed.substring('$key:'.length).trim();
        return value.replaceAll('"', '').replaceAll("'", '');
      }
    }

    return null;
  }

  Map<String, String> _parseEnv(String envText) {
    final map = <String, String>{};
    for (final raw in envText.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
      final idx = line.indexOf('=');
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      if (key.isNotEmpty) {
        map[key] = value;
      }
    }
    return map;
  }

  String _upsertEnv(String envText, String key, String value) {
    final lines = envText.isEmpty ? <String>[] : envText.split('\n');
    var replaced = false;

    for (int i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (raw.trimLeft().startsWith('$key=')) {
        lines[i] = '$key=$value';
        replaced = true;
        break;
      }
    }

    if (!replaced) {
      lines.add('$key=$value');
    }

    return lines.join('\n').trimRight() + '\n';
  }

  String _escapeSingleQuotes(String input) {
    return input.replaceAll("'", "'\"'\"'");
  }

  Future<void> _save() async {
    final model = _modelController.text.trim();
    final endpoint = _endpointController.text.trim();
    final apiKey = _keyController.text.trim();

    if (model.isEmpty || endpoint.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模型 ID 和端点 URL 不能为空')),
      );
      return;
    }

    setState(() => _saving = true);

    try {
      final escapedProvider = _escapeSingleQuotes(_provider);
      final escapedModel = _escapeSingleQuotes(model);
      final escapedEndpoint = _escapeSingleQuotes(endpoint);
      final escapedMode = _escapeSingleQuotes(_apiMode);

      final command =
          'cd /root/hermes-agent && '
          'source venv/bin/activate && '
          'python -m hermes_cli.main config set '
          "'model.provider' '$escapedProvider' && "
          'python -m hermes_cli.main config set '
          "'model.default' '$escapedModel' && "
          'python -m hermes_cli.main config set '
          "'model.base_url' '$escapedEndpoint' && "
          'python -m hermes_cli.main config set '
          "'model.api_mode' '$escapedMode'";

      await NativeBridge.runInProot(command, timeout: 900);

      if (apiKey.isNotEmpty) {
        final escapedApiKey = _escapeSingleQuotes(apiKey);
        final keyCmd =
            'cd /root/hermes-agent && '
            'source venv/bin/activate && '
            'python -m hermes_cli.main config set '
            "'model.api_key' '$escapedApiKey'";
        await NativeBridge.runInProot(keyCmd, timeout: 300);

        final currentEnv =
            await NativeBridge.readRootfsFile('root/.hermes/.env') ?? '';
        var updatedEnv = _upsertEnv(currentEnv, _envKeyName, apiKey);
        if (_provider == 'custom' || _provider == 'openai-codex') {
          updatedEnv = _upsertEnv(updatedEnv, 'OPENAI_API_KEY', apiKey);
        }
        await NativeBridge.writeRootfsFile('root/.hermes/.env', updatedEnv);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存成功，请重启 Gateway 使配置生效')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型与 API 设置'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DropdownButtonFormField<String>(
                  value: _provider,
                  decoration: const InputDecoration(
                    labelText: '模型提供商预设',
                  ),
                  items: _presets
                      .map(
                        (preset) => DropdownMenuItem(
                          value: preset.provider,
                          child: Text(preset.label),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value == null) return;
                          final preset = _presets.firstWhere(
                            (p) => p.provider == value,
                          );
                          setState(() {
                            _provider = preset.provider;
                            _apiMode = preset.apiMode;
                            _envKeyName = preset.keyEnv;
                            _endpointController.text = preset.endpoint;
                          });
                        },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _modelController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '模型 ID',
                    hintText: '例如: glm-5 / deepseek-chat / claude-sonnet-4-6',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _endpointController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '端点 URL',
                    hintText: '例如: https://openrouter.ai/api/v1',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keyController,
                  enabled: !_saving,
                  obscureText: _hideKey,
                  decoration: InputDecoration(
                    labelText: 'API 密钥',
                    hintText: '将写入 $_envKeyName',
                    suffixIcon: IconButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() => _hideKey = !_hideKey),
                      icon: Icon(
                        _hideKey ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _apiMode,
                  decoration: const InputDecoration(
                    labelText: 'API 协议',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'chat_completions',
                      child: Text('chat_completions'),
                    ),
                    DropdownMenuItem(
                      value: 'codex_responses',
                      child: Text('codex_responses'),
                    ),
                    DropdownMenuItem(
                      value: 'anthropic_messages',
                      child: Text('anthropic_messages'),
                    ),
                    DropdownMenuItem(
                      value: 'bedrock_converse',
                      child: Text('bedrock_converse'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _apiMode = value);
                        },
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_saving ? '保存中...' : '保存设置'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '保存后请回到首页停止并重新启动 Gateway，再进入聊天页面测试收发。',
                ),
              ],
            ),
    );
  }
}
