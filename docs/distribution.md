# 安装包、签名与开源许可 / Distribution

## 拖拽安装窗口

DMG 中左侧是 Poieva Translate，右侧是 Applications。将应用拖到 Applications 后，从应用程序目录打开。

打包脚本写入独立的 Finder 窗口设置：660 × 420、大图标、白色背景、固定的左右位置。它不依赖打包机器的 Finder 偏好或窗口排列，不需要运行 Finder 自动化。

```sh
./scripts/build-app.sh
./scripts/package-dmg.sh
```

首次打包会在 `.build/dmg-tools` 安装固定版本并校验哈希的 `ds-store` 与 `mac-alias`，仅用于生成 Finder 元数据，不随应用分发。仓库及应用资源中都附有 MIT `LICENSE`。

## 为什么 macOS 仍提示无法验证

当前公开预览版使用固定的本机开发签名，**尚未完成 Developer ID 分发签名和 Apple 公证**。打包窗口和图标排版不改变 Gatekeeper 的校验结论；代码有开源许可证也不等于经过 Apple 公证。

本次检查中，可用身份只有 Apple Development 测试证书，没有可用于正式分发的 Developer ID Application 证书。不能用测试证书或本机自签证书替代正式分发证书。

正式分发需要：

1. 由 Apple 开发者账户提供有效的 Developer ID Application 证书和对应私钥。
2. 对应用及嵌套的 XPC 组件分别签名，启用 Hardened Runtime，并带安全时间戳。
3. 用 `notarytool` 提交 Apple 公证，检查结果和日志。
4. 公证通过后附加凭据（staple），验证最终 DMG，再在保持 Gatekeeper 开启的环境中验收安装。

Apple Developer Program 的常规年费为 99 美元，当地价格及可能的减免以 Apple 账户显示为准。[会员说明](https://developer.apple.com/help/account/membership/program-enrollment)

本项目的密钥组件与主应用相互校验签名，已有密钥也受系统访问控制保护。从本机开发证书切换到 Developer ID 属于身份迁移，必须同时验证组件签名、旧密钥迁移和辅助功能权限；不能只给主应用换签名后宣称已经完成。现有 `TYPEBRIDGE_SIGN_IDENTITY` 参数也不是完整的正式分发流程。

本次没有更换用户签名身份、放宽 Gatekeeper、删除隔离标记或修改钥匙串权限。缺少分发证书时仍将预览版明确标记为未公证。

依据：[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[公证常见问题](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)。

## MIT 开源许可

仓库根目录的 [`LICENSE`](../LICENSE) 使用 MIT 许可证，版权归 King87125。它允许使用、修改、分发及商用，要求保留版权和许可声明，并包含免责条款。公开仓库本身不能代替许可证；许可与系统分发签名也是两个不同的问题。[GitHub 许可说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)

## English

Drag Poieva Translate from the left side of the DMG window to Applications on the right, then launch it from Applications. The package includes a fixed Finder layout and the MIT license.

The preview is **not Developer ID signed or notarized**. macOS may still block its first launch. A polished DMG and an open-source license do not replace Apple’s signing and notarization process. Production distribution requires a Developer ID Application identity, Hardened Runtime, secure timestamps, notarization and validation of the final package. Apple Development certificates are for testing and do not meet those distribution requirements.

The existing credential component is deliberately kept unchanged in ordinary builds. Moving to a new signing identity needs a separate migration and permission check. The current scripts do not claim to complete that migration or remove Gatekeeper’s warning.
