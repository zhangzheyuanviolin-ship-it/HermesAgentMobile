import 'package:flutter/services.dart';
import '../constants.dart';

class NativeBridge {
  static const _channel = MethodChannel(AppConstants.channelName);
  static const _eventChannel = EventChannel(AppConstants.eventChannelName);

  static Future<String> getProotPath() async {
    return await _channel.invokeMethod<String>('getProotPath') ?? '';
  }

  static Future<String> getArch() async {
    return await _channel.invokeMethod<String>('getArch') ?? '';
  }

  static Future<String> getFilesDir() async {
    return await _channel.invokeMethod<String>('getFilesDir') ?? '';
  }

  static Future<String> getNativeLibDir() async {
    return await _channel.invokeMethod<String>('getNativeLibDir') ?? '';
  }

  static Future<bool> isBootstrapComplete() async {
    return await _channel.invokeMethod<bool>('isBootstrapComplete') ?? false;
  }

  static Future<Map<String, dynamic>> getBootstrapStatus() async {
    final result = await _channel.invokeMethod('getBootstrapStatus');
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> getShizukuStatus() async {
    final result = await _channel.invokeMethod('getShizukuStatus');
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> setShizukuBridgeEnabled(bool enabled) async {
    final result = await _channel.invokeMethod(
      'setShizukuBridgeEnabled',
      {'enabled': enabled},
    );
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> requestShizukuPermission() async {
    final result = await _channel.invokeMethod('requestShizukuPermission');
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>> maybeRequestShizukuPermission() async {
    final result = await _channel.invokeMethod('maybeRequestShizukuPermission');
    return Map<String, dynamic>.from(result);
  }

  static Future<bool> openShizukuApp() async {
    return await _channel.invokeMethod<bool>('openShizukuApp') ?? false;
  }

  static Future<bool> extractRootfs(String tarPath) async {
    return await _channel.invokeMethod<bool>('extractRootfs', {'tarPath': tarPath}) ?? false;
  }

  static Future<String> runInProot(String command, {int timeout = 900}) async {
    final output = await _channel.invokeMethod<String>(
      'runInProot',
      {'command': command, 'timeout': timeout},
    );
    return output ?? '';
  }

  static Future<bool> startGateway() async {
    return await _channel.invokeMethod<bool>('startGateway') ?? false;
  }

  static Future<bool> stopGateway() async {
    return await _channel.invokeMethod<bool>('stopGateway') ?? false;
  }

  static Future<bool> isGatewayRunning() async {
    return await _channel.invokeMethod<bool>('isGatewayRunning') ?? false;
  }

  static Future<bool> setupDirs() async {
    return await _channel.invokeMethod<bool>('setupDirs') ?? false;
  }

  static Future<bool> writeResolv() async {
    return await _channel.invokeMethod<bool>('writeResolv') ?? false;
  }

  static Future<String?> readRootfsFile(String path) async {
    return await _channel.invokeMethod<String>('readRootfsFile', {'path': path});
  }

  static Future<bool> writeRootfsFile(String path, String content) async {
    return await _channel.invokeMethod<bool>(
          'writeRootfsFile',
          {'path': path, 'content': content},
        ) ??
        false;
  }

  static Future<bool> hasStoragePermission() async {
    return await _channel.invokeMethod<bool>('hasStoragePermission') ?? false;
  }

  static Future<bool> requestStoragePermission() async {
    return await _channel.invokeMethod<bool>('requestStoragePermission') ?? false;
  }

  static Future<String> getExternalStoragePath() async {
    return await _channel.invokeMethod<String>('getExternalStoragePath') ?? '/sdcard';
  }

  static Future<bool> isBatteryOptimized() async {
    return await _channel.invokeMethod<bool>('isBatteryOptimized') ?? true;
  }

  static Future<bool> requestBatteryOptimization() async {
    return await _channel.invokeMethod<bool>('requestBatteryOptimization') ?? false;
  }

  static Future<bool> startTerminalService() async {
    return await _channel.invokeMethod<bool>('startTerminalService') ?? false;
  }

  static Future<bool> stopTerminalService() async {
    return await _channel.invokeMethod<bool>('stopTerminalService') ?? false;
  }

  static Future<bool> startSetupService() async {
    return await _channel.invokeMethod<bool>('startSetupService') ?? false;
  }

  static Future<bool> stopSetupService() async {
    return await _channel.invokeMethod<bool>('stopSetupService') ?? false;
  }

  static void updateSetupNotification(String text, {int progress = -1}) {
    _channel.invokeMethod('updateSetupNotification', {
      'text': text,
      'progress': progress,
    });
  }

  static Stream<String> get gatewayLogStream async* {
    await for (final event in _eventChannel.receiveBroadcastStream()) {
      if (event is String) yield event;
    }
  }
}
