# 实时字幕 / Live Captions

Poieva 可以将应用播放的声音转换为文字，再使用现有翻译服务生成顶部双语字幕。入口在工作台右上角的字幕按钮、应用菜单和菜单栏的 **实时字幕…**。

## 开始使用

1. 打开 **实时字幕 → 语音识别 → 配置…**。在模型管理的「语音识别」页添加自己的服务名称、实时转写地址、转写模型 ID 和密钥。语音识别配置与「翻译与辅助」配置分开；原有翻译服务和密钥不变。
2. 点「检查连接」可验证转写会话是否就绪，不会采集声音。保存后回到字幕窗口，选择该识别服务。
3. 选择 **全部系统声音** 或一个正在运行的应用。浏览器按整个应用采音，首版不区分标签页。可以选择包含自己的麦克风，此时增加一路独立识别连接。
4. 选择苹果或已配置的翻译服务，以及原文/目标语言。原文语言用于翻译方向；识别接口自行识别输入语音。字幕使用当前翻译场景的术语与语气；全局上下文开启时，仅传入之前的字幕作为参考。
5. 点 **开始字幕**。首次采集需要用户在 macOS 确认系统音频录制权限；开启麦克风时还需要麦克风权限。只预览提词器或测试音频文件不需要录制桌面声音。

字幕在主屏幕顶部中央展开，有刘海时接在刘海下方。默认显示最近两句，原文小字、译文大字；原文可关闭，字号和显示屏可调整。部分识别文字先显示，只有最终确定的句子才触发翻译，避免每个字都重复发送。

![顶部提词器的离线样例预览](images/live-captions-zh.jpg)

*实机提词器窗口截图，内容为公开预览样例；不代表会议采集或真实语音识别质量。*

鼠标移入字幕区后显示暂停、设置、收起和停止按钮；右键也可以打开操作菜单。暂停立即关闭采音和识别连接，保留已有字幕；停止同时清空本次字幕并关闭提词器。关闭设置窗口仍可显示字幕，在应用菜单重新打开设置即可操作。窗口支持 Command + W 关闭。

## 先看效果和测试接口

- **预览提词器** 或「测试 → 预览提词器（不联网）」显示公开样例和滚动效果，不使用网络、麦克风或系统录音权限，界面明确标为「样例预览」。
- **测试 → 测试音频文件…** 会将用户选择的音频发送给所选识别 API，再使用所选翻译服务。支持 WAV、AIFF、MP3、M4A，最多 60 秒；这会产生所选服务的实际用量。测试完成并收到最终翻译后自动暂停连接。不要把它当成离线预览。

## API 要求

首版适配 **Realtime transcription 兼容 WebSocket 接口**。它是专门的语音转写接口；文字 Chat Completions 地址、普通 HTTP 翻译接口或任意一个聊天模型不会自动获得语音识别能力。服务商需要兼容下列协议，不能仅凭「支持音频」就认定可用。

- 地址可填写完整的 `wss://api.example.com/v1/realtime`，也可填 `https://api.example.com/v1`，应用会转换并添加 `/realtime?intent=transcription`。非标准路径按填写的路径使用。远程要求 WSS；明文 WS 只允许 localhost/回环地址用于开发。
- 密钥通过 `Authorization: Bearer …` 请求头传递，不支持把密钥写入 URL。更换服务来源时需要重新填写或清除旧密钥。密钥保存在既有的固定钥匙串组件中，不写入配置偏好。
- 客户端发送 `session.update`，会话类型为 `transcription`；转写模型由用户填写。输入为 24 kHz、单声道、小端 PCM16，关闭服务端分句，按 200 ms 音频包发送。
- 收到匹配转写模型的会话确认后才开始采音。客户端用轻量能量门限识别停顿，在约 600 ms 静音或最长约 8 秒时提交一段；这不是本地 AI 模型。
- 服务需支持 `input_audio_buffer.append`、`input_audio_buffer.commit` 和对应的增量/完成事件。客户端按 `item_id` 匹配原文和译文，处理乱序及重复结果。

协议依据：[OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)。例如官方文档中的转写模型也需要对应账户权限；此处不提供品牌预设，也不保证其他服务声称兼容就能使用。

## 隐私和运行方式

声音只在用户开始后采集，并发送至其选择的识别服务；识别文字交给所选翻译服务。苹果基础翻译仍使用本机已有语言包；选用 AI 翻译或场景辅助时，文字会进入对应 API。服务端如何留存及计费由各服务决定。

Poieva 不将音频或字幕写入历史、日志或配置文件。内存中只保留有限音频包、近期字幕和有限待译队列。暂停和停止会取消请求并丢弃迟到结果；断线、无效返回、翻译失败或队列跟不上时暂停并显示错误，需用户手动再次开始，不自动重连或重试计费请求。电脑休眠或桌面会话停用时暂停。

系统采音采用 macOS Core Audio tap，不安装虚拟声卡，不更改系统默认输入输出设备，不静音原应用。麦克风与系统声音分别识别，避免将两个音频时钟直接混合。音频格式变化时停止并提示重新开始。[Apple 音频采集说明](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

## 当前验收范围

已通过客户端协议、取消、乱序、重复、失败停止、缓冲上限和密钥来源隔离检查；原生 UI 使用公开合成音频、本机固定识别响应和真实苹果翻译验证。

![公开音频测试的识别原文与实际苹果翻译](images/live-captions-audio-test-zh.jpg)

*识别原文由本机固定协议样例返回，中文来自实际苹果翻译。文件测试完成后自动暂停并关闭连接。*

本机样例不是语音识别模型，不能证明识别准确率或云端延迟。按用户安排，真实语音 API 稍后配置；腾讯会议、飞书、浏览器的实际声音采集、音频设备切换、长时间运行、全屏与多屏组合仍需在用户授权的公开测试中逐项验收。受保护视频的声音可能无法采集，首版不承诺所有视频或会议应用兼容。

## English

Open **Live Captions** from the translation window’s toolbar or the app/menu-bar menu. Add your own speech recognition endpoint under **Model Management → Speech Recognition**, then select an audio source, your translator and target language. Speech configurations are separate from existing text translation and assistant configurations. The first release requires a **Realtime transcription-compatible WebSocket API**, with transcription sessions, 24 kHz mono PCM16 input and manual turn commits. A text-only model or ordinary translation endpoint is not sufficient.

Start captions to request system audio recording permission; optionally include your microphone as a separate recognition connection. A dark teleprompter expands below the notch or at the top of a display without a notch. It shows recent source/translated text, supports collapse, pause, text size and display selection, and does not take keyboard focus. Translation reuses Apple or your existing configured service and the active scene. Browser audio is captured per application, not per tab.

**Preview Teleprompter** is an offline, explicitly labeled sample. **Test an Audio File** sends the chosen file to your selected recognition service and translator, accepts up to 60 seconds, and automatically pauses after the final result. Only final transcripts are translated. Pausing stops capture and closes sockets while retaining current text; stopping clears the session. No audio or captions are saved to history. Remote service retention and charges are governed by that service.

The client has bounded buffers and translation queues, correlates results by item ID, and rejects late results after cancellation. Errors pause the session without automatic retries or reconnects. Recognition does not run a local AI model. The audio tap does not replace default audio devices or install a virtual driver.

Validation used public synthetic audio, a fixed loopback WebSocket response and real Apple translation. This checks the application pipeline, not speech recognition quality. Real speech APIs, Tencent Meeting/Lark/browser capture, long sessions and device/display combinations remain subject to user configuration, permission and live testing. See [verification notes](verification.md).
