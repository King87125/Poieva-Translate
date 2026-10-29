# Build and development

[English overview](../README.md) · [中文介绍](../README.zh-CN.md)

## Requirements

- A Mac with the macOS 26 SDK and Swift 6 toolchain, such as current Xcode Command Line Tools.
- The distributed preview binary targets Apple Silicon and macOS 26+.
- No third-party Swift packages are required.

## Build

From the repository root:

```sh
./scripts/build-app.sh
open "dist/Poieva Translate.app"
```

The script builds and signs the application and its credential XPC service. On a fresh checkout it creates a persistent local development identity in `.typebridge-signing/`. Keep that directory private and retain it between builds; rotating the identity may invalidate existing system permissions or Keychain access. It is ignored by Git and is not included in the application or DMG.

Create a drag-to-install disk image from the signed app:

```sh
./scripts/package-dmg.sh
```

The output is `dist/Poieva-Translate-0.3.0.dmg`. The DMG uses a fixed Finder layout with a large app icon on the left and Applications on the right. Its metadata tools are installed only in `.build/dmg-tools`, with pinned versions and verified hashes; they are not application runtime dependencies. Local development signing is separate from Developer ID signing and notarization needed for normal public distribution. See [distribution and licensing](distribution.md) for the current status and prerequisites.

## Checks

Run core tests:

```sh
./scripts/test.sh
```

For optional integration tests, run the loopback-only fixture server in one terminal:

```sh
python3 scripts/mock-translation-service.py
```

In another terminal:

```sh
TYPEBRIDGE_TEST_SERVER_URL=http://127.0.0.1:19081/v1 ./scripts/test.sh
```

The fixture uses fixed public samples and no real provider keys. Stop it after testing. Real system translation checks require downloaded language packs:

```sh
"dist/Poieva Translate.app/Contents/MacOS/TypeBridge" --diagnose
"dist/Poieva Translate.app/Contents/MacOS/TypeBridge" --smoke-translate
```

Accessibility attribution can differ for a terminal-launched diagnostic process. The running app’s Settings page is the reference for its actual permission state. Historical results, including known failures, are retained in [verification notes](verification.md).

## Source layout

| Directory | Responsibility |
| --- | --- |
| `Sources/TypeBridge` | macOS windows, menu bar, shortcuts, capture, translation flow and writeback |
| `Sources/TypeBridgeCore` | Translation protocols, providers, document formatting, preferences and validation |
| `Sources/TypeBridgeCredentialSupport` | Shared credential protocol and signing identity checks |
| `Sources/TypeBridgeCredentials` | Fixed XPC Keychain reader |
| `Tests` | Core regression tests and public example fixtures |
| `Examples` | Generic configuration format example with placeholder values |
| `Resources` | Branding, application metadata and UI assets |

Poieva Translate was originally named TypeBridge. Internal module names, the `studio.typebridge.mac` identifier and existing preference/credential namespaces are intentionally preserved for compatibility.

## UI language and branding

Interface strings live in the `en.lproj` and `zh-Hans.lproj` resources under `Sources/TypeBridgeCore/Resources`. UI language is independent of translation source/target languages, model instructions and user-defined service names.

The shared vector mark is [`poieva-mark.svg`](../Resources/Design/poieva-mark.svg). `scripts/make-icon.swift` creates the white app icon in all required sizes; the menu bar uses the same mark as a system template image. Exported artwork is in [`Resources/Branding`](../Resources/Branding).

## Extending translation

New configurations currently expose only Custom AI (OpenAI-compatible Chat Completions) and Custom HTTP Translation. Provider presets are deferred; older adapters remain for saved-configuration compatibility. Protocol regression data lives under `Tests/Fixtures`, separate from the generic user example.

New protocols implement `TranslationProvider` and register an adapter. Existing capture, formatting, settings and writeback can be reused. Configuration schemas and HTTP templates are described in [service configuration](services.md).

Translation profiles are defined in `TranslationProfiles.swift` and `TranslationProfileStore.swift`; their snapshots are resolved through the shared guidance pipeline for the workbench and shortcuts. User instructions are in [Translation Profiles](profiles.md).

`SampleProfileGeneration.swift` uses an existing Custom AI configuration to create an ephemeral, validated draft from pasted or imported writing. The native `SampleProfileGenerationView` lets the user review evidence, edit rules and select terms before a single atomic catalog update. It does not collect chat/email accounts or train a model. Public input and response fixtures are under `Tests/Fixtures/profile-generation-*`; network tests intercept transport and do not require a provider key.

The current app stores explicit writing preferences and terminology. It does not train a personal model or collect translation history. Model-assisted context handling can fail; public context regression fixtures and recorded outputs are kept under `Tests/Fixtures` and `docs`.

## Credential service updates

Normal application builds retain the complete signed credential service bundle unchanged. Changing that component is a separate migration: the default build stops when it detects a different reader. Do not use the component-upgrade override as a routine build fix.

The app and XPC service verify each other’s identifier and signing certificate. User credentials stay in the local Keychain and are excluded from configuration exports, source commits and release assets. The synthetic credential regression scripts are intended for deliberate security/migration testing, not ordinary UI changes.
