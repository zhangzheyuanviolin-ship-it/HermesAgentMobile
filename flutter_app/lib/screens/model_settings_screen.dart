import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../models/model_profile_models.dart';
import '../services/model_profile_store.dart';
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

enum _ModelMenuAction {
  edit,
  fetchModels,
  testConnection,
  delete,
}

class _ProbeResult {
  final bool ok;
  final String message;
  final String probedUrl;
  final List<String> models;

  const _ProbeResult({
    required this.ok,
    required this.message,
    required this.probedUrl,
    this.models = const [],
  });
}

class _ModelEditorResult {
  final ModelProfile profile;
  final bool activateAfterSave;

  const _ModelEditorResult({
    required this.profile,
    required this.activateAfterSave,
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

  final _store = ModelProfileStore();
  final _uuid = const Uuid();

  List<ModelProfile> _profiles = [];
  String? _selectedProfileId;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  ProviderPreset _presetOf(String provider) {
    for (final p in _presets) {
      if (p.provider == provider) return p;
    }
    return _presets.last;
  }

  ModelProfile? get _selectedProfile {
    for (final p in _profiles) {
      if (p.id == _selectedProfileId) return p;
    }
    return null;
  }

  Future<void> _loadProfiles() async {
    final data = await _store.loadStore();
    var profiles = List<ModelProfile>.from(data.profiles);
    var selectedId = data.selectedProfileId;

    if (profiles.isEmpty) {
      final migrated = await _migrateFromCurrentConfig();
      if (migrated != null) {
        profiles = [migrated];
        selectedId = migrated.id;
        await _store.saveStore(
          profiles: profiles,
          selectedProfileId: selectedId,
        );
      }
    }

    if (profiles.isNotEmpty) {
      final selectedExists = selectedId != null && profiles.any((p) => p.id == selectedId);
      if (!selectedExists) {
        selectedId = profiles.first.id;
      }
    }

    profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _selectedProfileId = selectedId;
      _loading = false;
    });
  }

  Future<ModelProfile?> _migrateFromCurrentConfig() async {
    try {
      final configText = await NativeBridge.readRootfsFile('root/.hermes/config.yaml') ?? '';
      final envText = await NativeBridge.readRootfsFile('root/.hermes/.env') ?? '';

      final provider = _extractModelField(configText, 'provider')?.trim();
      final model = (_extractModelField(configText, 'default') ?? _extractModelField(configText, 'model'))
          ?.trim();
      final endpoint = _extractModelField(configText, 'base_url')?.trim();
      final apiMode = _extractModelField(configText, 'api_mode')?.trim();

      if ((provider ?? '').isEmpty && (model ?? '').isEmpty && (endpoint ?? '').isEmpty) {
        return null;
      }

      final preset = _presetOf((provider?.isNotEmpty == true) ? provider! : _presets.first.provider);
      final envMap = _parseEnv(envText);
      final key = envMap[preset.keyEnv] ?? '';
      final now = DateTime.now().toUtc();
      return ModelProfile(
        id: _uuid.v4(),
        name: (model?.isNotEmpty == true) ? model! : '${preset.label} 默认模型',
        provider: (provider?.isNotEmpty == true) ? provider! : preset.provider,
        modelId: model ?? '',
        endpoint: (endpoint?.isNotEmpty == true) ? endpoint! : preset.endpoint,
        apiKey: key,
        apiMode: (apiMode?.isNotEmpty == true) ? apiMode! : preset.apiMode,
        keyEnv: preset.keyEnv,
        createdAt: now,
        updatedAt: now,
      );
    } catch (_) {
      return null;
    }
  }

  String? _extractModelField(String yaml, String key) {
    final lines = yaml.split('\n');
    var inModel = false;
    var modelIndent = 0;

    for (final raw in lines) {
      final line = raw.replaceAll('\t', '  ');
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final indent = line.length - line.trimLeft().length;
      if (!inModel) {
        if (trimmed == 'model:') {
          inModel = true;
          modelIndent = indent;
        }
        continue;
      }

      if (indent <= modelIndent) break;
      if (!trimmed.startsWith('$key:')) continue;
      final value = trimmed.substring('$key:'.length).trim();
      return value.replaceAll('"', '').replaceAll("'", '');
    }
    return null;
  }

  Map<String, String> _parseEnv(String envText) {
    final map = <String, String>{};
    for (final raw in envText.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final idx = line.indexOf('=');
      if (idx <= 0) continue;
      map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
    return map;
  }

  Future<void> _saveStore() async {
    await _store.saveStore(
      profiles: _profiles,
      selectedProfileId: _selectedProfileId,
    );
  }

  String _escapeSingleQuotes(String input) {
    return input.replaceAll("'", "'\"'\"'");
  }

  String _upsertEnv(String envText, String key, String value) {
    final lines = envText.isEmpty ? <String>[] : envText.split('\n');
    var replaced = false;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trimLeft();
      if (!line.startsWith('$key=')) continue;
      lines[i] = '$key=$value';
      replaced = true;
      break;
    }
    if (!replaced) {
      lines.add('$key=$value');
    }
    return lines.join('\n').trimRight() + '\n';
  }

  Future<void> _applyProfileToHermes(ModelProfile profile) async {
    final escapedProvider = _escapeSingleQuotes(profile.provider);
    final escapedModel = _escapeSingleQuotes(profile.modelId);
    final escapedEndpoint = _escapeSingleQuotes(profile.endpoint);
    final escapedMode = _escapeSingleQuotes(profile.apiMode);

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

    if (profile.apiKey.trim().isNotEmpty) {
      final escapedApiKey = _escapeSingleQuotes(profile.apiKey.trim());
      final keyCmd =
          'cd /root/hermes-agent && '
          'source venv/bin/activate && '
          'python -m hermes_cli.main config set '
          "'model.api_key' '$escapedApiKey'";
      await NativeBridge.runInProot(keyCmd, timeout: 300);

      final currentEnv = await NativeBridge.readRootfsFile('root/.hermes/.env') ?? '';
      var updated = _upsertEnv(currentEnv, profile.keyEnv, profile.apiKey.trim());
      if (profile.provider == 'custom' || profile.provider == 'openai-codex') {
        updated = _upsertEnv(updated, 'OPENAI_API_KEY', profile.apiKey.trim());
      }
      await NativeBridge.writeRootfsFile('root/.hermes/.env', updated);
    }
  }

  Future<void> _setBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _createProfile() async {
    final result = await Navigator.of(context).push<_ModelEditorResult>(
      MaterialPageRoute(
        builder: (_) => _ModelEditorPage(
          presets: _presets,
        ),
      ),
    );
    if (result == null || !mounted) return;

    await _setBusy(() async {
      final profile = result.profile;
      final list = List<ModelProfile>.from(_profiles)..insert(0, profile);
      var selectedId = _selectedProfileId;

      if (result.activateAfterSave || selectedId == null) {
        try {
          await _applyProfileToHermes(profile);
          selectedId = profile.id;
          _showSnack('已切换到新模型：${profile.name}');
        } catch (e) {
          _showSnack('新模型已创建，但切换失败: $e');
        }
      } else {
        _showSnack('模型已创建');
      }

      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _profiles = list;
      _selectedProfileId = selectedId;
      await _saveStore();
      if (mounted) setState(() {});
    });
  }

  Future<void> _editProfile(ModelProfile profile) async {
    final result = await Navigator.of(context).push<_ModelEditorResult>(
      MaterialPageRoute(
        builder: (_) => _ModelEditorPage(
          presets: _presets,
          initialProfile: profile,
          isCurrent: profile.id == _selectedProfileId,
        ),
      ),
    );
    if (result == null || !mounted) return;

    await _setBusy(() async {
      final edited = result.profile;
      final list = List<ModelProfile>.from(_profiles);
      final idx = list.indexWhere((p) => p.id == edited.id);
      if (idx >= 0) {
        list[idx] = edited;
      } else {
        list.insert(0, edited);
      }

      var selectedId = _selectedProfileId;
      final shouldActivate = result.activateAfterSave || selectedId == edited.id;
      if (shouldActivate) {
        try {
          await _applyProfileToHermes(edited);
          selectedId = edited.id;
          _showSnack('模型已保存并生效');
        } catch (e) {
          _showSnack('模型已保存，但应用失败: $e');
        }
      } else {
        _showSnack('模型已保存');
      }

      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _profiles = list;
      _selectedProfileId = selectedId;
      await _saveStore();
      if (mounted) setState(() {});
    });
  }

  Future<void> _deleteProfile(ModelProfile profile) async {
    if (_profiles.length <= 1) {
      _showSnack('至少保留一个模型，无法删除最后一个');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除“${profile.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await _setBusy(() async {
      final list = _profiles.where((p) => p.id != profile.id).toList();
      var selectedId = _selectedProfileId;
      if (selectedId == profile.id) {
        final fallback = list.first;
        try {
          await _applyProfileToHermes(fallback);
          selectedId = fallback.id;
          _showSnack('已删除并切换到：${fallback.name}');
        } catch (e) {
          _showSnack('删除失败，切换到备用模型时出错: $e');
          return;
        }
      } else {
        _showSnack('模型已删除');
      }

      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _profiles = list;
      _selectedProfileId = selectedId;
      await _saveStore();
      if (mounted) setState(() {});
    });
  }

  Future<void> _selectProfile(ModelProfile profile) async {
    if (profile.id == _selectedProfileId) {
      _showSnack('该模型已是当前使用模型');
      return;
    }
    await _setBusy(() async {
      try {
        await _applyProfileToHermes(profile);
      } catch (e) {
        _showSnack('切换失败: $e');
        return;
      }

      _selectedProfileId = profile.id;
      final idx = _profiles.indexWhere((p) => p.id == profile.id);
      if (idx >= 0) {
        _profiles[idx] = _profiles[idx].copyWith(updatedAt: DateTime.now().toUtc());
      }
      _profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _saveStore();
      if (mounted) setState(() {});
      _showSnack('已切换为当前模型：${profile.name}');
    });
  }

  Future<void> _testConnection(ModelProfile profile) async {
    await _setBusy(() async {
      final result = await _probeModels(profile.endpoint, profile.apiKey);
      final idx = _profiles.indexWhere((p) => p.id == profile.id);
      if (idx >= 0) {
        _profiles[idx] = _profiles[idx].copyWith(
          lastTestAt: DateTime.now().toUtc(),
          lastTestSuccess: result.ok,
          lastTestMessage: result.message,
          updatedAt: DateTime.now().toUtc(),
        );
        _profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        await _saveStore();
        if (mounted) setState(() {});
      }

      final message = result.ok
          ? '连接测试成功：${result.models.length} 个模型可见'
          : '连接测试失败：${result.message}';
      _showSnack(message);
    });
  }

  Future<void> _fetchModelsFromProvider(ModelProfile profile) async {
    await _setBusy(() async {
      final result = await _probeModels(profile.endpoint, profile.apiKey);
      if (!result.ok) {
        _showSnack('拉取模型列表失败：${result.message}');
        return;
      }
      if (result.models.isEmpty) {
        _showSnack('连接成功，但该端点未返回可选模型列表');
        return;
      }

      final picked = await _pickModelId(result.models, profile.modelId);
      if (picked == null || picked.trim().isEmpty || !mounted) return;

      final idx = _profiles.indexWhere((p) => p.id == profile.id);
      if (idx < 0) return;
      final updated = _profiles[idx].copyWith(
        modelId: picked.trim(),
        name: (_profiles[idx].name.trim().isEmpty || _profiles[idx].name == _profiles[idx].modelId)
            ? picked.trim()
            : _profiles[idx].name,
        updatedAt: DateTime.now().toUtc(),
      );

      _profiles[idx] = updated;
      var applyFailed = false;
      if (updated.id == _selectedProfileId) {
        try {
          await _applyProfileToHermes(updated);
        } catch (e) {
          applyFailed = true;
          _showSnack('模型ID已更新，但应用到当前配置失败: $e');
        }
      }

      _profiles.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _saveStore();
      if (mounted) setState(() {});
      if (!applyFailed) {
        _showSnack('模型ID已更新为：$picked');
      }
    });
  }

  Future<String?> _pickModelId(List<String> models, String current) async {
    final sorted = List<String>.from(models);
    sorted.sort((a, b) => a.compareTo(b));
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.72,
          child: Column(
            children: [
              const ListTile(
                title: Text('从提供商返回列表中选择模型'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: sorted.length,
                  itemBuilder: (context, index) {
                    final model = sorted[index];
                    final selected = model == current;
                    return ListTile(
                      leading: Icon(
                        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      ),
                      title: Text(model),
                      onTap: () => Navigator.of(ctx).pop(model),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<_ProbeResult> _probeModels(String endpoint, String apiKey) async {
    final normalized = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      return const _ProbeResult(
        ok: false,
        message: '端点为空',
        probedUrl: '',
      );
    }

    final candidates = <String>[normalized];
    if (normalized.endsWith('/v1')) {
      final alternate = normalized.substring(0, normalized.length - 3).replaceAll(RegExp(r'/+$'), '');
      if (alternate.isNotEmpty && !candidates.contains(alternate)) {
        candidates.add(alternate);
      }
    } else {
      final alternate = '$normalized/v1';
      if (!candidates.contains(alternate)) {
        candidates.add(alternate);
      }
    }

    final errors = <String>[];
    final client = http.Client();
    try {
      for (final base in candidates) {
        final url = '$base/models';
        final headers = <String, String>{
          'Accept': 'application/json',
        };
        if (apiKey.trim().isNotEmpty) {
          headers['Authorization'] = 'Bearer ${apiKey.trim()}';
        }

        try {
          final response = await client
              .get(Uri.parse(url), headers: headers)
              .timeout(const Duration(seconds: 12));
          if (response.statusCode >= 200 && response.statusCode < 300) {
            final models = _extractModelIds(response.body);
            return _ProbeResult(
              ok: true,
              message: '连接成功',
              probedUrl: url,
              models: models,
            );
          }
          errors.add('${response.statusCode} @ $url');
        } catch (e) {
          errors.add('$e @ $url');
        }
      }
    } finally {
      client.close();
    }

    return _ProbeResult(
      ok: false,
      message: errors.isEmpty ? '请求失败' : errors.first,
      probedUrl: candidates.map((c) => '$c/models').join(' ; '),
    );
  }

  List<String> _extractModelIds(String body) {
    final result = <String>[];
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) {
        final list = data['data'];
        if (list is List) {
          for (final item in list) {
            if (item is Map && item['id'] != null) {
              final id = item['id'].toString().trim();
              if (id.isNotEmpty && !result.contains(id)) result.add(id);
            } else if (item is String && item.trim().isNotEmpty && !result.contains(item.trim())) {
              result.add(item.trim());
            }
          }
        }

        final alt = data['models'];
        if (alt is List) {
          for (final item in alt) {
            if (item is String && item.trim().isNotEmpty && !result.contains(item.trim())) {
              result.add(item.trim());
            } else if (item is Map && item['id'] != null) {
              final id = item['id'].toString().trim();
              if (id.isNotEmpty && !result.contains(id)) result.add(id);
            }
          }
        }
      } else if (data is List) {
        for (final item in data) {
          if (item is String && item.trim().isNotEmpty && !result.contains(item.trim())) {
            result.add(item.trim());
          } else if (item is Map && item['id'] != null) {
            final id = item['id'].toString().trim();
            if (id.isNotEmpty && !result.contains(id)) result.add(id);
          }
        }
      }
    } catch (_) {
      // Ignore parse errors; empty list means endpoint reachable but unknown shape.
    }
    return result;
  }

  String _titleOf(ModelProfile profile) {
    if (profile.name.trim().isNotEmpty) return profile.name.trim();
    if (profile.modelId.trim().isNotEmpty) return profile.modelId.trim();
    return '未命名模型';
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _handleMenuAction(_ModelMenuAction action, ModelProfile profile) async {
    switch (action) {
      case _ModelMenuAction.edit:
        await _editProfile(profile);
        return;
      case _ModelMenuAction.fetchModels:
        await _fetchModelsFromProvider(profile);
        return;
      case _ModelMenuAction.testConnection:
        await _testConnection(profile);
        return;
      case _ModelMenuAction.delete:
        await _deleteProfile(profile);
        return;
    }
  }

  Widget _buildSelectedCard(ThemeData theme) {
    final selected = _selectedProfile;
    if (selected == null) {
      return const SizedBox.shrink();
    }

    final testStatus = selected.lastTestAt != null
        ? '${selected.lastTestSuccess == true ? '最近测试成功' : '最近测试失败'} · ${_formatTime(selected.lastTestAt)}'
        : '尚未测试连接';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前使用模型',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(_titleOf(selected), style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('模型ID：${selected.modelId}'),
            Text('端点：${selected.endpoint}'),
            Text('提供商：${selected.provider}    协议：${selected.apiMode}'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _testConnection(selected),
                  icon: const Icon(Icons.network_check_outlined),
                  label: const Text('测试连接'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _fetchModelsFromProvider(selected),
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('从提供商获取模型列表'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              testStatus,
              style: theme.textTheme.bodySmall,
            ),
            if ((selected.lastTestMessage ?? '').trim().isNotEmpty)
              Text(
                selected.lastTestMessage!.trim(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected.lastTestSuccess == true ? Colors.green.shade700 : theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型与 API 设置'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _createProfile,
                      icon: const Icon(Icons.add),
                      label: const Text('手动创建新模型'),
                    ),
                    const SizedBox(height: 12),
                    _buildSelectedCard(theme),
                    Text(
                      '已配置模型',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (_profiles.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('暂无模型，请先创建一个模型配置。'),
                        ),
                      ),
                    ..._profiles.map(
                      (profile) {
                        final selected = profile.id == _selectedProfileId;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                            ),
                            title: Text(_titleOf(profile)),
                            subtitle: Text(
                              '模型ID: ${profile.modelId}\n端点: ${profile.endpoint}',
                            ),
                            isThreeLine: true,
                            onTap: _busy ? null : () => _selectProfile(profile),
                            trailing: PopupMenuButton<_ModelMenuAction>(
                              onSelected: _busy ? null : (a) => _handleMenuAction(a, profile),
                              itemBuilder: (ctx) => const [
                                PopupMenuItem(
                                  value: _ModelMenuAction.edit,
                                  child: Text('编辑模型'),
                                ),
                                PopupMenuItem(
                                  value: _ModelMenuAction.fetchModels,
                                  child: Text('从提供商获取模型列表'),
                                ),
                                PopupMenuItem(
                                  value: _ModelMenuAction.testConnection,
                                  child: Text('测试连接'),
                                ),
                                PopupMenuItem(
                                  value: _ModelMenuAction.delete,
                                  child: Text('删除模型'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '提示：点击模型即可切换为当前使用模型。切换或编辑后建议重启 Gateway 以确保全量生效。',
                    ),
                  ],
                ),
                if (_busy)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
    );
  }
}

class _ModelEditorPage extends StatefulWidget {
  final List<ProviderPreset> presets;
  final ModelProfile? initialProfile;
  final bool isCurrent;

  const _ModelEditorPage({
    required this.presets,
    this.initialProfile,
    this.isCurrent = false,
  });

  @override
  State<_ModelEditorPage> createState() => _ModelEditorPageState();
}

class _ModelEditorPageState extends State<_ModelEditorPage> {
  final _nameController = TextEditingController();
  final _modelController = TextEditingController();
  final _endpointController = TextEditingController();
  final _keyController = TextEditingController();
  final _uuid = const Uuid();

  bool _hideKey = true;
  bool _saving = false;
  bool _activateAfterSave = true;

  late String _provider;
  late String _apiMode;
  late String _keyEnv;

  ProviderPreset _presetOf(String provider) {
    for (final p in widget.presets) {
      if (p.provider == provider) return p;
    }
    return widget.presets.last;
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialProfile;
    if (initial == null) {
      final preset = widget.presets.first;
      _provider = preset.provider;
      _apiMode = preset.apiMode;
      _keyEnv = preset.keyEnv;
      _endpointController.text = preset.endpoint;
      _activateAfterSave = true;
      return;
    }

    final preset = _presetOf(initial.provider);
    _provider = initial.provider;
    _apiMode = initial.apiMode;
    _keyEnv = initial.keyEnv.isNotEmpty ? initial.keyEnv : preset.keyEnv;
    _nameController.text = initial.name;
    _modelController.text = initial.modelId;
    _endpointController.text = initial.endpoint;
    _keyController.text = initial.apiKey;
    _activateAfterSave = widget.isCurrent;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _modelController.dispose();
    _endpointController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final modelId = _modelController.text.trim();
    final endpoint = _endpointController.text.trim();
    if (modelId.isEmpty || endpoint.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模型ID与端点URL不能为空')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final now = DateTime.now().toUtc();
      final initial = widget.initialProfile;
      final name = _nameController.text.trim().isEmpty ? modelId : _nameController.text.trim();
      final profile = ModelProfile(
        id: initial?.id ?? _uuid.v4(),
        name: name,
        provider: _provider,
        modelId: modelId,
        endpoint: endpoint,
        apiKey: _keyController.text.trim(),
        apiMode: _apiMode,
        keyEnv: _keyEnv,
        createdAt: initial?.createdAt ?? now,
        updatedAt: now,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        _ModelEditorResult(
          profile: profile,
          activateAfterSave: _activateAfterSave,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initialProfile != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? '编辑模型' : '手动创建新模型'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: _provider,
            decoration: const InputDecoration(
              labelText: '模型提供商预设',
            ),
            items: widget.presets
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
                    final preset = _presetOf(value);
                    setState(() {
                      _provider = preset.provider;
                      _apiMode = preset.apiMode;
                      _keyEnv = preset.keyEnv;
                      _endpointController.text = preset.endpoint;
                    });
                  },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: '模型名称',
              hintText: '用于列表显示，不填则自动使用模型ID',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: '模型 ID',
              hintText: '例如: deepseek-chat / claude-sonnet-4-6',
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
              hintText: '将写入 $_keyEnv',
              suffixIcon: IconButton(
                onPressed: _saving ? null : () => setState(() => _hideKey = !_hideKey),
                icon: Icon(_hideKey ? Icons.visibility : Icons.visibility_off),
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
          const SizedBox(height: 8),
          SwitchListTile(
            value: _activateAfterSave,
            onChanged: _saving ? null : (value) => setState(() => _activateAfterSave = value),
            title: const Text('保存后设为当前使用模型'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? '保存中...' : '保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
