import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TypeBridgeCore

@MainActor
struct WorkbenchSceneBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @State private var error = ""
    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.tr("场景")).font(.system(size: 12)).foregroundStyle(.secondary)
            SelectionField(title: L10n.tr("当前翻译场景"), selection: Binding<UUID?>(get: { store.catalog.activeSceneID }, set: {
                do { try store.select($0); error = "" } catch { self.error = error.localizedDescription }
            }), options: [SelectionOption<UUID?>(nil, L10n.tr("通用翻译"))] + store.catalog.scenes.map { SelectionOption(Optional($0.id), $0.name) })
                .frame(width: 210)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error) }
            Spacer(minLength: 8)
            if store.catalog.activeSceneID != nil, let issue = model.workbenchAssistanceIssue {
                Button { model.showSettings() } label: { Label(L10n.tr("需要 AI 辅助"), systemImage: "exclamationmark.circle") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.orange).help(issue)
            }
            Button(L10n.tr("管理方案…"), systemImage: "square.stack") { model.showProfiles() }
                .accessibilityLabel(L10n.tr("管理术语库、语气和场景"))
        }.padding(.horizontal, 24).frame(height: 48)
            .background(Color.primary.opacity(0.025))
            .disabled(model.translatingOutsideWorkbench || model.committing || model.isComposing)
    }
}

private enum ProfileEditorDraft: Identifiable {
    case scene(TranslationScene), glossary(TerminologyLibrary), tone(ToneConfiguration)
    var id: UUID { switch self { case .scene(let x): return x.id; case .glossary(let x): return x.id; case .tone(let x): return x.id } }
}

private struct ProfilePackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw TranslationProfileFailure.damaged }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct TranslationProfileManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @State private var selection: String?
    @State private var query = ""
    @State private var editor: ProfileEditorDraft?
    @State private var pendingSelection: String?
    @State private var deleting = false
    @State private var importing = false
    @State private var exporting = false
    @State private var document: ProfilePackageDocument?
    @State private var message = ""
    @State private var failed = false
    private var kind: TranslationProfileKind? { selection?.split(separator: ":").first.flatMap { TranslationProfileKind(rawValue: String($0)) } }
    private var selectedID: UUID? { selection?.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) } }
    private var selectedName: String? {
        switch kind {
        case .scene: return store.catalog.scenes.first { $0.id == selectedID }?.name
        case .glossary: return store.catalog.glossaries.first { $0.id == selectedID }?.name
        case .tone: return store.catalog.tones.first { $0.id == selectedID }?.name
        case nil: return nil
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("翻译方案")).font(.title3.weight(.semibold))
                    Text(L10n.tr("工作台与快捷键翻译共用当前场景")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.tr("当前场景：\(store.catalog.activeScene?.name ?? L10n.tr("通用翻译"))")).font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField(L10n.tr("搜索方案"), text: $query).textFieldStyle(.roundedBorder).padding(12)
                    List(selection: $selection) {
                        Section(L10n.tr("场景模板")) {
                            ForEach(store.catalog.scenes.filter { matches($0.name) }) { scene in
                                HStack { Label(scene.name, systemImage: "square.stack"); Spacer(); if scene.id == store.catalog.activeSceneID { Image(systemName: "checkmark").foregroundStyle(.tint) } }
                                    .tag("scene:" + scene.id.uuidString)
                            }
                        }
                        Section(L10n.tr("术语库")) {
                            ForEach(store.catalog.glossaries.filter { matches($0.name) }) { library in
                                HStack { Label(library.name, systemImage: "text.book.closed"); Spacer(); Text("\(library.entries.count)").foregroundStyle(.secondary).font(.caption) }
                                    .tag("glossary:" + library.id.uuidString)
                            }
                        }
                        Section(L10n.tr("语气配置")) {
                            ForEach(store.catalog.tones.filter { matches($0.name) }) { tone in
                                Label(tone.name, systemImage: "text.bubble").tag("tone:" + tone.id.uuidString)
                            }
                        }
                    }.listStyle(.sidebar)
                    Divider()
                    HStack {
                        Menu { ForEach(TranslationProfileKind.allCases) { kind in Button(kind.name, systemImage: kind.symbol) { add(kind) } } }
                        label: { Label(L10n.tr("新建"), systemImage: "plus") }.fixedSize()
                        Spacer()
                        Button { deleting = true } label: { Image(systemName: "trash") }
                            .accessibilityLabel(L10n.tr("删除选中方案"))
                            .disabled(selectedName == nil)
                    }.padding(12).disabled(model.committing)
                }.frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                VStack(spacing: 0) {
                    if let name = selectedName, let kind {
                        HStack {
                            Label(name, systemImage: kind.symbol).font(.title3.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if kind == .scene {
                                Button(store.catalog.activeSceneID == selectedID ? L10n.tr("正在使用") : L10n.tr("使用此场景")) { perform { try store.select(selectedID) } }
                                    .disabled(store.catalog.activeSceneID == selectedID || model.committing)
                            }
                            Button(L10n.tr("编辑…")) { editSelected() }.disabled(model.committing)
                        }.padding(20)
                        Divider()
                        ProfileDetailView(catalog: store.catalog, kind: kind, id: selectedID!)
                    } else {
                        ContentUnavailableView(L10n.tr("选择或新建翻译方案"), systemImage: "square.stack")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                Button(L10n.tr("导入…")) { importing = true }.disabled(model.committing)
                Menu(L10n.tr("导出")) {
                    Button(L10n.tr("导出选中配置…")) { prepareExport(selected: true) }.disabled(selectedName == nil)
                    Button(L10n.tr("导出全部方案…")) { prepareExport(selected: false) }
                }.fixedSize()
                if store.catalog.activeSceneID != nil { Button(L10n.tr("停用场景")) { perform { try store.select(nil) } }.disabled(model.committing) }
                Spacer()
                if !message.isEmpty || !store.issue.isEmpty {
                    Text(message.isEmpty ? store.issue : message).font(.caption).foregroundStyle(failed || !store.issue.isEmpty ? Color.red : Color.secondary)
                        .lineLimit(2).help(message.isEmpty ? store.issue : message)
                }
            }.padding(16)
        }.frame(minWidth: 800, minHeight: 480)
        .onAppear { if selection == nil { selection = (store.catalog.activeSceneID ?? store.catalog.scenes.first?.id).map { "scene:" + $0.uuidString } } }
        .sheet(item: $editor, onDismiss: {
            if let pendingSelection, let rawID = pendingSelection.split(separator: ":").last, let id = UUID(uuidString: String(rawID)),
               (store.catalog.scenes.map(\.id) + store.catalog.glossaries.map(\.id) + store.catalog.tones.map(\.id)).contains(id) {
                selection = pendingSelection
            }
            pendingSelection = nil
        }) { draft in
            switch draft {
            case .scene(let scene): SceneEditor(model: model, store: store, initial: scene)
            case .glossary(let library): GlossaryEditor(model: model, store: store, initial: library)
            case .tone(let tone): ToneEditor(model: model, store: store, initial: tone)
            }
        }
        .confirmationDialog(L10n.tr("删除“\(selectedName ?? "")”？"), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.tr("删除"), role: .destructive) {
                if let kind, let selectedID { perform { try store.remove(selectedID, kind: kind); selection = nil } }
            }
        } message: { Text(L10n.tr("引用此项的场景会移除该关联，其他配置保留。")) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= TranslationProfilePackage.maximumBytes else { throw TranslationProfileFailure.oversized }
                let count = try store.importPackage(Data(contentsOf: url))
                message = L10n.tr("已导入 \(count) 项配置，当前场景保持不变。")
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Poieva-Translation-Profiles") { result in
            perform { _ = try result.get(); message = L10n.tr("方案已导出，不包含服务密钥。") }
        }
    }
    private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }
    private func perform(_ action: () throws -> Void) { do { try action(); failed = false } catch { message = error.localizedDescription; failed = true } }
    private func add(_ kind: TranslationProfileKind) {
        switch kind { case .scene: editor = .scene(.init()); case .glossary: editor = .glossary(.init()); case .tone: editor = .tone(.init()) }
        pendingSelection = editor.map { kind.rawValue + ":" + $0.id.uuidString }
    }
    private func editSelected() {
        switch kind {
        case .scene: if let x = store.catalog.scenes.first(where: { $0.id == selectedID }) { editor = .scene(x) }
        case .glossary: if let x = store.catalog.glossaries.first(where: { $0.id == selectedID }) { editor = .glossary(x) }
        case .tone: if let x = store.catalog.tones.first(where: { $0.id == selectedID }) { editor = .tone(x) }
        case nil: break
        }
    }
    private func prepareExport(selected: Bool) {
        perform { document = .init(data: try store.exportPackage(kind: selected ? kind : nil, id: selected ? selectedID : nil)); exporting = true }
    }
}

private struct ProfileDetailView: View {
    let catalog: TranslationProfileCatalog
    let kind: TranslationProfileKind
    let id: UUID
    var body: some View {
        Group {
            switch kind {
            case .glossary:
                if let library = catalog.glossaries.first(where: { $0.id == id }) { GlossaryTable(entries: library.entries) }
            case .scene:
                if let scene = catalog.scenes.first(where: { $0.id == id }) {
                    Form {
                        Section(L10n.tr("语气配置")) { Text(catalog.tones.first { $0.id == scene.toneID }?.name ?? L10n.tr("沿用原文")) }
                        Section(L10n.tr("术语库")) {
                            if scene.glossaryIDs.isEmpty { Text(L10n.tr("未关联术语库")).foregroundStyle(.secondary) }
                            ForEach(catalog.glossaries.filter { scene.glossaryIDs.contains($0.id) }) { library in
                                LabeledContent(library.name) { Text(L10n.tr("\(library.entries.count) 条术语")).foregroundStyle(.secondary) }
                            }
                        }
                        Section(L10n.tr("场景要求")) { Text(scene.instructions.isEmpty ? L10n.tr("无额外要求") : scene.instructions).textSelection(.enabled) }
                        Section { LabeledContent(L10n.tr("适用译文"), value: languageTitle(scene.target)) }
                    }.formStyle(.grouped)
                }
            case .tone:
                if let tone = catalog.tones.first(where: { $0.id == id }) {
                    Form {
                        Section { LabeledContent(L10n.tr("表达风格"), value: tone.tone.name); LabeledContent(L10n.tr("适用译文"), value: languageTitle(tone.target)) }
                        Section(L10n.tr("表达规则")) { Text(tone.instructions.isEmpty ? L10n.tr("无额外要求") : tone.instructions).textSelection(.enabled) }
                        if !tone.exampleSource.isEmpty {
                            Section(L10n.tr("参考例句")) { LabeledContent(L10n.tr("原文"), value: tone.exampleSource); LabeledContent(L10n.tr("译文"), value: tone.exampleTranslation) }
                        }
                    }.formStyle(.grouped)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func languageTitle(_ language: AppLanguage) -> String { language == .automatic ? L10n.tr("所有语言") : language.name }
private var profileLanguageOptions: [SelectionOption<AppLanguage>] {
    [SelectionOption(.automatic, L10n.tr("所有语言"))] + AppLanguage.targets.map { SelectionOption($0, $0.name) }
}

private struct GlossaryTable: View {
    let entries: [GlossaryEntry]
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.tr("搜索术语"), text: $query).textFieldStyle(.roundedBorder).padding(16)
            Table(entries.filter { query.isEmpty || $0.source.localizedCaseInsensitiveContains(query) || $0.output.localizedCaseInsensitiveContains(query) }) {
                TableColumn(L10n.tr("原文"), value: \.source)
                TableColumn(L10n.tr("固定译法")) { Text($0.output) }
                TableColumn(L10n.tr("语言方向")) { Text(languageTitle($0.sourceLanguage) + " → " + languageTitle($0.targetLanguage)).foregroundStyle(.secondary).font(.caption) }
            }.overlay { if entries.isEmpty { ContentUnavailableView(L10n.tr("还没有术语"), systemImage: "text.book.closed") } }
        }
    }
}

private struct ProfileEditorFooter: View {
    let error: String
    let disabled: Bool
    let cancel: () -> Void
    let save: () -> Void
    var body: some View {
        Divider()
        HStack {
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer()
            Button(L10n.tr("取消"), action: cancel).keyboardShortcut(.cancelAction)
            Button(L10n.tr("保存"), action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(disabled)
        }.padding(16)
    }
}

@MainActor
private struct SceneEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TranslationScene
    @State private var error = ""
    init(model: AppModel, store: TranslationProfileStore, initial: TranslationScene) { self.model = model; self.store = store; _draft = State(initialValue: initial) }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("编辑场景模板")).font(.headline).padding(20)
            Form {
                Section {
                    TextField(L10n.tr("名称"), text: $draft.name)
                    HStack { Text(L10n.tr("适用译文")); Spacer(); SelectionField(title: L10n.tr("适用译文"), selection: $draft.target, options: profileLanguageOptions).frame(width: 210) }
                    HStack { Text(L10n.tr("语气配置")); Spacer(); SelectionField(title: L10n.tr("语气配置"), selection: $draft.toneID,
                        options: [SelectionOption<UUID?>(nil, L10n.tr("沿用原文"))] + store.catalog.tones.map { SelectionOption(Optional($0.id), $0.name) })
                        .frame(width: 210) }
                }
                Section(L10n.tr("术语库")) {
                    if store.catalog.glossaries.isEmpty { Text(L10n.tr("先在翻译方案中新建术语库")).foregroundStyle(.secondary) }
                    ForEach(store.catalog.glossaries) { library in
                        Toggle(library.name, isOn: Binding(get: { draft.glossaryIDs.contains(library.id) }, set: {
                            if $0 { draft.glossaryIDs.append(library.id) } else { draft.glossaryIDs.removeAll { $0 == library.id } }
                        }))
                    }
                }
                Section(L10n.tr("场景要求")) {
                    TextEditor(text: $draft.instructions).frame(minHeight: 90).accessibilityLabel(L10n.tr("场景要求内容"))
                    Text("\(draft.instructions.count) / 1,000").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            ProfileEditorFooter(error: error, disabled: model.committing, cancel: { dismiss() }, save: {
                do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription }
            })
        }.frame(width: 540, height: 560)
    }
}

@MainActor
private struct ToneEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ToneConfiguration
    @State private var error = ""
    init(model: AppModel, store: TranslationProfileStore, initial: ToneConfiguration) { self.model = model; self.store = store; _draft = State(initialValue: initial) }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("编辑语气配置")).font(.headline).padding(20)
            Form {
                Section {
                    TextField(L10n.tr("名称"), text: $draft.name)
                    HStack { Text(L10n.tr("表达风格")); Spacer(); SelectionField(title: L10n.tr("表达风格"), selection: $draft.tone, options: TranslationTone.allCases.map { SelectionOption($0, $0.name) }).frame(width: 210) }
                    HStack { Text(L10n.tr("适用译文")); Spacer(); SelectionField(title: L10n.tr("适用译文"), selection: $draft.target, options: profileLanguageOptions).frame(width: 210) }
                }
                Section(L10n.tr("表达规则")) {
                    TextEditor(text: $draft.instructions).frame(height: 80).accessibilityLabel(L10n.tr("表达规则内容"))
                    Text("\(draft.instructions.count) / 1,000").font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("参考例句（可选）")) {
                    TextField(L10n.tr("例句原文"), text: $draft.exampleSource, axis: .vertical).lineLimit(2...4)
                    TextField(L10n.tr("例句译文"), text: $draft.exampleTranslation, axis: .vertical).lineLimit(2...4)
                }
            }.formStyle(.grouped)
            ProfileEditorFooter(error: error, disabled: model.committing, cancel: { dismiss() }, save: {
                do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription }
            })
        }.frame(width: 540, height: 580)
    }
}

@MainActor
private struct GlossaryEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: TranslationProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TerminologyLibrary
    @State private var selected: UUID?
    @State private var editingEntry: GlossaryEntry?
    @State private var query = ""
    @State private var error = ""
    init(model: AppModel, store: TranslationProfileStore, initial: TerminologyLibrary) { self.model = model; self.store = store; _draft = State(initialValue: initial) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.tr("编辑术语库")).font(.headline); Spacer() }.padding(20)
            HStack { Text(L10n.tr("名称")); TextField(L10n.tr("术语库名称"), text: $draft.name).textFieldStyle(.roundedBorder) }.padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            HStack { TextField(L10n.tr("搜索术语"), text: $query).textFieldStyle(.roundedBorder); Button(L10n.tr("添加术语"), systemImage: "plus") { editingEntry = .init() } }.padding(16)
            Table(draft.entries.filter { query.isEmpty || $0.source.localizedCaseInsensitiveContains(query) || $0.output.localizedCaseInsensitiveContains(query) }, selection: $selected) {
                TableColumn(L10n.tr("原文"), value: \.source)
                TableColumn(L10n.tr("固定译法")) { Text($0.output) }
                TableColumn(L10n.tr("语言方向")) { Text(languageTitle($0.sourceLanguage) + " → " + languageTitle($0.targetLanguage)).font(.caption).foregroundStyle(.secondary) }
            }.contextMenu(forSelectionType: UUID.self) { ids in
                Button(L10n.tr("编辑…")) { if let id = ids.first { editingEntry = draft.entries.first { $0.id == id } } }.disabled(ids.isEmpty)
            } primaryAction: { ids in if let id = ids.first { editingEntry = draft.entries.first { $0.id == id } } }
            HStack {
                Button(L10n.tr("编辑…")) { editingEntry = draft.entries.first { $0.id == selected } }.disabled(selected == nil)
                Button(L10n.tr("删除术语")) { draft.entries.removeAll { $0.id == selected }; selected = nil }.disabled(selected == nil)
                Spacer(); Text(L10n.tr("\(draft.entries.count) 条术语")).font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            ProfileEditorFooter(error: error, disabled: model.committing, cancel: { dismiss() }, save: {
                do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription }
            })
        }.frame(width: 720, height: 540)
        .sheet(item: $editingEntry) { entry in
            GlossaryEntryEditor(initial: entry) { updated in
                if let index = draft.entries.firstIndex(where: { $0.id == updated.id }) { draft.entries[index] = updated }
                else { draft.entries.append(updated) }
                selected = updated.id
            }
        }
    }
}

@MainActor
private struct GlossaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GlossaryEntry
    @State private var error = ""
    let save: (GlossaryEntry) -> Void
    init(initial: GlossaryEntry, save: @escaping (GlossaryEntry) -> Void) { _draft = State(initialValue: initial); self.save = save }
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("编辑术语")).font(.headline).padding(20)
            Form {
                Section {
                    TextField(L10n.tr("原文"), text: $draft.source)
                    TextField(L10n.tr("固定译法"), text: $draft.translation).disabled(draft.preserveOriginal)
                    Toggle(L10n.tr("保留原文"), isOn: $draft.preserveOriginal)
                }
                Section(L10n.tr("语言方向")) {
                    HStack { Text(L10n.tr("原文语言")); Spacer(); SelectionField(title: L10n.tr("术语原文语言"), selection: $draft.sourceLanguage, options: profileLanguageOptions).frame(width: 180) }
                    HStack { Text(L10n.tr("目标语言")); Spacer(); SelectionField(title: L10n.tr("术语目标语言"), selection: $draft.targetLanguage, options: profileLanguageOptions).frame(width: 180) }
                }
            }.formStyle(.grouped)
            ProfileEditorFooter(error: error, disabled: false, cancel: { dismiss() }, save: {
                do { save(try draft.validated()); dismiss() } catch { self.error = error.localizedDescription }
            })
        }.frame(width: 440, height: 400)
    }
}
