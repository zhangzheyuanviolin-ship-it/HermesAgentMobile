enum SetupStep {
  checkingStatus,
  downloadingRootfs,
  extractingRootfs,
  installingPython,
  installingHermesAgent,
  configuringEnvironment,
  complete,
  error,
}

class SetupState {
  final SetupStep step;
  final double progress;
  final String message;
  final String? error;

  const SetupState({
    this.step = SetupStep.checkingStatus,
    this.progress = 0.0,
    this.message = '',
    this.error,
  });

  SetupState copyWith({
    SetupStep? step,
    double? progress,
    String? message,
    String? error,
  }) {
    return SetupState(
      step: step ?? this.step,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      error: error,
    );
  }

  bool get isComplete => step == SetupStep.complete;
  bool get hasError => step == SetupStep.error;

  String get stepLabel {
    switch (step) {
      case SetupStep.checkingStatus:
        return '正在检查状态...';
      case SetupStep.downloadingRootfs:
        return '正在下载 Ubuntu rootfs';
      case SetupStep.extractingRootfs:
        return '正在解压 rootfs';
      case SetupStep.installingPython:
        return '正在安装 Python';
      case SetupStep.installingHermesAgent:
        return '正在安装 Hermes Agent';
      case SetupStep.configuringEnvironment:
        return '正在配置环境';
      case SetupStep.complete:
        return '初始化完成';
      case SetupStep.error:
        return '错误';
    }
  }

  int get stepNumber {
    switch (step) {
      case SetupStep.checkingStatus:
        return 0;
      case SetupStep.downloadingRootfs:
        return 1;
      case SetupStep.extractingRootfs:
        return 2;
      case SetupStep.installingPython:
        return 3;
      case SetupStep.installingHermesAgent:
        return 4;
      case SetupStep.configuringEnvironment:
        return 5;
      case SetupStep.complete:
        return 6;
      case SetupStep.error:
        return -1;
    }
  }

  static const int totalSteps = 6;
}
