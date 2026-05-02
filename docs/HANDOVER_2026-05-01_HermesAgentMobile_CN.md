HermesAgentMobile 项目交接文档
生成时间：2026-05-01 UTC
文档目的：为新的无上下文会话提供完整、可落地、可继续开发的项目背景、源码位置、资产位置、版本状态、技术架构、实现方式、开发过程和后续接手依据。

一、当前环境核对结论
1. 本地旧工作副本现状
当前安卓私有目录下已不存在此前的 HermesAgentMobile 本地源码工作副本。已实际搜索目录：
/data/user/0/com.codex.mobile.pocketlobster.test/files/home
搜索结果显示没有本地 HermesAgentMobile 仓库目录残留，说明此前为清理手机存储已删除本地克隆副本。

2. 本地交接文档现状
已在以下范围内搜索旧交接文档：
/data/user/0/com.codex.mobile.pocketlobster.test/files/home
/sdcard
搜索关键字为 HANDOVER 和 交接，结果未发现当前环境残留的旧交接文档文件。因此本文件为当前环境中的唯一交接文档。

3. 当前仍保留的本地资产
当前本地仍保留项目 APK 安装包资产，位于：
/sdcard/下载管理/HermesAgentMobile项目改造
历史安装包归档目录位于：
/sdcard/下载管理/HermesAgentMobile项目改造/历史安装包

4. 云端源码仓库仍然存在并可访问
当前项目接手应以云端仓库为准。已核对真实仓库为：
主仓库 Fork：https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile
默认分支：main
上游仓库 Parent：https://github.com/Binair-Dev/HermesAgentMobile
仓库说明：Hermes Agent AI Gateway for Android - standalone mobile app
仓库创建时间：2026-04-23T12:12:37Z
Fork 来源上游最近在 GitHub API 中显示为 Binair-Dev/HermesAgentMobile

二、项目背景与目标
1. 项目本质
这是一个将 Hermes Agent 网关封装到 Android 手机上的独立 Flutter 应用，目标是在 Android 设备中通过内置前端、Android 服务、proot Ubuntu 根文件系统和 Python 环境运行 Hermes Agent。

2. 用户侧真实需求背景
本项目并不是普通聊天机器人壳，而是要让手机端能够：
初始化 Ubuntu + Python + Hermes Agent 环境。
配置模型、端点、密钥。
进入聊天界面与智能体交互。
显示工具调用和任务执行过程。
在长任务场景下避免前端短超时误杀执行。
支持会话管理、附件接入、中文界面和可访问性。

3. 此轮接手背景
此前项目存在版本混乱、源码污染和签名不稳定等问题，因此在 2026-04-23 做过一次“重启式接手”。本轮最新有效状态已经发展到 0.3.12，并同时产出了正式原始版和并行测试版两个 APK。

三、当前可用源码位置与版本定位
1. 正式原始版最新源码位置
云端分支：main
提交 SHA：65d9c4f3e32162bbdc7c0c0f911201880d441c58
短 SHA：65d9c4f
提交时间：2026-04-25T04:29:11Z
提交标题：feat(model-settings): add multi-model management with create/edit/delete/select/probe
用途：这是原始包名正式版的最新源码基线，应作为继续开发原始版的主基线。

2. 测试版最新源码位置
云端分支：build/testpkg-0.3.12-20260425
提交 SHA：904d35e9871ce1a0da0070c203711e1a7d167419
短 SHA：904d35e
提交时间：2026-04-25T04:29:44Z
提交标题：build(test): package id suffix and launcher label for parallel install
用途：这是并行测试版源码分支。

3. 两个最新源码分支之间的关系
测试版分支是在正式版 0.3.12 功能已经完成后，仅针对并行安装需求做了包名和桌面显示名改动的构建分支。除包名与应用名差异外，功能逻辑应与 main 上的 0.3.12 正式版保持一致。

4. 关键源码文件云端路径
Flutter 主入口：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/tree/main/flutter_app
Android 原生层：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/tree/main/flutter_app/android/app/src/main/kotlin/com/nxg/hermesagentmobile
聊天页面：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/screens/chat_screen.dart
聊天服务与流式解析：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/services/chat_service.dart
会话存储：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/services/chat_session_store.dart
多模型管理页面：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/screens/model_settings_screen.dart
多模型数据模型：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/models/model_profile_models.dart
多模型本地存储：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/lib/services/model_profile_store.dart
Flutter 工作流：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/.github/workflows/flutter-build.yml
Android 包名与签名配置：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/android/app/build.gradle
Android 应用名与权限：
https://github.com/zhangzheyuanviolin-ship-it/HermesAgentMobile/blob/main/flutter_app/android/app/src/main/AndroidManifest.xml

四、技术架构与实现方式
1. 总体架构
项目由四层组成：
Flutter 前端层：负责页面、交互、聊天区渲染、模型设置、会话管理、附件入口、状态提示。
Android Kotlin 原生层：负责 GatewayService、SetupService、TerminalSessionService、MainActivity、BootstrapManager、ProcessManager 等。
proot Ubuntu 运行层：在 Android 内启动 Ubuntu rootfs，承载 Python 和 Hermes Agent。
Hermes Agent / Python 网关层：在 Ubuntu 内运行 Hermes Agent，并通过本地 HTTP API 为 Flutter 前端服务。

2. Flutter 层职责
Flutter 主要位于 flutter_app/lib 下，按 screens、services、models、providers、widgets 拆分。
screens：页面实现。
services：调用本地网关、处理流式消息、读写会话、桥接原生。
models：聊天会话模型、模型配置模型、网关状态模型、安装状态模型。
widgets：状态卡片、终端工具栏、网关控件等。

3. Android 原生层职责
MainActivity：Flutter 与原生桥接主入口。
BootstrapManager：初始化 rootfs、下载和解压运行时资源、准备 Python/Hermes 环境。
GatewayService：启动和维护 Hermes 网关进程。
TerminalSessionService：维护终端会话能力。
SetupService：执行首次环境安装相关任务。
ProcessManager：对子进程生命周期做集中控制。

4. Hermes 配置实际落点
模型配置不是直接存储在 Flutter 内部就完事，而是需要最终写回 Hermes 实际配置文件。
当前逻辑涉及的真实 Hermes 配置路径为：
root/.hermes/config.yaml
root/.hermes/.env
Flutter 通过 native_bridge 和 proot 命令调用把当前选中的模型配置应用回 Hermes。

5. 本地持久化数据
聊天会话有独立本地存储。
多模型管理在 0.3.12 新增了独立持久化文件：
model_profiles_v1.json
该文件保存在 Flutter 应用文档目录，由 model_profile_store.dart 管理。

五、当前最新版本状态
1. 正式原始版最新版本
版本名：0.3.12
包名：com.nxg.hermesagentmobile
桌面应用名：Hermes Agent
源码分支：main
源码提交：65d9c4f3e32162bbdc7c0c0f911201880d441c58
构建运行号：24922578879
GitHub Actions run_number：16
对应构建时间：2026-04-25T04:29:16Z 到 2026-04-25T04:37:24Z
APK 本地路径：
/sdcard/下载管理/HermesAgentMobile项目改造/HermesAgentMobile-v0.3.12-原始版-可覆盖更新.apk
当前唯一安装包快捷副本路径：
/sdcard/下载管理/HermesAgentMobile项目改造/HermesAgentMobile-当前唯一安装包.apk
历史归档路径：
/sdcard/下载管理/HermesAgentMobile项目改造/历史安装包/HermesAgentMobile-run24922578879-v0.3.12-prod.apk
SHA256：
202354870cfe4900897e65d9c5847ca383ffaaf59f7f9f5edad71e1cb55de041

2. 测试版最新版本
版本名：0.3.12
包名：com.nxg.hermesagentmobile.test
桌面应用名：Hermes Agent 测试版
源码分支：build/testpkg-0.3.12-20260425
源码提交：904d35e9871ce1a0da0070c203711e1a7d167419
构建运行号：24922589309
GitHub Actions run_number：17
对应构建时间：2026-04-25T04:29:53Z 到 2026-04-25T04:38:29Z
APK 本地路径：
/sdcard/下载管理/HermesAgentMobile项目改造/HermesAgentMobile-v0.3.12-测试版-并行安装.apk
历史归档路径：
/sdcard/下载管理/HermesAgentMobile项目改造/历史安装包/HermesAgentMobile-run24922589309-v0.3.12-test.apk
SHA256：
11f6eb0e878ed711b379becd2443ea1ad41e96f55584a8e3c615a13ff9b7835b

3. 两个版本的实际差异
正式版与测试版最新 0.3.12 在功能层面应完全一致。
唯一设计目标差异：
正式版用于覆盖正式安装链路。
测试版用于并行安装验证，不影响正式版。

六、签名方式与构建机制
1. 当前签名机制的真实来源
签名方式由 GitHub Actions 工作流控制，工作流文件为：
.github/workflows/flutter-build.yml
工作流会从 GitHub Secrets 中读取：
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
然后写出：
flutter_app/android/app/release.keystore
flutter_app/android/key.properties

2. build.gradle 中的实际签名逻辑
flutter_app/android/app/build.gradle 中实际逻辑为：
如果 key.properties 存在且 storeFile 对应 keystore 存在，则定义 release 签名配置。
debug 构建和 release 构建都会优先使用同一套 release signingConfig。
如果 keystore 不存在，则才退回 debug 签名。

3. 签名稳定性修复的关键历史点
在提交 ee1d84c81eb1165ca4850ac74d5bdfad938da129 中，修复了 CI keystore 路径错误问题。
提交标题：
fix: correct CI keystore path to prevent debug-sign fallback
这一步是后续签名持久化能够成立的关键修复。

4. 关于最新 0.3.12 的签名结论
从当前重新核对到的云端工作流和 build.gradle 配置看，0.3.12 仍然沿用 release keystore 机制。
文档撰写时，本地源码仓库已被删除，因此未重新直接读取历史 run 日志文本，但相关构建链路和源码配置已重新核对无误。

七、项目当前技术实现重点
1. 初始化与环境安装
应用首次启动会经过 splash、onboarding、setup_wizard 等页面，最终由 Android 原生层拉起 Ubuntu rootfs、Python 环境、Hermes Agent 所需依赖与仓库。

2. 聊天链路
聊天页面位于 flutter_app/lib/screens/chat_screen.dart。
聊天服务位于 flutter_app/lib/services/chat_service.dart。
前端通过本地 API server 与 Hermes 通信，使用流式方式接收消息。

3. 过程区与最终回复区分流
这是整个项目长期最难问题之一，直到 0.3.10 才真正稳定解决。
当前修复不是单靠系统提示词，而是结合了以下几层：
SSE 流式事件解析。
标签拆分 assistant_process 与 assistant_final。
工具调用事件收集。
启发式分流兜底。
非流式 fallback 拉最终答复。
从而避免模型把过程内容混入最终答复区，或最终区为空。

4. 附件链路
聊天页支持：
拍照。
从图库选图或选视频。
从文件选择器选择文件。
附件会先落盘，再把精确路径附加到消息上下文里，引导智能体去访问该实际路径。

5. 会话管理
聊天页具备会话历史管理入口。
支持：
查看所有 session。
点击进入历史会话。
长按后修改标题。
删除会话。
导出会话。
打开聊天页自动恢复到上一次 session。

6. 多模型管理
这是 0.3.12 的最新重点功能。
原先“模型与 API 设置”只有一个页面、三个字段、只能覆盖保存单模型。
现在已升级为模型列表与创建编辑混合管理方式，支持多模型持久化。

八、截至 0.3.12 已完成的主要修复与功能增量
以下按时间顺序概述本轮重启接手后的真实开发脉络，依据 GitHub 提交历史和已知产物整理。

1. 2026-04-23 重启接手文档
提交：0f8e47002143c5fdd2a58fdc49661b199a890a37
标题：docs: add restart handover for clean rebuild
作用：标记“从头接手”的新起点。

2. 0.3.6 前后阶段的基础接手修复
提交：547a901b4971b6814a3cff4d6c039cc3f8b06760
标题：feat: add model settings + chat UI and fix bootstrap deps
作用：补上模型设置入口、基础聊天界面和初始化依赖修复，是后续所有版本的起点之一。

3. 签名回退修复
提交：ee1d84c81eb1165ca4850ac74d5bdfad938da129
标题：fix: correct CI keystore path to prevent debug-sign fallback
作用：修复构建流程 keystore 写入位置错误，避免错误落回 debug 签名。

4. 0.3.8 过程输出与图库选择修复
提交：d667fbe6e763a101dfc136ddb472985c6ec47724
标题：fix: split process output and use true gallery picker for attachments
作用：
增强聊天输出分流。
把“从相册选择”修正为真正调用图库图片或视频选择，而不是落回文件选择器。
工作流版本名固定为 0.3.8。

5. 0.3.9 无障碍与任务状态
提交：7b87e1e6756779f60f5d90d2eef9ecae113954e4
标题：feat: add accessible send-cancel flow and runtime status banner
作用：
发送按钮加入更好的可访问性语义。
发送中按钮切换为可取消。
聊天页顶部新增实时状态区，显示已就绪、执行中、完成、取消或异常。
工作流版本名固定为 0.3.9。

6. 0.3.10 测试版并行安装与核心分流稳定化
提交：32b8b3580671423a1f8fec3b3a1df48541997ccc
标题：fix(chat): robust process/final split and SSE event parsing; build 0.3.10 test package
作用：
这是“过程区和最终回复区彻底分离”真正稳定的关键版本。
加入更稳健的 SSE 解析、过程/最终标签容错拆分、工具调用过程单独展示。
产出首个真正意义上的测试版并行安装包。

7. 0.3.11 正式版恢复原始包名
提交：dfc608d9ff582943533377f15976c7b931cabaf9
标题：release(android): restore prod package id and bump to 0.3.11
作用：
在确认测试版逻辑稳定后，把同一套功能回切到正式原始包名，用于覆盖更新正式版。

8. 0.3.12 多模型管理
提交：65d9c4f3e32162bbdc7c0c0f911201880d441c58
标题：feat(model-settings): add multi-model management with create/edit/delete/select/probe
作用：
将原来的单模型页面升级为完整的多模型管理入口。

九、0.3.12 最新实现的功能明细
1. 模型与 API 设置页面重构为模型管理入口
入口打开后不再直接显示单模型三字段表单，而是进入模型列表页。

2. 顶部新增创建模型按钮
用户可以手动创建新模型。

3. 创建/编辑页保留并扩展了原有三字段能力
模型 ID。
端点 URL。
API 密钥。
并保留预设提供商、默认端点、取消和保存能力。

4. 已配置模型列表
页面下方显示已经保存的模型列表，而不是只能看到一个当前模型。

5. 当前模型切换
点击某个模型可将其设为当前使用模型，并立即应用回 Hermes 配置文件。

6. 编辑与删除
每个模型支持编辑和删除。

7. 测试连接
当前模型上方支持测试连接，用于验证端点与密钥是否可通。

8. 从提供商获取模型列表
如果端点支持模型索引，可拉取模型列表并供用户选择；如果提供商不支持，则提示继续手动填写。

9. 数据迁移
首次进入多模型管理页面时，会尝试从当前 Hermes 的单模型 config.yaml 和 .env 中迁移出第一个模型档案，避免老用户原有配置丢失。

10. 模型预设
在 model_settings_screen.dart 中已加入常见提供商预设，包括：
OpenRouter
Anthropic
Google Gemini
DeepSeek
Z.AI / GLM
Kimi / Moonshot
MiniMax
Alibaba / DashScope
Hugging Face
OpenAI Codex
Custom Endpoint

十、0.3.12 多模型管理的关键源码说明
1. flutter_app/lib/models/model_profile_models.dart
用途：定义 ModelProfile 和 ModelProfilesData。
内容包括：
模型名称。
provider。
modelId。
endpoint。
apiKey。
apiMode。
keyEnv。
创建时间与更新时间。
最近测试结果信息。

2. flutter_app/lib/services/model_profile_store.dart
用途：在 Flutter 应用文档目录下持久化 model_profiles_v1.json。
能力包括：
读取所有模型档案。
写回所有模型档案。
保存当前选中模型 ID。

3. flutter_app/lib/screens/model_settings_screen.dart
用途：完整的模型管理页面实现。
核心能力包括：
预设提供商定义。
从 Hermes 当前配置迁移旧单模型配置。
创建模型。
编辑模型。
删除模型。
切换当前模型。
测试连接。
从端点拉取模型列表。
保存后应用回 Hermes config.yaml 与 .env。

十一、目前仍需要注意的已知事实
1. 本地源码仓库已删
下一次继续开发前，如需本地修改源码，要重新从云端克隆 main 或测试分支。

2. 当前继续开发的推荐基线
如果目标是继续正式版迭代，应从 main 的 65d9c4f 开始。
如果目标是先做并行验证，应从 build/testpkg-0.3.12-20260425 的 904d35e 开始。

3. 测试版与正式版并行策略
后续如果继续采用“双包验证”策略，建议始终先在测试分支只改包名和桌面标题，再构建测试版验证通过后回切到正式包名并产出正式版。

4. 签名相关高风险点
后续任何工作流改动、keystore 路径改动、key.properties 写法变动，都可能重新触发 debug fallback，从而再次造成无法覆盖更新。
必须重点核对：
.github/workflows/flutter-build.yml
flutter_app/android/app/build.gradle

十二、后续继续开发时的推荐操作顺序
1. 先确认本地是否需要重新克隆仓库。
2. 如果继续正式版，克隆 main 分支。
3. 如果需要先并行测试，基于 main 创建新的 test 包分支，只修改 applicationId 和 AndroidManifest 应用名。
4. 修改代码后，先构建测试版。
5. 手机端验证不影响旧功能后，再回切正式包名构建正式版。
6. 每次产出 APK 后都把正式版、测试版、当前唯一安装包和历史归档同时落盘到：
/sdcard/下载管理/HermesAgentMobile项目改造
/sdcard/下载管理/HermesAgentMobile项目改造/历史安装包

十三、当前本地 APK 资产清单
当前目录：
/sdcard/下载管理/HermesAgentMobile项目改造
已存在：
HermesAgentMobile-v0.3.12-原始版-可覆盖更新.apk
HermesAgentMobile-v0.3.12-测试版-并行安装.apk
HermesAgentMobile-当前唯一安装包.apk
子目录 历史安装包

历史归档目录当前可见文件：
HermesAgentMobile-20260423T142233Z.apk
HermesAgentMobile-previous-20260424T001946Z.apk
HermesAgentMobile-previous-20260424T031552Z.apk
HermesAgentMobile-previous-20260424T043250Z.apk
HermesAgentMobile-previous-20260424T131055Z.apk
HermesAgentMobile-previous-20260424T143536Z.apk
HermesAgentMobile-previous-20260425T043954Z.apk
HermesAgentMobile-run24837404974.apk
HermesAgentMobile-run24839442391.apk
HermesAgentMobile-run24865286342.apk
HermesAgentMobile-run24870070138.apk
HermesAgentMobile-run24872028511.apk
HermesAgentMobile-run24890859318-v0.3.10-test.apk
HermesAgentMobile-run24894671072-v0.3.11.apk
HermesAgentMobile-run24922578879-v0.3.12-prod.apk
HermesAgentMobile-run24922589309-v0.3.12-test.apk

十四、下一位接手者最重要的结论
1. 不要假设本地还有源码，当前应以云端仓库为准。
2. 继续正式开发请从 main 的 65d9c4f 开始。
3. 继续测试并行包请从 build/testpkg-0.3.12-20260425 的 904d35e 开始。
4. 0.3.12 已经完成多模型管理，正式版和测试版功能应一致。
5. 过程区与最终回复区分流问题在 0.3.10 已经基本攻克，不要轻易重写 chat_service.dart 的核心分流逻辑。
6. 签名稳定性的核心修复点在工作流和 build.gradle，后续任何改动都必须优先回归验证覆盖更新。

十五、为下一次新会话准备的最短指令建议
在新会话中，让接手者先读取本文件，然后按文档中的云端分支、提交 SHA、APK 路径和架构说明继续开发，不要依赖历史上下文记忆。
