# 实时字幕 / Live Captions

Poieva 可以将应用播放的声音转换为文字，再使用现有翻译服务生成顶部双语字幕。入口在工作台右上角的字幕按钮、应用菜单和菜单栏的 **实时字幕…**。

## 开始使用

1. 打开 **实时字幕 → 语音识别 → 配置…**。在模型管理的「语音识别」页添加配置，选择 **阿里云千问** 或 **Realtime 转写（兼容）**。阿里云默认填好模型与北京地域地址，只需填写对应地域的百炼 API Key；也可选择新加坡或填写业务空间专属地址。语音识别配置与「翻译与辅助」配置分开。
2. 点「检查连接」可验证转写会话是否就绪，不会采集声音。保存后回到字幕窗口，选择该识别服务。
3. 选择 **全部系统声音** 或一个正在运行的应用。浏览器按整个应用采音，首版不区分标签页。可以选择包含自己的麦克风，此时增加一路独立识别连接。
4. 选择苹果或已配置的翻译服务，以及原文/目标语言。原文语言用于翻译方向；识别接口自行识别输入语音。字幕使用当前翻译场景的术语与语气；全局上下文开启时，仅传入之前的字幕作为参考。
5. 点 **开始字幕**。首次采集需要用户在 macOS 确认系统音频录制权限；开启麦克风时还需要麦克风权限。只预览提词器或测试音频文件不需要录制桌面声音。

字幕在主屏幕顶部中央展开。有刘海时，黑色表面从屏幕顶缘连续展开；收起时，字幕图标和展开按钮位于刘海两侧。默认显示当前一句，原文小字、译文大字；原文可关闭，字号和显示屏可调整。部分识别文字先显示，只有最终确定的句子才触发翻译，避免每个字都重复发送。

![顶部提词器的离线样例预览](images/live-captions-zh.jpg)

*实机提词器窗口截图，内容为公开预览样例；不代表会议采集或真实语音识别质量。*

![收起后的刘海两侧字幕按钮](images/live-captions-collapsed-zh.jpg)

鼠标移入字幕区后显示暂停、设置、收起和停止按钮；右键也可以打开操作菜单。暂停立即关闭采音和识别连接，保留已有字幕；停止同时清空本次字幕并关闭提词器。关闭设置窗口仍可显示字幕，在应用菜单重新打开设置即可操作。窗口支持 Command + W 关闭。

### Mac 顶部显示与系统灵动岛

这是一块使用官方 AppKit 窗口和显示屏几何接口实现的顶部字幕界面，并非 iPhone 的系统 Dynamic Island 组件。苹果在 Mac 上提供的 Live Activities 是从配对 iPhone 同步到菜单栏的实时活动；Poieva 的本机语音字幕采用独立的顶部窗口，不依赖 iPhone。刘海尺寸和位置通过 `NSScreen.safeAreaInsets`、`auxiliaryTopLeftArea` 和 `auxiliaryTopRightArea` 获取，不写死某款 Mac 的尺寸。

参考：[Apple Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities)、[NSScreen 安全区域](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)、[刘海左侧可用区域](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc)。

## 先看效果和测试接口

- **预览提词器** 或「测试 → 预览提词器（不联网）」显示公开样例和滚动效果，不使用网络、麦克风或系统录音权限，界面明确标为「样例预览」。
- **测试 → 测试音频文件…** 会将用户选择的音频发送给所选识别 API，再使用所选翻译服务。支持 WAV、AIFF、MP3、M4A，最多 60 秒；这会产生所选服务的实际用量。测试完成并收到最终翻译后自动暂停连接。不要把它当成离线预览。

## API 要求

目前支持两类专门的语音转写接口。文字 Chat Completions 地址、普通 HTTP 翻译接口或任意一个聊天模型不会自动获得语音识别能力。

### 阿里云千问

- 服务类型选 **阿里云千问**，默认模型 `qwen3-asr-flash-realtime`。北京默认地址为 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`，新加坡为 `wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime`。这两个旧域名仍获官方支持；也可填写官方推荐的 `wss://业务空间ID.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime` 或对应新加坡专属地址。密钥必须与地域对应。
- 应用自动添加 `?model=模型ID`，使用 Bearer 鉴权；输入为 16 kHz、单声道、小端 PCM16，按 200 ms 音频包持续发送，包含静音。
- 使用服务端 VAD 分句，停顿阈值 400 ms，不发送客户端手动 commit。每条客户端事件具有独立 `event_id`。先验证服务确认的模型、格式和分句模式，之后才采音。
- 阿里云的 `text + stash` 是当前句的完整草稿，用新内容替换旧草稿，避免累加重复。最终 `completed` 结果才触发翻译。音频文件发送完后通过 `session.finish` 收尾，等待 `session.finished` 与最后一句翻译完成，再自动暂停；用户手动暂停/停止仍立即取消。

官方依据：[WebSocket 接入与地域地址](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-interaction-process)、[客户端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-server-events)。

### Realtime 转写（兼容）

这一类型保留原有 Realtime transcription 协议，不会改变已保存的旧配置：

- 地址可填写完整的 `wss://api.example.com/v1/realtime`，也可填 `https://api.example.com/v1`，应用会转换并添加 `/realtime?intent=transcription`。非标准路径按填写的路径使用。远程要求 WSS；明文 WS 只允许 localhost/回环地址用于开发。
- 密钥通过 `Authorization: Bearer …` 请求头传递，不支持把密钥写入 URL。更换服务来源时需要重新填写或清除旧密钥。密钥保存在既有的固定钥匙串组件中，不写入配置偏好。
- 客户端发送 `session.update`，会话类型为 `transcription`；转写模型由用户填写。输入为 24 kHz、单声道、小端 PCM16，关闭服务端分句，按 200 ms 音频包发送。
- 收到匹配转写模型的会话确认后才开始采音。客户端用轻量能量门限识别停顿，在约 600 ms 静音或最长约 8 秒时提交一段；这不是本地 AI 模型。
- 服务需支持 `input_audio_buffer.append`、`input_audio_buffer.commit` 和对应的增量/完成事件。客户端按 `item_id` 匹配原文和译文，处理乱序及重复结果。

协议依据：[OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)。例如官方文档中的转写模型也需要对应账户权限；其他服务声称兼容时，仍需检查具体协议。

## 腾讯会议自测

1. 在模型管理中为阿里云配置点 **检查连接**，成功后保存。该按钮只验证会话，不采音，也不证明语音识别质量。
2. 在腾讯会议创建自己的测试会议，用手机作为第二个参会端加入。电脑端麦克风静音，手机端读公开例句；让电脑端能听到来自手机的会议声音。
3. Poieva 的声音来源选 **腾讯会议**，翻译服务选 **苹果系统翻译**，目标语言设为 **简体中文**。先关闭「同时识别我的麦克风」，单独验证会议传来的声音。
4. 点 **开始字幕**，首次录音权限由你在 macOS 中确认。手机端读：`Today's meeting is about the project timeline. We plan to finish the first version next Friday.` 检查顶部是否先出现英文，再出现对应中文。
5. 单人会议没有远端声音。只有一台设备时，可勾选 **同时识别我的麦克风** 做本人语音测试，但这验证的是独立麦克风路径，不能据此认定腾讯会议的对方声音已通过。
6. 测试后点 **暂停** 或 **停止** 关闭采音与 API 连接。若有问题，反馈界面错误和声音来源即可。

## 隐私和运行方式

声音只在用户开始后采集，并发送至其选择的识别服务；识别文字交给所选翻译服务。苹果基础翻译仍使用本机已有语言包；选用 AI 翻译或场景辅助时，文字会进入对应 API。服务端如何留存及计费由各服务决定。

Poieva 不将音频或字幕写入历史、日志或配置文件。内存中只保留有限音频包、近期字幕和有限待译队列。暂停和停止会取消请求并丢弃迟到结果；断线、无效返回、翻译失败或队列跟不上时暂停并显示错误，需用户手动再次开始，不自动重连或重试计费请求。电脑休眠或桌面会话停用时暂停。

系统采音采用 macOS Core Audio tap，不安装虚拟声卡，不更改系统默认输入输出设备，不静音原应用。麦克风与系统声音分别识别，避免将两个音频时钟直接混合。音频格式变化时停止并提示重新开始。[Apple 音频采集说明](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

## 当前验收范围

已通过客户端协议、取消、乱序、重复、失败停止、缓冲上限和密钥来源隔离检查；原生 UI 使用公开合成音频、本机固定识别响应和真实苹果翻译验证。

![公开音频测试的识别原文与实际苹果翻译](images/live-captions-audio-test-zh.jpg)

*v0.4.0 链路验收截图，当前顶部样式见上方预览图。识别原文由本机固定协议样例返回，中文来自实际苹果翻译。文件测试完成后自动暂停并关闭连接。*

本机样例不是语音识别模型，不能证明识别准确率或云端延迟。用户自行配置阿里云后实际反馈可用、速度可接受；具体声源和量化延迟尚未确认。腾讯会议远端音频、单独麦克风、飞书、浏览器、音频设备切换、长时间运行、全屏与多屏组合仍需分别记录验收。受保护视频的声音可能无法采集，首版不承诺所有视频或会议应用兼容。

## English

Open **Live Captions** from the translation window’s toolbar or the app/menu-bar menu. Under **Model Management → Speech Recognition**, choose **Alibaba Cloud Qwen** or **Realtime transcription (compatible)**, then select an audio source, your translator and target language. Speech configurations are separate from existing text translation and assistant configurations. A text-only model or ordinary translation endpoint is not sufficient.

For Qwen, the model and Beijing endpoint are filled in by default; enter your region's Model Studio API key, or select Singapore/use a workspace-specific endpoint. Qwen receives 16 kHz mono PCM16 with server VAD. Its corrected full-sentence previews replace earlier drafts. File tests send `session.finish` and wait for `session.finished` and the final translation before pausing. The original Realtime-compatible type keeps 24 kHz PCM16 and client-side turn commits; old configurations retain that type.

Start captions to request system audio recording permission; optionally include your microphone as a separate recognition connection. A continuous dark surface expands from the display edge around the notch, with compact controls on either side when collapsed. On displays without a notch, it appears below the menu bar. It shows the current source/translated sentence, supports collapse, pause, text size and display selection, and does not take keyboard focus. Translation reuses Apple or your existing configured service and the active scene. Browser audio is captured per application, not per tab.

The top display uses public AppKit window and screen-geometry APIs; it is not the system iPhone Dynamic Island. Apple's Live Activities on Mac are mirrored from a paired iPhone into the menu bar. Poieva's local captions do not require an iPhone.

**Preview Teleprompter** is an offline, explicitly labeled sample. **Test an Audio File** sends the chosen file to your selected recognition service and translator, accepts up to 60 seconds, and automatically pauses after the final result. Only final transcripts are translated. Pausing stops capture and closes sockets while retaining current text; stopping clears the session. No audio or captions are saved to history. Remote service retention and charges are governed by that service.

The client has bounded buffers and translation queues, correlates results by item ID, and rejects late results after cancellation. Errors pause the session without automatic retries or reconnects. Recognition does not run a local AI model. The audio tap does not replace default audio devices or install a virtual driver.

Validation used public synthetic audio, fixed loopback WebSocket responses and real Apple translation. This checks the application pipeline, not speech recognition quality. After configuring Alibaba Qwen independently, the user reported that it worked with acceptable perceived speed; the exact audio source and measured latency were not confirmed. To test Tencent Meeting's remote audio, join your own meeting from a second device, mute the computer microphone, select Tencent Meeting as the source and read the public English sample above from the other device. A single-person microphone test covers a separate input path. Long sessions and device/display combinations still need live testing. See [verification notes](verification.md).
