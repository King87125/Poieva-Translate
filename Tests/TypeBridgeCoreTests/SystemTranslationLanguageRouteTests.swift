import Testing
@testable import TypeBridgeCore

@Suite @MainActor struct SystemTranslationLanguageRouteTests {
    @Test func installedExactPairWinsWithoutCheckingOrConvertingAnotherScript() async throws {
        var checks = 0
        let route = try await SystemTranslationLanguageRoute.resolve(source: .traditionalChinese, target: .english) { candidate in
            checks += 1
            #expect(candidate.source == .traditionalChinese && candidate.target == .english)
            return .ready
        }
        #expect(checks == 1)
        #expect(try route.prepare(["請保留原文。"], preserveCode: true) == ["請保留原文。"])
        #expect(try route.finish("Keep the original.", preserveCode: true) == "Keep the original.")
    }

    @Test func missingTraditionalSourceUsesInstalledSimplifiedModelAndPreservesProtectedText() async throws {
        let route = try await SystemTranslationLanguageRoute.resolve(source: .traditionalChinese, target: .english) { candidate in
            candidate.source == .simplifiedChinese ? .ready : .notInstalled
        }
        #expect(route.requestedSource == .traditionalChinese && route.source == .simplifiedChinese)
        let original = "# 請保留 `繁體.swift`。\n\n- 網址 https://example.com/繁體 及數字 12。"
        #expect(try route.prepare([original], preserveCode: true) == ["# 请保留 `繁體.swift`。\n\n- 网址 https://example.com/繁體 及数字 12。"])
        #expect(original.hasPrefix("# 請"))
    }

    @Test func missingTraditionalTargetConvertsResultBackToTheRequestedScript() async throws {
        let route = try await SystemTranslationLanguageRoute.resolve(source: .english, target: .traditionalChinese) { candidate in
            candidate.target == .simplifiedChinese ? .ready : .notInstalled
        }
        #expect(route.requestedTarget == .traditionalChinese && route.target == .simplifiedChinese)
        #expect(try route.prepare(["Keep the file."], preserveCode: true) == ["Keep the file."])
        #expect(try route.finish("请保留 `简体.swift` 和 https://example.com/简体。", preserveCode: true) == "請保留 `简体.swift` 和 https://example.com/简体。")
    }

    @Test func installedButTemporarilyUnavailableNeverAsksForAnotherDownload() async {
        do {
            _ = try await SystemTranslationLanguageRoute.resolve(source: .english, target: .simplifiedChinese) { candidate in
                candidate.target == .simplifiedChinese ? .temporarilyUnavailable : .notInstalled
            }
            Issue.record("Expected the installed model's readiness error")
        } catch TranslationFailure.systemNotReady { }
        catch { Issue.record("Wrong recovery: \(error)") }
    }

    @Test func genuineMissingAndUnsupportedPairsRemainDistinct() async {
        do {
            _ = try await SystemTranslationLanguageRoute.resolve(source: .traditionalChinese, target: .english) { _ in .notInstalled }
            Issue.record("Expected missing language pack")
        } catch TranslationFailure.needsLanguagePack(let source, let target) {
            #expect(source == .traditionalChinese && target == .english)
        } catch { Issue.record("Wrong error: \(error)") }
        do {
            _ = try await SystemTranslationLanguageRoute.resolve(source: .japanese, target: .english) { _ in .unsupported }
            Issue.record("Expected unsupported pair")
        } catch TranslationFailure.unsupportedLanguage(let source, let target) {
            #expect(source == .japanese && target == .english)
        } catch { Issue.record("Wrong error: \(error)") }
    }

    @Test func cancelledAvailabilityCheckCannotReturnARouteOrAPackagePrompt() async {
        let task = Task {
            try await SystemTranslationLanguageRoute.resolve(source: .traditionalChinese, target: .english) { _ in
                try await Task.sleep(for: .seconds(5))
                return .notInstalled
            }
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled lookup must stop") }
        catch { #expect(error is CancellationError) }
    }
}
