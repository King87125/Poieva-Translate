# 自定义配置 / Custom configuration

[English overview](../README.md) · [中文介绍](../README.zh-CN.md)

本文对应 v0.3.0。术语库、语气与场景的导入导出请见[翻译方案](profiles.md)，与本页的服务配置分开。

## 免费使用苹果翻译

默认使用苹果系统翻译，无需注册、密钥或自定义配置。首次使用时下载对应语言包，之后在本机翻译。在「设置 → 系统 → 语言包」管理语言包。

Poieva 当前不提供服务商套餐、品牌模板或模型推荐目录。需要在线翻译时，可以添加自己的配置；在线服务的收费和额度由用户选择的服务商决定。

## 添加自己的配置

打开「设置 → 模型管理 → 添加」，选择一种通用类型：

| 类型 | 需要填写 | 用途 |
| --- | --- | --- |
| 自定义 AI | 名称、服务地址、模型 ID、所需密钥 | 翻译；远程 HTTPS 模型也可作为上下文辅助 |
| 自定义 HTTP 翻译 | 名称、完整接口地址、请求与响应定义、所需密钥 | 翻译 |

**自定义 AI** 使用 OpenAI 兼容的 Chat Completions 协议。这是协议格式，不绑定某一家服务商。地址可以是基础地址（如 `https://api.example.com/v1`）或完整的 `/chat/completions` 地址。模型 ID 填写服务商提供的值。「高级参数」可填写额外请求参数 JSON，也可按接口要求开启 JSON 输出模式。当前不支持 Responses、Anthropic Messages 或自动获取模型列表。

**自定义 HTTP** 用于已有 POST JSON 接口。需要按接口文档填写请求正文、语言代码和译文响应路径；不能仅填写地址就适配任意接口。定义在「高级参数 → 接口模板 JSON」中编辑，示例见下节。需要 OAuth 刷新、签名计算、GET、表单、XML 或流式响应的接口，留待后续统一适配。

远程地址必须使用 HTTPS；HTTP 仅支持本机回环地址。保存后可点「测试连接」，测试使用公开短句并会向该地址发送请求。

已有版本保存的配置继续保留和使用，不会因本次精简被删除。旧专业服务类型只在编辑已有配置时显示，新增窗口不再列出品牌服务。

## 使用和切换

- 在模型管理中设定默认翻译服务，供全局「翻译并替换」和「翻译预览」使用。苹果翻译始终可选。
- 在工作台右上角勾选一个或多个已配置服务；选几个就显示几个，各自显示结果和失败状态。这里的选择不改变全局默认服务。
- 上下文辅助独立选择自己的远程 AI 配置。默认不启用辅助；专业 HTTP 接口不承担辅助模型的作用。

## 自定义 HTTP 定义

以下为协议示例，不是某个在线服务的现成模板。字段和语言代码应根据用户自己的接口文档调整。

```json
{
  "version": 1,
  "method": "POST",
  "authentication": "bearer",
  "request": {
    "text": "{{text}}",
    "source": "{{source}}",
    "target": "{{target}}"
  },
  "responsePath": "data.translatedText",
  "languageCodes": {"en": "en", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"},
  "maxCharacters": 2000
}
```

- `authentication` 支持 `bearer`、`header`、`none`。自定义请求头用 `keyHeader` 和可选的 `keyPrefix` 指定；密钥只填密钥栏。
- `request` 支持 `{{text}}`、`{{source}}`、`{{target}}` 和已定义的 `{{option.名称}}`；按 JSON 值转义，不执行脚本，不二次解析原文里的占位符。
- `responsePath` 使用点分路径，如 `data.translatedText` 或 `data.0.text`。可用 `successPath`、`successValue` 检查业务状态，用 `errorMessages` 定义错误码提示。
- `languageCodes` 将应用语言标识映射为接口要求的语言代码；`sourceLanguageCodes` 可单独覆盖源语言代码。
- `options` 可定义下拉选项，配置选项的当前值保存在服务级 `parameters`。候选值可覆盖语言代码。最多 8 个选项，每项最多 50 个候选值。
- 定义最多 32 KB，嵌套不超过 8 层；`maxCharacters` 是客户端分段上限（UTF-16 长度，1–20,000），并非服务商承诺的额度。任一分段失败不提交部分覆盖；取消后停止后续请求。

## 导入与导出

模型管理中可导入 JSON 配置，或导出选中配置、全部自定义配置。苹果内置翻译无需导出。当前导出格式为 v3，兼容导入旧版 v1/v2 文件。导入不切换默认服务，也不覆盖现有记录。

[`Examples/translation-services.json`](../Examples/translation-services.json) 只有占位地址和模型 ID，可用来了解文件格式；使用前换成自己的地址和模型。它不指向可调用的公共服务。

文件包含名称、协议、地址、模型和非秘密的参数定义，不包含密钥、本机配置 ID 或当前选择。密钥保存在本机钥匙串，不写入导出文件；导入到另一台 Mac 后，需要自行填入密钥。编辑已有配置时，密钥留空表示保留；明确勾选「清除已保存的密钥」才会删除。更换协议、地址来源、应用 ID 或鉴权方式时，需要重新填写或清除密钥。

## English

Apple Translate is the default and requires no account or API key. Download the language packs you need, then translation runs on your Mac.

To use your own service, open **Settings → Model Management → Add**:

- **Custom AI:** enter a name, base URL, model ID and any required key. Uses the OpenAI-compatible Chat Completions protocol. Remote HTTPS models can also be selected separately for context assistance.
- **Custom HTTP Translation:** enter your endpoint and define its POST JSON request, language codes and response path under **Advanced Parameters → HTTP template JSON**. An arbitrary API needs a matching definition; a URL alone is insufficient.

Poieva currently offers no provider presets or recommended model catalog. Configure your own account; pricing and limits depend on your chosen service. Existing saved configurations remain usable. Provider-specific choices from older versions appear only when editing an existing configuration.

Select a global default in Model Management. In the translation window, select any number of configured services to see their results separately. Import/export shares configuration without API keys; importing never changes your default service. Keys stay in the local macOS Keychain.

The [generic example](../Examples/translation-services.json) contains placeholder values, not a working public endpoint. Replace them with your own. POST JSON HTTP definitions are documented above; OAuth refresh, custom signatures, GET, form data, XML and streaming require future protocol support.

## 开发验收

`Tests/Fixtures` 中的协议样例仅用于回归验证，不是用户可导入的服务模板。可用本机固定样例验证传输、请求字段、旧格式兼容、取消和导入导出，不使用真实账户：

```sh
python3 scripts/mock-translation-service.py
```

另一个终端运行：

```sh
TYPEBRIDGE_TEST_SERVER_URL=http://127.0.0.1:19081/v1 ./scripts/test.sh
```

仅允许回环地址；测试完停止本机样例服务。旧版本的验证记录保留在 [verification.md](verification.md)。
