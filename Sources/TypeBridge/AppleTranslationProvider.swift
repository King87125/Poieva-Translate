import Foundation
import Translation
import TypeBridgeCore

@MainActor
final class AppleTranslationProvider: TranslationProvider {
    let name = L10n.tr("Apple 系统翻译")
    private var activeSession: TranslationSession?

    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { return LanguageAvailability(preferredStrategy: .lowLatency) }
        return LanguageAvailability()
    }

    static func installedSessionRoute(source: AppLanguage, target: AppLanguage) async throws -> (route: SystemTranslationLanguageRoute, session: TranslationSession) {
        var sessions: [SystemTranslationLanguageRoute: TranslationSession] = [:]
        let availability = Self.availability()
        let route = try await SystemTranslationLanguageRoute.resolve(source: source, target: target) { candidate in
            let from = Locale.Language(identifier: candidate.source.rawValue)
            let to = Locale.Language(identifier: candidate.target.rawValue)
            let status = await availability.status(from: from, to: to)
            switch status {
            case .installed, .supported: break
            case .unsupported: return .unsupported
            @unknown default: return .temporarilyUnavailable
            }
            let session: TranslationSession
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: from, target: to)
            }
            // This session cannot request downloads. Readiness also avoids
            // treating stale availability metadata as another missing package.
            if await session.isReady {
                sessions[candidate] = session
                return .ready
            }
            return status == .installed ? .temporarilyUnavailable : .notInstalled
        }
        try Task.checkCancellation()
        guard let session = sessions[route] else { throw TranslationFailure.systemNotReady }
        return (route, session)
    }

    func detectedSource(for request: TranslationRequest) throws -> AppLanguage {
        try LanguageDetection.source(for: request)
    }

    func translate(_ request: TranslationRequest, progress: TranslationProgressHandler? = nil) async throws -> String {
        _ = try detectedSource(for: request)
        let document = TranslationDocument(request.text, preserveCode: request.preserveCode)
        let indices = document.translatableIndices
        let responses = try await translateSegments(indices.map { document.segments[$0].text }, for: request, progress: progress)
        return try document.assemble(Dictionary(uniqueKeysWithValues: zip(indices, responses)))
    }

    func translateSegments(_ texts: [String], for request: TranslationRequest, progress: TranslationProgressHandler? = nil) async throws -> [String] {
        let source = try detectedSource(for: request)
        var tracker = TranslationProgressTracker(texts: texts)
        progress?(tracker.progress)
        if texts.isEmpty { return [] }
        if source == request.target { return texts }
        if source.isChinese && request.target.isChinese {
            return try texts.indices.map { index in
                try Task.checkCancellation()
                let result = try ChineseScript.convert(texts[index], to: request.target, preserveCode: request.preserveCode)
                progress?(try tracker.complete(index: index, translation: result))
                return result
            }
        }
        let (route, session) = try await Self.installedSessionRoute(source: source, target: request.target)
        let modelTexts = try route.prepare(texts, preserveCode: request.preserveCode)
        activeSession = session
        defer { if activeSession === session { activeSession = nil } }
        let requests = texts.indices.map { index in
            TranslationSession.Request(sourceText: modelTexts[index], clientIdentifier: String(index))
        }
        var results: [Int: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                try Task.checkCancellation()
                guard let identifier = response.clientIdentifier, let index = Int(identifier), texts.indices.contains(index),
                      response.sourceText == modelTexts[index] else {
                    throw TranslationFailure.incompleteResponse
                }
                let result = try route.finish(response.targetText, preserveCode: request.preserveCode)
                let update = try tracker.complete(index: index, translation: result)
                results[index] = result
                progress?(update)
            }
            try Task.checkCancellation()
            guard results.count == texts.count else { throw TranslationFailure.incompleteResponse }
            return try texts.indices.map { index in
                guard let value = results[index] else { throw TranslationFailure.incompleteResponse }
                return value
            }
        } catch {
            if error is CancellationError || Task.isCancelled || TranslationError.alreadyCancelled ~= error { throw CancellationError() }
            if error is TranslationFailure { throw error }
            if TranslationError.notInstalled ~= error {
                let currentStatus = await Self.availability().status(from: Locale.Language(identifier: route.source.rawValue), to: Locale.Language(identifier: route.target.rawValue))
                try Task.checkCancellation()
                if currentStatus == .supported { throw TranslationFailure.needsLanguagePack(route.source, route.target) }
                throw TranslationFailure.systemNotReady
            }
            if TranslationError.unsupportedSourceLanguage ~= error || TranslationError.unsupportedTargetLanguage ~= error || TranslationError.unsupportedLanguagePairing ~= error {
                throw TranslationFailure.unsupportedLanguage(source, request.target)
            }
            if TranslationError.unableToIdentifyLanguage ~= error { throw TranslationFailure.detectionFailed }
            throw TranslationFailure.systemUnavailable
        }
    }

    func cancel() { activeSession?.cancel() }
}
