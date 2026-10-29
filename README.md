# Poieva Translate

![Poieva Translate](Resources/Branding/Poieva-Icon-256.png)

**[下载安装包 · v0.1.0 预览版](https://github.com/King87125/Poieva-Translate/releases/download/v0.1.0/Poieva-Translate-0.1.0.dmg)** · [发布说明](https://github.com/King87125/Poieva-Translate/releases/tag/v0.1.0)

支持 **Apple Silicon（M 系列芯片）· macOS 26.0 及以上**，内置 English / 简体中文界面。打开 DMG 后将应用拖入 Applications，首次打开时选择界面语言。当前安装包使用本地开发签名，尚未经过 Apple Developer ID 签名与公证，属于开发预览版。

Poieva 系列的 macOS 菜单栏翻译工具，原名「译入 TypeBridge」。第一版只聚焦输入框翻译和选中文字翻译，附带一个方便调试、随手翻译的翻译窗口。

系列品牌为 **Poieva**，本产品名称为 **Poieva Translate**。更名保留原应用标识、设置域、配置格式、固定签名和完整密钥组件，以沿用已有服务、密钥与快捷键；内部 Swift 模块和兼容标识继续使用 TypeBridge。应用包现为 `dist/Poieva Translate.app`，构建脚本会从旧包接续构建号并迁移，不另外留下第二份应用。

## 第一版功能

- **输入框翻译**：按 `⌃⌥Return`，有选区时只翻译并替换选中部分，没有选区时翻译整个输入框。不会自动发送；可在原应用按 `⌘Z` 撤销粘贴。
- **选中文字翻译**：选中可复制的文字，按 `⌃⌥D`，在独立小窗口查看译文；可复制结果，原文不变。需要直接替换选中部分时，使用「输入框翻译」快捷键。
- 两种功能默认使用**中英自动互译**：中文转英文，英文转简体中文；也可以分别切换为「指定目标语言」。方向根据本次选中文字或整框文字判断。翻译窗口沿用输入框翻译的方向设置。
- **翻译窗口自动翻译**：输入或粘贴完成、停顿约 0.55 秒后翻译；中文输入法组字期间暂停，选词提交后再计时。翻译期间仍可继续输入，旧结果不会覆盖新文本；删除或清空原文会同步清空译文。按钮或 `⌘Return` 可立即翻译。
- **保留原文格式**：换行、缩进、Markdown 标题、列表和表格标记不交给翻译服务改写。能够读取 HTML 或 RTF 时，只替换文字，携带原有标题、列表、加粗、字号等样式回填或复制；无法可靠读取格式时保留译文，不自动用纯文本覆盖原文。
- 在「设置」顶部点击对应快捷键旁的「修改」，按一次自己的组合键即可自动保存，也支持单独使用 F1–F20 功能键和一键恢复默认。界面用 Control、Option、Command 等完整名称显示按键。
- 默认使用 Apple Translation，不需要 API 密钥或翻译订阅；首次需要在应用内允许准备系统语言包，之后在设备端翻译。也可按服务类型添加 DeepL、百度通用翻译、有道文本翻译，或 OpenAI Chat Completions 兼容模型，填写自己的账户配置。
- **工作台服务选择**：在右上角原生菜单直接勾选或取消服务，即时生效，不限勾选数量。一个服务显示一份译文，多个服务分别显示结果；全部取消时暂停工作台翻译。各结果可独立复制与重试，某一路失败不影响其他结果。全局快捷键继续使用默认服务。
- **自定义 HTTP 翻译**：导入接口模板后填写自己的密钥，支持 POST JSON、Bearer/自定义密钥请求头、语言代码映射、译文字段路径和模板下拉选项。附带[灵动翻译模板](Examples/lingdong-http.json)，可选择 DeepL、Google、百度、有道引擎。
- **服务管理与配置分享**：在「设置 → 模型管理 → 管理…」添加、编辑、删除、测试或切换服务，导入/导出 JSON 配置。密钥保存到系统钥匙串，导出文件不包含密钥；导入不会自动启用、覆盖已有配置或发起网络请求。
- 默认保留反引号内代码、Markdown 代码块和网址，可在设置中关闭。
- 在「设置 → 翻译提示」选择波浪圆点、打字机、简洁加载或翻译字数，可预览加载与失败状态，或播放实际浮窗。加载仅显示小动效，圆点/转圈为 44×28；不显示成功、取消或无需替换通知。跨应用提示显示在输入位置附近，无法取得位置时使用鼠标附近；只有失败保留原因与操作入口。字数按真实返回的正文更新。
- 「你好」「您好」等简繁共有的短中文默认按简体识别，避免误报不支持；繁简转换在本机完成，无需下载翻译模型。
- 翻译期间切换应用、输入框、修改文字或移动已知选区，会停止自动回填并保留结果。
- 按编辑控件能力处理原生输入框与网页输入框；必要时请求目标应用启用辅助功能接口。分块编辑器优先使用局部选区，无法确认范围时提示改用选中文字翻译，避免误选整页。
- 不存储翻译历史，不监听日常打字，只在快捷键触发时读取目标文字。

## 打开使用

当前构建产物：`dist/Poieva Translate.app`，双击打开。也可用 `./scripts/package-dmg.sh` 生成 `dist/Poieva-Translate-0.1.0.dmg`，打开后将应用拖入 Applications。需要 **macOS 26.0 或更高版本**；当前开发机为 Apple Silicon。

首次打开会显示 **English / 简体中文** 语言选择，之后记住所选语言。已有用户更新后也会选择一次；可随时在「设置 → 通用设置 → 界面语言」修改，重新打开应用后生效。界面语言覆盖工作台、菜单、设置、模型管理、预览、提示与错误信息，与原文/目标语言分开保存，不修改模型、密钥、术语或翻译方向。DMG 是拖拽安装盘，语言选择出现在应用首次启动时。原生打开/保存对话框在后续启动时也使用所选语言。

1. 在「设置 → 系统 → 语言包」查看状态。「已安装」或「可用」可直接翻译，无需重新选择或下载；确实缺少语言包时，再点「管理… → 下载语言包」并按系统提示完成。
2. 在「设置 → 系统 → 辅助功能」点击「系统设置…」，在系统设置中给 **Poieva Translate** 授权。翻译窗口不需要辅助功能权限。
3. 回到 Codex 或其他应用的输入框写好中文或英文，保持光标在原处，按 `Control + Option + Return` 翻译整框。只想替换一段时，先选中那一段，再使用同一快捷键。
4. 只想看译文时，选中文字后按 `Control + Option + D`，在小窗口查看。以上为默认快捷键，已保存的自定义按键会保留。

关闭翻译窗口后应用仍常驻菜单栏；从菜单栏可以重新打开设置或退出。更换语言后优先复用已安装的翻译能力，确实缺包时才需要下载。简体与繁体中文可通过本机文字转换共用已安装的中文模型，原文、格式和要求的译文书写形式保持不变。第三方特殊输入框的兼容性需逐一实测；无法读取时可以尝试选中文字翻译，或将文字粘贴到翻译窗口。当前实现与各应用的验证状态见[兼容性说明](docs/compatibility.md)。

本地构建现在复用固定的本机开发签名。首次准备的证书和独立签名钥匙串保存在 `.typebridge-signing/`，目录已加入忽略列表，不打包进应用；请保留并妥善备份，不提交或分享私钥及签名钥匙串密码。构建以「应用标识 + 固定证书指纹」识别同一应用，更新前校验身份连续性；签名材料缺失或改变时停止构建，不会静默退回临时签名。初始证书设置仅在当前用户下允许代码签名工具验证这张证书，私钥仅供 `/usr/bin/codesign` 使用，不配置网站证书或系统根信任。对外分发仍需正式开发者签名与公证。

旧临时签名首次转到固定签名属于一次身份迁移，已有系统权限或旧钥匙串记录可能需要最后确认一次；后续正常更新继续复用这一身份。下载权限和辅助功能权限由用户在系统界面确认，应用不会修改系统隐私开关。

### 自定义翻译服务

在「设置 → 模型管理 → 管理…」点击「添加…」，先选择服务类型：DeepL 填写 API Key 并选择对应 API 地址；百度填写 APP ID 和密钥；有道填写应用 ID 和应用密钥；OpenAI 兼容类型填写服务地址、模型 ID 和所需密钥。本机免鉴权模型可留空密钥。「测试连接」会发送一条固定短句，可能产生服务商用量；保存后可选中服务并点「设为默认翻译」。工作台右上角也能直接勾选服务：仅选一个时会更新默认服务，选多个就分别显示各自译文。全局快捷键始终使用默认服务；多选状态不随配置导出，也不在重启后恢复。

专业翻译服务使用各自官方协议，自动处理语言代码、鉴权和长文本分批；继续保留原文格式。Chat Completions 兼容模型需能按要求返回 JSON 译文。分享配置时可导出选中服务或全部自定义服务，收到配置后先检查服务地址、将应用 ID 改为自己的并补填密钥，再选择使用。新版本导出 v3 格式，仍可导入原有 v1/v2 配置。配置格式、限制与扩展方式见[服务配置说明](docs/services.md)，可参考[专业服务示例](Examples/professional-services.json)和[原有模型示例](Examples/translation-services.json)。

### 使用灵动翻译模板

在「设置 → 模型管理 → 管理… → 导入…」选择 [`Examples/lingdong-http.json`](Examples/lingdong-http.json)。选中导入的「灵动翻译」并点「编辑…」，选择翻译引擎、填写自己的 API Key、保存，再从工作台的服务菜单勾选它。模板默认 Google，另可选 DeepL、百度和有道；接口格式、语言映射和错误提示已预置，不需要填写 AI 模型名称。密钥不会随配置导出。

本次按[服务方文档](https://gg.ldfy.cc/APIDocument)编写模板，并通过本机模拟接口验证；尚未使用真实灵动账户验证额度、权限或在线翻译质量。

### OpenRouter 免费 Nemotron 模型

在「模型管理 → 导入…」选择 [`Examples/openrouter-nemotron-free.json`](Examples/openrouter-nemotron-free.json)，编辑导入的配置，填写自己的 OpenRouter API Key 后保存。地址为 `https://openrouter.ai/api/v1`，模型为 `nvidia/nemotron-3-ultra-550b-a55b:free`，可用于翻译和辅助；导入不会自动启用或发送请求。

填写密钥并点「保存」即可使用，没有独立的「授权密钥」步骤。密钥由应用内的固定 XPC 组件保存在系统钥匙串，读取后仅在当前进程内复用，不写入配置文件或导出包。应用与组件相互校验标识和签名证书，组件仅供同一应用及当前用户调用。保存已有配置时会将旧记录迁移至 v3；首次迁移可能需要一次系统确认，等待发生在后台，普通读取不反复弹窗。

迁移先写入新记录、再清理旧记录；写入失败保留旧记录。已完成迁移或主动清除的密钥不会再回退到旧副本。若旧副本因系统权限暂时不能删除，它仍受旧钥匙串保护，应用也不会再次使用它。普通主应用更新原样保留密钥组件及其文件指纹；组件代码变化会阻止默认发布，需另行安排组件自身的迁移验证。

构建 47–49 已用现有 OpenRouter 密钥验证完整重启与连续更新，无需重新填密钥或再次确认。固定证书本身不足以处理登录钥匙串的文件指纹分区，修复依赖保留固定密钥组件。完整 206 项自动检查通过；六项真实上下文回归为 5 通过、1 失败，省略主语仍有模型错误，详见 `docs/verification.md`。

模板关闭推理、限制输出为 4,096 token，不设置其他模型作为回退。按 2026-10-28 公开接口信息，该端点没有声明支持 `response_format`，因此关闭「JSON 输出模式」，依靠翻译提示词要求 JSON，客户端继续严格校验结果。无需运行示例里的 JavaScript 或保存多轮 `reasoning_details`，每次翻译是独立请求。免费名额有请求限额，实际额度以账户和[官方限制说明](https://openrouter.ai/docs/api_reference/limits)为准；已用公开短句验证真实连接和上下文辅助流程；尚未做系统性的质量与速度评测。

[该免费端点说明](https://openrouter.ai/nvidia/nemotron-3-ultra-550b-a55b:free)提示会记录会话数据，请使用公开测试文字，不用于私人聊天、个人资料或工作机密。待译片段、附近上下文和相关偏好都会发送给所选模型服务；`store: false` 不代表服务商不留存日志。

### 开关已开启，应用仍提示未授权

开发期间更新程序会改变临时签名。macOS 可能仍保留旧版本的授权记录，导致系统开关显示开启，但当前应用的权限检查仍返回未授权。

1. 完全退出 Poieva Translate。
2. 在「系统设置 → 隐私与安全性 → 辅助功能」选中 Poieva Translate（旧记录可能仍显示 TypeBridge），点击 `−` 移除旧记录。
3. 点击 `+`，按 `Command + Shift + G`，定位当前项目的 `dist/Poieva Translate.app`，重新添加并开启。
4. 重新打开 Poieva Translate，检查设置页的辅助功能是否显示「已开启」。

不需要额外授予录屏或完全磁盘访问权限。默认的「中英自动互译」无需手动切换方向；翻译其他语言时，在「设置 → 翻译方向」选择「指定目标语言」。开发环境有稳定的开发者签名后，可以通过 `TYPEBRIDGE_SIGN_IDENTITY` 配置构建脚本，减少版本更新引起的授权变化。

## 上下文与个人偏好

「设置 → 翻译偏好」可以开启附近上下文、选择辅助模型、设置表达风格与固定术语。偏好可按译文语言应用，保存在本机；当前版本只保存明确填写的偏好，不自动收集聊天记录或训练模型。

选中翻译时，从同一个编辑控件读取附近文字，每侧最多 600 字；无法确认范围或读不到时不补取其他页面。没有选区时仍翻译整个输入框。工作台可点「上下文…」手动填写前文和后文，便于在不授权其他应用的情况下测试；上下文只存在本次会话中，不参与翻译或回填，清空原文时一并清空。

AI 翻译服务在原有的一次请求中使用上下文和偏好。苹果及专业翻译需另选辅助模型，在初译后最多调用一次；未选择时维持基础翻译，界面提示偏好尚不能生效。辅助调用失败、不完整或擅自改动数字/受保护内容时不提交替换，原文保留。

预览中以小字显示本次是否读到前后文，以及「基础翻译 / AI 翻译 / AI 辅助」路径；悬停可查看字数和未能读取的原因。状态仅保留本次执行元数据，不保存原文或日志。「已传入前后文」表示请求包含参考文本，不承诺模型一定正确利用它。辅助阶段额外传入按阅读顺序排列的前文、选区与后文，再校正独立初译；原文明写的人称优先于参考。当前免费模型仍可能误判省略主语，已保留真实失败样例。

AI 请求会对保守识别的中英明确第一人称增加约束，结果丢失该人称时拒绝回填；复杂混合主语仍需模型和人工判断。仅有空行或空格的参考按无上下文处理，避免无意义的辅助调用。公开回归样例位于 `Tests/Fixtures/context-regressions.json`，可用 `python3 scripts/check-context-quality.py docs/context-quality-latest.json` 查看记录；脚本不会发网络请求，未运行和受阻样例不会算作通过。

辅助模型默认关闭，只能选择已配置的远程 OpenAI 兼容 API。「辅助模型 API → 管理…」可进入模型管理，填写自己的服务地址、模型 ID 和密钥。待译文字、附近上下文和相关偏好发送给选中的服务；无需安装本机推理程序或下载模型权重。本机只负责文字截取、偏好检索、结果校验、界面和回填。

已移除苹果设备端辅助模型和本机 Qwen 模板。旧的设备端选择会迁移为关闭；旧的本机 API 辅助选择也会停用，保留个人偏好，不自动改选其他远程服务。基础苹果翻译仍保留默认，它本身使用本机计算；要将基础翻译也交给远端，可在原有服务菜单选择翻译 API。

## 本地开发

需要支持 macOS 26 SDK 的 Swift 6 工具链，可使用 Xcode Command Line Tools，无第三方包依赖。

```sh
./scripts/build-app.sh
open "dist/Poieva Translate.app"
```

运行核心回归测试：

```sh
./scripts/test.sh
```

查询权限和中英文语言包状态，不修改系统设置：

```sh
"dist/Poieva Translate.app/Contents/MacOS/TypeBridge" --diagnose
```

命令行启动的诊断进程可能受到终端宿主的权限归属影响；运行中应用的实际辅助功能权限，以应用「设置」里的状态为准。

准备好语言包后，可运行真实翻译检查：

```sh
"dist/Poieva Translate.app/Contents/MacOS/TypeBridge" --smoke-translate
```

## 模块结构

```text
Sources/TypeBridgeCore/
  Language.swift                 语言、翻译请求、服务接口
  LanguageDetection.swift        中文识别与本机繁简转换
  TranslationDocument.swift      代码与链接保护、批量结果重组
  TranslationDirection.swift     中英互译与指定目标语言
  InputTranslationPolicy.swift   选区优先、局部替换校验
  HTMLTranslationDocument.swift  保留 HTML 标记并替换文字节点
  AttributedTranslationDocument.swift 保留 RTF 文字和段落属性
  WritebackPolicy.swift          回填前的状态校验
  EditorSelectionPolicy.swift    输入范围选择与局部选区验证
  ClipboardSnapshot.swift        多格式剪贴板快照与有条件恢复
  TranslationFeedback.swift      动效选项、真实字数进度与浮窗位置
  LiveTranslationController.swift 输入防抖、请求取消和迟到结果隔离
  WorkbenchComparisonController.swift 多服务独立请求、结果、取消与重试
  WorkbenchTextView.swift        原生占位绘制与输入法组字处理
  SelectionRestorer.swift        等待临时选区恢复确认，拒绝覆盖用户新选区
  TranslationServiceConfiguration.swift 服务类型、字段校验与版本化配置包
  TranslationServiceStore.swift  服务管理、当前选择与钥匙串凭据
  CompatibleTranslationProvider.swift Chat Completions 兼容服务适配
  ProfessionalTranslationProvider.swift DeepL、百度、有道协议与分批翻译
  TranslationHTTPClient.swift    共享网络会话、取消及重定向保护
  HTTPTranslationTemplate.swift  声明式 HTTP 模板、占位符与字段校验
  HTTPTranslationProvider.swift  自定义 POST JSON 请求、译文提取与取消
Sources/TypeBridge/
  AppleTranslationProvider.swift 系统翻译会话
  AccessibilityTextEditor.swift  跨应用焦点识别与编辑能力检测
  TextAccess.swift               辅助功能读取、剪贴板事务、键盘回填
  FormattedText.swift            格式捕获、译文格式与复制内容
  HotKeyManager.swift            全局快捷键
  ShortcutSettings.swift         自定义快捷键录入与校验
  ServiceSettings.swift          服务管理、连接测试与配置文件导入导出
  InterfaceControls.swift        统一选择器与配置输入框
  WorkbenchServices.swift        工作台服务多选与独立译文
  AppModel.swift                 操作流程、设置、取消与语言包准备
  AppDelegate.swift              菜单栏、主窗口、选中结果和状态提示
  Views.swift                    翻译窗口、设置、快速上手
  FeedbackView.swift             四种动效、状态提示和设置预览
  TranslationFeedback.swift     读取/翻译/替换/完成/取消/错误状态
```

后续新增协议需实现 `TranslationProvider` 并注册对应适配类型；已有服务管理、快捷键、文本获取和回填可复用。首版不包含 OCR、网页翻译、云端历史或 AI 提示词改写。

本项目没有复用 Bob、Easydict 或其他翻译工具的实现代码。
