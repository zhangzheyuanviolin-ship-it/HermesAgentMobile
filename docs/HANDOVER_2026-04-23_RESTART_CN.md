# HermesAgentMobile 从零重启交接文档

生成时间：2026-04-23

## 1. 当前结论

本轮已经重新确认真正上游仓库，并在张老师的 GitHub 账号下重新 fork 了一份干净仓库。

真正上游仓库是：

https://github.com/Binair-Dev/HermesAgentMobile

张老师账号下新 fork 仓库是：

https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile

本地干净浅克隆路径是：

/data/user/0/com.codex.mobile.pocketlobster.test/files/home/codex/work/HermesAgentMobile_clean_20260423_shallow

当前干净克隆 HEAD：

b68f921 docs: correct upstream credit to OpenClaw Termux

注意：旧的 /data/user/0/com.codex.mobile.pocketlobster.test/files/home/codex/work/HermesAgentMobile 和 HermesAgentMobile_v2 等目录只能作为历史参考，不允许作为新项目基线继续修。新项目必须基于上面的干净 fork 和干净克隆目录开展。

## 2. 用户目标

张老师的真实目标不是继续修补旧污染版本，而是从上游 HermesAgentMobile 重新开始，只做清晰、可回溯、可交付的最小改造。

核心需求只有两个：

1. 全局中文适配：面向普通中文用户，尽量做到 100% UI 文案中文化，包括初始化、首页、设置、日志、终端提示、错误提示、按钮、状态、对话框、通知等。

2. 降低命令行门槛：上游原始应用主要通过终端和 `hermes setup` 与 AI / Hermes Agent 交互。张老师需要新增可视化聊天入口和可视化模型配置入口，让普通用户至少可以手动填写提供商、模型、Base URL、API 密钥，然后在聊天框里像聊天机器人一样给智能体下达指令。

重要约束：先保证初始化、网关启动、API 请求、模型收发消息、前端渲染这条主链路稳定，再优化过程展示和布局。不要一次性堆很多花哨功能。

## 3. 当前上游源码结构

Flutter 应用目录：

flutter_app/

主要 Dart 入口：

flutter_app/lib/main.dart

flutter_app/lib/app.dart

上游已有页面：

flutter_app/lib/screens/splash_screen.dart：启动页，检查初始化状态，执行自动修复。

flutter_app/lib/screens/setup_wizard_screen.dart：初始化向导入口。

flutter_app/lib/screens/dashboard_screen.dart：首页，包含 GatewayControls、Configure、Terminal、Logs、Settings 等入口。

flutter_app/lib/screens/configure_screen.dart：通过终端运行 `cd /root/hermes-agent && source venv/bin/activate && python -m hermes_cli.main setup`，这是上游当前主要配置方式，但对普通用户不友好。

flutter_app/lib/screens/settings_screen.dart：设置页，已有自动启动、共享存储授权、电池优化、快照导入导出、重新初始化等功能。

flutter_app/lib/screens/logs_screen.dart：网关日志页面。

flutter_app/lib/screens/terminal_screen.dart：PRoot 终端页面。

上游已有服务：

flutter_app/lib/services/bootstrap_service.dart：下载 Ubuntu rootfs、安装基础依赖、clone `nousresearch/hermes-agent`、安装 Python 依赖、验证 `/root/hermes-agent/gateway/run.py`。

flutter_app/lib/services/gateway_service.dart：Flutter 层网关状态管理。

flutter_app/lib/services/native_bridge.dart：Flutter 与 Android 原生 MethodChannel/EventChannel 的桥。

flutter_app/lib/services/terminal_service.dart：终端/PRoot 参数构建。

Android 原生关键文件：

flutter_app/android/app/src/main/kotlin/com/nxg/hermesagentmobile/BootstrapManager.kt：rootfs 解包、目录准备、resolv.conf、假 /proc /sys 文件、环境修复。

flutter_app/android/app/src/main/kotlin/com/nxg/hermesagentmobile/ProcessManager.kt：构建 proot 命令，区分 install mode 和 gateway mode。这里已经有共享存储挂载逻辑：授权后 bind `/storage:/storage` 和 `/storage/emulated/0:/sdcard`。

flutter_app/android/app/src/main/kotlin/com/nxg/hermesagentmobile/GatewayService.kt：启动后台网关服务，当前上游命令是 `cd /root/hermes-agent && source venv/bin/activate && exec python gateway/run.py`。

flutter_app/android/app/src/main/kotlin/com/nxg/hermesagentmobile/MainActivity.kt：MethodChannel 方法分发。

上游当前没有：

聊天页面。

聊天会话持久化模型。

可视化模型/API 配置页面。

OpenAI 兼容 API 请求服务。

GitHub Actions Flutter APK 打包工作流。

## 4. 必须优先修复的上游初始化坑

上游 `bootstrap_service.dart` 当前依赖安装逻辑仍是：

`pip install -r requirements.txt`

但 2026-04-23 实测 `https://github.com/nousresearch/hermes-agent.git` 当前主分支没有 `requirements.txt`，只有 `pyproject.toml`、`uv.lock`、`hermes_cli/setup.py` 等。因此初始化会失败：

`ERROR: Could not open requirements file: [Errno 2] No such file or directory: 'requirements.txt'`

下一轮开发必须最先改这个，否则用户第一步初始化就失败。

建议改法：

在 `flutter_app/lib/services/bootstrap_service.dart` 的 Python 依赖安装命令里使用兼容链路：

如果存在 `requirements.txt`，执行 `pip install -r requirements.txt`。

否则如果存在 `pyproject.toml`，执行 `pip install -e .`。

否则如果存在 `hermes_cli/setup.py`，执行 `pip install -e ./hermes_cli`。

否则明确报错。

同样修 `flutter_app/lib/screens/splash_screen.dart` 里的 Auto-repair 分支。旧代码在 hermesOk=false 时直接：

`cd /root/hermes-agent && source venv/bin/activate && pip install -r requirements.txt`

这个也会失败，必须同步修。

## 5. 聊天入口建议实现路线

目标：普通用户不进终端也能聊天。

建议新增文件：

flutter_app/lib/screens/chat_screen.dart

flutter_app/lib/services/chat_service.dart

flutter_app/lib/models/chat_session_models.dart

flutter_app/lib/services/chat_session_store.dart

建议在 `flutter_app/lib/screens/dashboard_screen.dart` 增加“聊天”入口，位置优先放在 Configure/Terminal 前面。

聊天服务建议先走 Hermes Agent gateway 暴露的 OpenAI 兼容 API。此前可用路径是应用内 API Server 端口 8642：

`http://127.0.0.1:8642/v1/chat/completions`

对应需要在 Android `GatewayService.kt` 启动网关时注入环境变量：

`API_SERVER_ENABLED=true API_SERVER_HOST=127.0.0.1 API_SERVER_PORT=8642`

原始上游只启动 `python gateway/run.py`，没有显式打开 API Server。新增聊天页前必须确认 API Server 是否实际监听。最小改造建议在 `GatewayService.kt` 把启动命令改成：

`cd /root/hermes-agent && source venv/bin/activate && API_SERVER_ENABLED=true API_SERVER_HOST=127.0.0.1 API_SERVER_PORT=8642 exec python gateway/run.py`

然后在 Dart 常量里新增：

`apiServerUrl = 'http://127.0.0.1:8642'`

聊天请求优先使用 `/v1/chat/completions`，不要一开始切到 `/v1/responses`。之前把主通道切到 responses 后造成认证和收发消息问题更难定位。

ChatService 的最低要求：

POST `/v1/chat/completions`

body 含 `model: hermes-agent`、`stream: true`、`messages: [...]`

解析 SSE 的 `data:` 行。

兼容 OpenAI chat completions：`choices[0].delta.content` 和非流式 `choices[0].message.content`。

错误必须显示在聊天页和过程区，不允许静默吞掉。

如果流式结束但最终回复为空，可增加非流式补拉兜底，但不要让兜底破坏主通道。

## 6. 模型配置入口建议实现路线

目标：普通用户可以在表单里填模型配置，而不是进终端跑 `hermes setup`。

建议新增文件：

flutter_app/lib/screens/model_settings_screen.dart

入口放到 Dashboard 或 Settings 中。

可参考旧版本思路，但不要直接复制旧污染版本全部代码。核心方法是通过 `NativeBridge.runInProot` 执行 Hermes CLI config set：

`cd /root/hermes-agent && source venv/bin/activate && python -m hermes_cli.main config set '<key>' '<value>'`

建议支持字段：

提供商 provider：openrouter、custom、anthropic、gemini、deepseek、openai-codex 等。

模型 ID：写 `model.default`。

Base URL：写 `model.base_url`。

API 协议：写 `model.api_mode`，先保留 chat_completions / codex_responses / anthropic_messages / bedrock_converse。

API 密钥：写对应环境变量，例如 OPENROUTER_API_KEY、OPENAI_API_KEY、ANTHROPIC_API_KEY、GOOGLE_API_KEY、DEEPSEEK_API_KEY 等，同时可写 `model.api_key` 做兼容。

读取配置可用：

`NativeBridge.readRootfsFile('root/.hermes/config.yaml')`

`NativeBridge.readRootfsFile('root/.hermes/.env')`

写配置要注意 shell 单引号转义，旧经验中 `_escapeSingleQuotes(value).replaceAll("'", "'\"'\"'")` 可用。

保存后提示用户重启网关生效。

## 7. 全局中文适配范围

上游仍大量英文 UI。需要逐页汉化。

优先汉化文件：

flutter_app/lib/app.dart：MaterialApp title、主题相关不用全部改，用户可见 title 要改。

flutter_app/lib/screens/splash_screen.dart：Loading、Checking setup status、AI Gateway for Android、Error 等。

flutter_app/lib/screens/dashboard_screen.dart：Hermes Agent 可保留品牌名，但 QUICK ACTIONS、Onboarding、Configure、Terminal、Logs、STATUS、Gateway 等要汉化。

flutter_app/lib/screens/settings_screen.dart：Settings、GENERAL、Auto-start gateway、Battery Optimization、Setup Storage、SYSTEM INFO、MAINTENANCE、ABOUT 等。

flutter_app/lib/screens/setup_wizard_screen.dart：初始化向导所有步骤。

flutter_app/lib/screens/configure_screen.dart：标题、错误、复制、粘贴、打开链接等。

flutter_app/lib/screens/logs_screen.dart：日志页面。

flutter_app/lib/screens/terminal_screen.dart：终端页面。

flutter_app/lib/widgets/*：按钮、状态、提示文案。

flutter_app/lib/models/setup_state.dart 和 gateway_state.dart：状态文字。

Android 原生通知也要汉化：

GatewayService.kt：通知标题、状态文本、日志中的重要用户可见错误。

SetupService.kt：初始化通知。

TerminalSessionService.kt：终端通知。

不要改包名，保持：

`com.nxg.hermesagentmobile`

否则会影响升级安装关系和用户设备上的数据路径。

## 8. 聊天页布局避坑

张老师明确希望聊天区可理解为三块：

用户发送的消息。

执行过程。

最终输出结果。

但之前尝试把所有内容强行拆成三块后，实际体验仍不稳定。下一轮建议先采用保守布局：

默认关闭“显示过程”时，聊天主列表只显示用户消息和助手最终回复。

打开“显示过程”时，下面或中间出现独立过程面板，只显示模型 reasoning / tool call / 状态，不要显示整段网关原始日志。

不要把 GatewayProvider.logs 全量镜像到聊天过程面板。旧版本这么做会让“显示过程”变成网关进程日志，不是用户想看的智能体过程。

如果模型输出了 `<assistant_process>` 和 `<assistant_final>` 标签，前端可解析：

最终区只显示 `<assistant_final>`。

过程区显示 `<assistant_process>`。

如果模型没有按标签输出，则先把原文作为最终回复显示，避免“无最终回复内容”。

不要激进过滤普通文本。之前“最终回复（无最终回复内容）”的一个风险就是前端过滤太激进，把可见文本当成过程删掉。

## 9. 系统指令建议

可以在聊天请求 messages 开头注入 system 指令，但不要指望系统指令 100% 解决分离问题，前端仍需容错。

建议注入内容：

要求模型使用 `<assistant_process>` 包裹执行过程、工具调用、中间观察。

要求模型使用 `<assistant_final>` 包裹最终给用户看的回复。

要求最终回复不要复述“首先、接下来、我将检查”等过程句。

告诉模型 Android 共享存储已经挂载到 `/storage` 和 `/sdcard`，`/sdcard` 通常映射 `/storage/emulated/0`。

要求涉及外部文件时先检查 `/sdcard`、`/storage`、`/storage/emulated/0`，不要在未检查前说无法访问共享存储。

## 10. 之前已踩坑清单

1. 上游地址曾经误判。真实上游是 `Binair-Dev/HermesAgentMobile`。`TapXWorld/HermesAgentMobile` 当前 GitHub API 返回 404，不要再用。

2. 用户仓库已被删除后重新 fork。现在新 fork 是 `zhangzheyuanviolin-ship-it/HermesAgentMobile`，父仓库是 `Binair-Dev/HermesAgentMobile`。

3. 完整 clone 曾因 GitHub 连接中断失败，报 `RPC failed; curl 56 ... unexpected eof`。解决方式是浅克隆：`git clone --depth=1 --filter=blob:none ...`。

4. 本地 `rg` 在当前 Android app 环境里可能不可执行，报 vendor musl 路径缺失。搜索时可直接用 `grep -RIn`、`find`、`sed`。

5. 当前 Codex 本地环境没有 `flutter` 和 `dart` 命令，不能本地 flutter analyze/build。需要使用 GitHub Actions 云端构建 APK。

6. 上游没有 GitHub Actions Flutter APK 工作流。需要新增 `.github/workflows/flutter-build.yml`，步骤至少包括 checkout、setup Java 17、setup Flutter stable、安装 zstd/binutils、执行 `scripts/fetch-proot-binaries.sh`、`flutter pub get`、`flutter build apk --release`、upload artifact。

7. `scripts/fetch-proot-binaries.sh` 依赖 `zstd`、`ar`、`tar`、`curl`。云端 Ubuntu runner 需要先安装 `zstd binutils`。

8. 初始化失败主要来自 `requirements.txt` 缺失。必须改成 pyproject/requirements 兼容安装。

9. 旧版本为了修“最终回复为空”曾把聊天主通道切到 `/v1/responses`，后来引入更严重的认证/收发问题。新版本从头做时，优先用 `/v1/chat/completions`，responses 只能作为明确兼容分支或兜底。

10. 不要把 API Server 和 Gateway 端口混淆。上游网关主端口是 18789；聊天 API Server 曾使用 8642，需要在 `GatewayService.kt` 明确启用。

11. `ProcessManager.kt` 使用 `env -i` 清理 guest 环境，这是为了避免 Android JVM 环境变量污染 proot。不要随便去掉。

12. 共享存储访问依赖 Android “管理所有文件”授权。授权后 ProcessManager 会 bind `/storage` 和 `/sdcard`。系统指令也要告诉模型这些路径存在。

13. 旧改造版本里曾经出现 401。这类问题不一定是前端解析错误，也可能是模型配置、环境变量、provider/api_mode 不一致。排查顺序应是配置文件、`.env`、网关日志、实际 API 请求，而不是先改前端解析。

14. 旧改造版本里多次出现“最终回复（无最终回复内容）”。高风险点包括模型把内容放进 reasoning/process、前端只读取某一种 chunk 字段、或前端标签过滤过度。修复时要兼容多种字段并保留兜底显示。

15. 安装包管理曾经混乱。后续交付必须只在根目录保留一个 `HermesAgentMobile-当前唯一安装包.apk`，其他版本移入 `历史安装包`。

## 11. 推荐开发顺序

第一阶段：建立干净可构建基线。

确认 fork 可访问。

新增 GitHub Actions APK 构建工作流。

触发一次不改业务的基线构建，下载 APK，记录 run id、commit sha、SHA256。

第二阶段：修初始化。

修 `requirements.txt` 缺失问题。

保留 `env -i` 和 proot-distro 风格参数。

构建 APK，用户实测初始化通过。

第三阶段：汉化。

按页面逐步汉化，不改业务逻辑。

构建 APK，用户实测主流程中文可读。

第四阶段：可视化模型配置。

新增 `ModelSettingsScreen`。

通过 `NativeBridge.runInProot` 写 config。

构建 APK，用户实测填 key 后重启网关生效。

第五阶段：聊天入口。

先在 `GatewayService.kt` 启用 API Server。

新增 `ChatService`，用 `/v1/chat/completions` 流式请求。

新增 `ChatScreen`，先保证用户消息和助手回复稳定显示。

再做过程面板和最终输出分离。

第六阶段：整理交付。

每次 APK 文件名带 run id 和简短功能名。

根目录只留 `HermesAgentMobile-当前唯一安装包.apk`。

历史包统一放 `历史安装包`。

文档记录 commit、run id、SHA256、改动点、已知风险。

## 12. 建议云端构建工作流

上游没有 `.github/workflows/flutter-build.yml`，需要在新 fork 中新增。旧项目中成功用过的结构：

name: Build Android APK

on:

workflow_dispatch

push main 且 paths 包含 flutter_app、scripts、workflow 文件

jobs:

ubuntu-latest

actions/checkout@v4

actions/setup-java@v4，Java 17

subosito/flutter-action@v2，stable

sudo apt-get install -y zstd binutils

bash scripts/fetch-proot-binaries.sh

flutter pub get

flutter build apk --release --build-name "0.3.${{ github.run_number }}" --build-number "${{ github.run_number }}"

upload-artifact name `hermes-agent-mobile-apk`

后续触发：

推送 main 自动触发，或通过 GitHub API workflow_dispatch 指定 ref。

下载 artifact：

GET `/repos/zhangzheyuanviolin-ship-it/HermesAgentMobile/actions/runs/<run_id>/artifacts`

下载 artifact zip，解压出 APK。

## 13. APK 交付路径规范

张老师已删除原来的手机本地改造文件夹。未来接手时需要重新创建：

/sdcard/下载管理/HermesAgentMobile项目改造

历史目录：

/sdcard/下载管理/HermesAgentMobile项目改造/历史安装包

根目录只保留：

/sdcard/下载管理/HermesAgentMobile项目改造/HermesAgentMobile-当前唯一安装包.apk

带版本名的 APK 可以短暂生成，但最终要移入历史目录，避免根目录多个 APK 混淆。

每次最终汇报必须包含：

APK 路径。

Git commit sha。

GitHub Actions run id。

SHA256。

是否已移动旧包到历史目录。

## 14. 当前远端和本地状态

GitHub 账号：

zhangzheyuanviolin-ship-it

新 fork 仓库：

https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile

父仓库：

https://github.com/Binair-Dev/HermesAgentMobile

本地干净克隆：

/data/user/0/com.codex.mobile.pocketlobster.test/files/home/codex/work/HermesAgentMobile_clean_20260423_shallow

本交接文档路径：

/data/user/0/com.codex.mobile.pocketlobster.test/files/home/codex/work/HermesAgentMobile_clean_20260423_shallow/docs/HANDOVER_2026-04-23_RESTART_CN.md

## 15. 给下一轮 Codex 的工作原则

不要继续追旧污染版本的 bug。

不要把旧目录里的 APK 当作基线。

不要在未构建验证前一次性大改聊天协议、过程解析和 UI 布局。

每一版只解决一个清晰阶段目标。

每次提交信息要可读，APK 文件名要可读，交付目录根下只能有唯一当前 APK。

如果用户说“正常收发消息优先”，技术判断一律服从这条主线：API 请求成功、模型收到用户消息、模型回复返回、前端显示最终回复。

