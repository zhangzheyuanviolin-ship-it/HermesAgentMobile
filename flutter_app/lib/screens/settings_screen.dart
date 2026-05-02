import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app.dart';
import '../constants.dart';
import '../services/native_bridge.dart';
import '../services/preferences_service.dart';
import 'setup_wizard_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = PreferencesService();
  bool _autoStart = false;
  bool _batteryOptimized = true;
  String _arch = '';
  String _prootPath = '';
  Map<String, dynamic> _status = {};
  bool _loading = true;
  bool _storageGranted = false;
  Map<String, dynamic> _shizukuStatus = {};
  bool _shizukuBusy = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _prefs.init();
    _autoStart = _prefs.autoStartGateway;

    try {
      final arch = await NativeBridge.getArch();
      final prootPath = await NativeBridge.getProotPath();
      final status = await NativeBridge.getBootstrapStatus();
      final batteryOptimized = await NativeBridge.isBatteryOptimized();
      final storageGranted = await NativeBridge.hasStoragePermission();
      final shizukuStatus = await NativeBridge.getShizukuStatus();

      setState(() {
        _batteryOptimized = batteryOptimized;
        _storageGranted = storageGranted;
        _shizukuStatus = shizukuStatus;
        _arch = arch;
        _prootPath = prootPath;
        _status = status;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _sectionHeader(theme, '常规'),
                SwitchListTile(
                  title: const Text('自动启动网关'),
                  subtitle: const Text('应用启动后自动拉起网关'),
                  value: _autoStart,
                  onChanged: (value) {
                    setState(() => _autoStart = value);
                    _prefs.autoStartGateway = value;
                  },
                ),
                ListTile(
                  title: const Text('电池优化'),
                  subtitle: Text(_batteryOptimized
                      ? '已优化（可能杀死后台会话）'
                      : '无限制（推荐）'),
                  leading: const Icon(Icons.battery_alert),
                  trailing: _batteryOptimized
                      ? const Icon(Icons.warning, color: AppColors.statusAmber)
                      : const Icon(Icons.check_circle, color: AppColors.statusGreen),
                  onTap: () async {
                    await NativeBridge.requestBatteryOptimization();
                    final optimized = await NativeBridge.isBatteryOptimized();
                    setState(() => _batteryOptimized = optimized);
                  },
                ),
                ListTile(
                  title: const Text('存储权限'),
                  subtitle: Text(_storageGranted
                      ? '已授权，proot 可访问 /sdcard。不需要时可撤销。'
                      : '未授权（推荐），仅在需要共享存储时再授权'),
                  leading: const Icon(Icons.sd_storage),
                  trailing: _storageGranted
                      ? const Icon(Icons.warning_amber, color: AppColors.statusAmber)
                      : const Icon(Icons.check_circle, color: AppColors.statusGreen),
                  onTap: () async {
                    await NativeBridge.requestStoragePermission();
                    final granted = await NativeBridge.hasStoragePermission();
                    setState(() => _storageGranted = granted);
                  },
                ),
                SwitchListTile(
                  title: const Text('Shizuku 系统命令通道'),
                  subtitle: Text(_buildShizukuSubtitle()),
                  value: _shizukuStatus['enabled'] == true,
                  onChanged: _shizukuBusy
                      ? null
                      : (value) async {
                          setState(() => _shizukuBusy = true);
                          try {
                            final status = await NativeBridge.setShizukuBridgeEnabled(value);
                            setState(() => _shizukuStatus = status);
                          } finally {
                            if (mounted) {
                              setState(() => _shizukuBusy = false);
                            }
                          }
                        },
                ),
                ListTile(
                  title: const Text('请求 Shizuku 授权'),
                  subtitle: const Text('仅当已安装并已启动 Shizuku 服务时可申请'),
                  leading: const Icon(Icons.shield_outlined),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _shizukuBusy
                      ? null
                      : () async {
                          setState(() => _shizukuBusy = true);
                          try {
                            final status = await NativeBridge.requestShizukuPermission();
                            setState(() => _shizukuStatus = status);
                          } finally {
                            if (mounted) {
                              setState(() => _shizukuBusy = false);
                            }
                          }
                        },
                ),
                ListTile(
                  title: const Text('打开 Shizuku 应用'),
                  subtitle: const Text('用于启动服务或检查授权状态'),
                  leading: const Icon(Icons.open_in_new),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final opened = await NativeBridge.openShizukuApp();
                    if (!mounted) return;
                    if (!opened) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('未找到 Shizuku 应用或无法打开')),
                      );
                    }
                  },
                ),
                const Divider(),
                _sectionHeader(theme, '系统信息'),
                ListTile(
                  title: const Text('系统架构'),
                  subtitle: Text(_arch),
                  leading: const Icon(Icons.memory),
                ),
                ListTile(
                  title: const Text('PRoot 路径'),
                  subtitle: Text(_prootPath),
                  leading: const Icon(Icons.folder),
                ),
                ListTile(
                  title: const Text('Rootfs'),
                  subtitle: Text(_status['rootfsExists'] == true
                      ? '已安装'
                      : '未安装'),
                  leading: const Icon(Icons.storage),
                ),
                ListTile(
                  title: const Text('Python'),
                  subtitle: Text(_status['pythonInstalled'] == true
                      ? '已安装'
                      : '未安装'),
                  leading: const Icon(Icons.code),
                ),
                ListTile(
                  title: const Text('Hermes Agent'),
                  subtitle: Text(_status['hermesInstalled'] == true
                      ? '已安装'
                      : '未安装'),
                  leading: const Icon(Icons.cloud),
                ),
                const Divider(),
                _sectionHeader(theme, '维护'),
                ListTile(
                  title: const Text('导出快照'),
                  subtitle: const Text('将配置备份到下载目录'),
                  leading: const Icon(Icons.upload_file),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _exportSnapshot,
                ),
                ListTile(
                  title: const Text('导入快照'),
                  subtitle: const Text('从备份恢复配置'),
                  leading: const Icon(Icons.download),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _importSnapshot,
                ),
                ListTile(
                  title: const Text('重新执行初始化'),
                  subtitle: const Text('重装或修复运行环境'),
                  leading: const Icon(Icons.build),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                      builder: (_) => const SetupWizardScreen(),
                    ),
                  ),
                ),
                const Divider(),
                _sectionHeader(theme, '关于'),
                const ListTile(
                  title: Text('Hermes Agent'),
                  subtitle: Text(
                    'Android 智能体网关\n版本 ${AppConstants.version}',
                  ),
                  leading: Icon(Icons.info_outline),
                  isThreeLine: true,
                ),
                ListTile(
                  title: const Text('GitHub'),
                  subtitle: const Text('nousresearch/hermes-agent-mobile'),
                  leading: const Icon(Icons.code),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => launchUrl(
                    Uri.parse(AppConstants.githubUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                ListTile(
                  title: const Text('联系方式'),
                  subtitle: const Text(AppConstants.authorEmail),
                  leading: const Icon(Icons.email),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => launchUrl(
                    Uri.parse('mailto:${AppConstants.authorEmail}'),
                  ),
                ),
                const ListTile(
                  title: Text('许可证'),
                  subtitle: Text(AppConstants.license),
                  leading: Icon(Icons.description),
                ),
              ],
            ),
    );
  }

  String _buildShizukuSubtitle() {
    final installed = _shizukuStatus['installed'] == true;
    final running = _shizukuStatus['running'] == true;
    final granted = _shizukuStatus['permissionGranted'] == true ||
        _shizukuStatus['granted'] == true;
    final commandReady = _shizukuStatus['commandReady'] == true;
    return 'Shizuku${installed ? '已安装' : '未安装'}。 服务${running ? '运行中' : '未运行'}。 权限${granted ? '已授予' : '未授予'}。 命令${commandReady ? '已就绪' : '未就绪'}。';
  }

  Future<String> _getSnapshotPath() async {
    final hasPermission = await NativeBridge.hasStoragePermission();
    if (hasPermission) {
      final sdcard = await NativeBridge.getExternalStoragePath();
      final downloadDir = Directory('$sdcard/Download');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return '$sdcard/Download/hermes-snapshot.json';
    }
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/hermes-snapshot.json';
  }

  Future<void> _exportSnapshot() async {
    try {
      final hermesConfig =
          await NativeBridge.readRootfsFile('root/.hermes/config.yaml') ?? '';
      final snapshot = {
        'version': AppConstants.version,
        'timestamp': DateTime.now().toIso8601String(),
        'hermesConfig': hermesConfig,
        'autoStart': _prefs.autoStartGateway,
      };
      final path = await _getSnapshotPath();
      await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(snapshot));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('快照已保存到: $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
    }
  }

  Future<void> _importSnapshot() async {
    try {
      final path = await _getSnapshotPath();
      final file = File(path);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('未找到快照文件: $path')),
        );
        return;
      }
      final content = await file.readAsString();
      final snapshot = jsonDecode(content) as Map<String, dynamic>;
      final hermesConfig = snapshot['hermesConfig'] as String?;
      if (hermesConfig != null) {
        await NativeBridge.writeRootfsFile('root/.hermes/config.yaml', hermesConfig);
      }
      if (snapshot['autoStart'] != null) {
        _prefs.autoStartGateway = snapshot['autoStart'] as bool;
      }
      await _loadSettings();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('快照恢复成功，请重启网关后生效。')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
