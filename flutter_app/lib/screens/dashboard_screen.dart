import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/gateway_provider.dart';
import '../widgets/gateway_controls.dart';
import '../widgets/status_card.dart';
import 'configure_screen.dart';
import 'chat_screen.dart';
import 'model_settings_screen.dart';
import 'onboarding_screen.dart';
import 'terminal_screen.dart';
import 'logs_screen.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes Agent 控制台'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const GatewayControls(),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                '快捷操作',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            _buildActionCard(
              theme,
              '聊天',
              '与 Hermes Agent 直接对话',
              icon: Icons.chat_bubble_outline,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChatScreen()),
              ),
            ),
            _buildActionCard(
              theme,
              '模型与 API 设置',
              '手动配置模型、端点和密钥',
              icon: Icons.tune,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ModelSettingsScreen()),
              ),
            ),
            _buildActionCard(
              theme,
              '初始化引导',
              '配置 API 密钥和绑定地址',
              icon: Icons.rocket_launch,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              ),
            ),
            _buildActionCard(
              theme,
              '环境配置',
              '在终端运行 hermes setup',
              icon: Icons.build,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ConfigureScreen()),
              ),
            ),
            _buildActionCard(
              theme,
              '终端',
              '打开 proot 终端',
              icon: Icons.terminal,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TerminalScreen()),
              ),
            ),
            _buildActionCard(
              theme,
              '日志',
              '查看网关日志',
              icon: Icons.article,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogsScreen()),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                '运行状态',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Consumer<GatewayProvider>(
              builder: (context, provider, _) {
                return _buildStatusCard(
                  theme,
                  '网关',
                  provider.statusLabel,
                  icon: provider.isRunning ? Icons.cloud_done : Icons.cloud_off,
                  color: provider.statusColor,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionCard(
    ThemeData theme,
    String title,
    String subtitle, {
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Widget _buildStatusCard(
    ThemeData theme,
    String title,
    String value, {
    required IconData icon,
    required Color color,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return StatusCard(
      title: title,
      value: value,
      icon: icon,
      iconColor: color,
      trailing: trailing,
      onTap: onTap,
    );
  }
}
