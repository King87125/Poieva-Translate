import AppKit
import ApplicationServices
import Translation
import TypeBridgeCore

ProcessInfo.processInfo.processName = AppBrand.name

if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--smoke-translate") {
    Task { @MainActor in
        let status = await AppleTranslationProvider.availability().status(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en"))
        print("\(AppBrand.name) 0.1.0")
        print("Accessibility (this diagnostic process): \(AXIsProcessTrusted())")
        print("For the running app, check its Settings permission status; terminal-launched diagnostics may have different attribution.")
        print("Chinese-English language pack: \(status)")
        if CommandLine.arguments.contains("--smoke-translate") {
            do {
                let provider = AppleTranslationProvider()
                let result = try await provider.translate(TranslationRequest(text: "你好，请帮我创建一个简单的项目。", target: .english))
                print("Translation smoke test: \(result)")
                let greeting = try await provider.translate(TranslationRequest(text: "你好", target: .english))
                print("Short Chinese smoke test: \(greeting)")
                let sameLanguage = try await provider.translate(TranslationRequest(text: "你好", target: .simplifiedChinese))
                print("Shared Chinese characters smoke test: \(sameLanguage)")
                let script = try await provider.translate(TranslationRequest(text: "請幫我建立專案", target: .simplifiedChinese))
                print("Chinese script smoke test: \(script)")
                for text in ["這個工具可以保留原來的格式。", "This tool keeps the original formatting.", "這個工具可以保留原來的格式。"] {
                    let request = try TranslationDirection.chineseEnglish.request(text: text, fixedTarget: .english, preserveCode: true)
                    let result = try await provider.translate(request)
                    guard !result.isEmpty else { throw TranslationFailure.incompleteResponse }
                    print("Repeated preview language route \(request.source.rawValue) -> \(request.target.rawValue): \(result)")
                }
                let traditionalResult = try await provider.translate(TranslationRequest(text: "Please translate this document.", source: .english, target: .traditionalChinese))
                print("Requested Traditional Chinese via installed model: \(traditionalResult)")
                for text in ["你好，请帮我创建一个简单的项目。", "Hello, please help me create a simple project."] {
                    let request = try TranslationDirection.chineseEnglish.request(text: text, fixedTarget: .english, preserveCode: true)
                    let result = try await provider.translate(request)
                    print("Automatic \(request.source.rawValue) -> \(request.target.rawValue): \(result)")
                }
                let formattedRequest = TranslationRequest(text: "你好\n谢谢", source: .simplifiedChinese, target: .english)
                let html = try HTMLTranslationDocument(html: "<h2 style='color:red'>你好</h2><ul><li><strong>谢谢</strong></li></ul>",
                    plainText: formattedRequest.text, preserveCode: true)
                let formatted = try html.render(await provider.translateSegments(html.texts, for: formattedRequest))
                print("Formatted translation smoke test: \(formatted.html)")
                var progress: [TranslationProgress] = []
                let layout = try await provider.translate(TranslationRequest(text: "# 你好\n\n- 谢谢", source: .simplifiedChinese, target: .english), progress: { progress.append($0) })
                guard layout.hasPrefix("# "), layout.contains("\n\n- ") else { throw TranslationFailure.incompleteResponse }
                guard progress.first?.completedCharacters == 0,
                      progress.last == TranslationProgress(completedCharacters: 4, totalCharacters: 4),
                      zip(progress, progress.dropFirst()).allSatisfy({ $0.completedCharacters <= $1.completedCharacters }) else {
                    throw TranslationFailure.incompleteResponse
                }
                print("Paragraph and list smoke test: \(layout)")
                print("Actual batch progress: \(progress.map { String($0.completedCharacters) }.joined(separator: " -> ")) / 4 characters")
                exit(0)
            } catch {
                print("Translation smoke test unavailable: \(error.localizedDescription)")
                exit(2)
            }
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
