import SwiftUI
import UIKit
import PhotosUI
import ImageIO

struct ContactActionButton: View {
    let title: String
    let phase: ComposerSendPhase
    var disabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    ProgressView().opacity(phase == .sending ? 1 : 0)
                    Image(systemName: "checkmark").opacity(phase == .sent ? 1 : 0)
                    Image(systemName: "exclamationmark").opacity(phase == .failed ? 1 : 0)
                }.frame(width: 16, height: 16)
                Text(phase == .sending ? "处理中" : phase == .sent ? "已完成" : title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(width: 112, height: 44)
            .foregroundStyle(phase == .failed ? Theme.danger : Theme.brand)
            .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 12))
            .animation(reduced ? nil : WandMotion.stateSwap, value: phase)
        }
        .buttonStyle(.plain).disabled(disabled || phase == .sending)
    }
}

struct ContactAvatar: View {
    let id: String
    let avatar: String
    var systemKey: String? = nil
    var provider: String? = nil
    var team = false
    var size: CGFloat = 44
    var name: String = ""
    var floating = false
    var body: some View {
        Group {
            if !team, let asset = PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar) {
                PlushAvatarView(asset: asset, size: size, floating: floating)
            } else { legacyFace }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if !team, let known = WandProvider.normalizedID(provider) {
                let badge = min(20, max(13, size * 0.5))
                let shape = RoundedRectangle(cornerRadius: badge * 0.35)
                BrandLogo(provider: known).frame(width: (badge - 3) * 0.75, height: (badge - 3) * 0.75)
                    .frame(width: badge, height: badge).background(Theme.elevated, in: shape)
                    .overlay(shape.stroke(Theme.background, lineWidth: 1.5)).offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
    @ViewBuilder private var legacyFace: some View {
        if floating { legacyFaceContent }
        else {
            legacyFaceContent
                .background(Theme.surfaceSoft, in: RoundedRectangle(cornerRadius: size * 0.3))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3))
        }
    }
    private var legacyFaceContent: some View {
        ZStack {
            if avatar.hasPrefix("data:image/"), let comma = avatar.firstIndex(of: ","),
               let bytes = Data(base64Encoded: String(avatar[avatar.index(after: comma)...])),
               let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: floating ? .fit : .fill)
            } else {
                if team {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(Theme.info)
                } else {
                    Canvas { context, bounds in
                        let pixels = ContactCatAvatar.grid(coat: ContactCatAvatar.coatIndex(id: id, avatar: avatar))
                        let cell = bounds.width / 10
                        for (row, cells) in pixels.enumerated() {
                            for (column, rgb) in cells.enumerated() {
                                guard let rgb else { continue }
                                let color = Color(red: Double((rgb >> 16) & 255) / 255,
                                    green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
                                context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                    width: cell, height: cell)), with: .color(color))
                            }
                        }
                    }.frame(width: size * 0.74, height: size * 0.74)
                }
            }
        }.frame(width: size, height: size)
    }
}

/// Mirrors src/plush-avatar.ts: strict v1 fields, stable UTF-16 seed, no persistence.
enum PlushAvatarIdentity {
    static let shapes = ["heart", "triangle", "diamond", "round", "square", "capsule"]
    static let colors = ["coral", "sage", "lavender", "cream", "blue", "ochre"]
    static let glasses = ["none", "gold", "ink"]
    static let hats = ["none", "beanie", "beret"]
    private static func hash(_ seed: String) -> UInt32 {
        var value: UInt32 = 0x811c9dc5
        for unit in seed.utf16 { value = (value ^ UInt32(unit)) &* 0x01000193 }
        value = (value ^ (value >> 16)) &* 0x85ebca6b
        value = (value ^ (value >> 13)) &* 0xc2b2ae35
        return value ^ (value >> 16)
    }
    static func asset(id: String, name: String = "", avatar: String) -> String? {
        if avatar.hasPrefix("data:image/") || avatar.range(of: "^cat:[0-9]+$", options: .regularExpression) != nil { return nil }
        if avatar == "plush-cat:v1:silver" { return "plush_cat_silver" }
        if avatar == "plush-cat:v1:orange" { return "plush_cat_orange" }
        let fields = avatar.components(separatedBy: ":")
        let options = [shapes, colors, glasses, hats]
        if fields.count == 6, fields[0] == "plush", fields[1] == "v1",
           options.indices.allSatisfy({ options[$0].contains(fields[$0 + 2]) }) {
            return "plush_" + fields.dropFirst(2).joined(separator: "_")
        }
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = !trimmedID.isEmpty ? trimmedID : !trimmedName.isEmpty ? trimmedName : "member"
        let keys = ["shape", "color", "glasses", "hat"]
        return "plush_" + options.enumerated().map { index, choices in
            choices[Int(hash("plush:v1:\(identity):\(keys[index])") % UInt32(choices.count))]
        }.joined(separator: "_")
    }
}

/// Transparent static portraits exported from the shared scene. Animation uses WorkingAvatar.
struct PlushAvatarView: View {
    let asset: String
    let size: CGFloat
    let floating: Bool
    var body: some View {
        Image(asset).resizable().scaledToFit().frame(width: size, height: size)
            .shadow(color: Theme.textPrimary.opacity(floating ? 0.16 : 0), radius: 4, x: 0, y: 3)
    }
}

/// Exact Android/Web 10×10 cat palette and UTF-16 identity hash.
enum ContactCatAvatar {
    static let rows = ["TdTTTTTTdT", "dbdTTTTdbd", "dbbbbbbbbd", "bbwkbbwkbb", "bbwwbbwwbb",
        "bbbbppbbbb", "bdblbblbdb", "TbbbbbbbbT", "TTbdbbdbTT", "TTTbTTbTTT"]
    static let coats: [(base: Int, dark: Int, light: Int, eye: Int)] = [
        (0xF0923A, 0xC46A1A, 0xF0923A, 0x2D2D2D),
        (0x9EAAB8, 0x6B7B8D, 0xC5CED8, 0x3F8F55),
        (0xF4F1EA, 0x2F2F33, 0xF4F1EA, 0x2D2D2D),
        (0x3A3A40, 0x1E1E22, 0x55555C, 0xE9C63F),
        (0xE9DCC4, 0x6B4A36, 0xF4ECDD, 0x3F7FD8),
        (0x7C8BA6, 0x56627A, 0x98A6BE, 0xE0A43A),
        (0xF2E6D4, 0xC46A1A, 0x3A3A40, 0x2D2D2D),
        (0xF2B8C6, 0xC9788D, 0xF8D3DC, 0x2D2D2D)
    ]
    static func coatIndex(id: String, avatar: String) -> Int {
        if avatar.range(of: "^cat:[0-9]+$", options: .regularExpression) != nil,
           let explicit = Int32(avatar.dropFirst(4)) { return Int(explicit) % coats.count }
        var hash: Int32 = 0
        let seed = id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "member" : id
        for unit in seed.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return Int(abs(Int64(hash)) % Int64(coats.count))
    }
    static func grid(coat: Int) -> [[Int?]] {
        let palette = coats[((coat % coats.count) + coats.count) % coats.count]
        return rows.map { row in row.map { cell in
            switch cell {
            case "T": return nil
            case "b": return palette.base
            case "d": return palette.dark
            case "l": return palette.light
            case "w": return 0xFFFFFF
            case "k": return palette.eye
            default: return 0xF28B9A
            }
        } }
    }
}

struct ContactCandidateEditor: View {
    @Binding var agents: [ContactCandidate]
    let catalog: ModelsResponse?
    var body: some View {
        VStack(spacing: WandLayout.sectionGap) {
            ForEach(agents.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(index == 0 ? "首选" : "备用 \(index)").font(.subheadline.weight(.semibold))
                    if agents.count > 1 {
                        HStack {
                            Button { agents.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel("候选\(index + 1)上移")
                            Button { agents.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == agents.count - 1).accessibilityLabel("候选\(index + 1)下移")
                            Spacer(minLength: 0)
                            Button("移除") { agents.remove(at: index) }.foregroundStyle(Theme.danger)
                        }
                    }
                    WandFormField("执行工具") {
                    Picker("执行工具", selection: Binding(
                        get: { WandAgentTool(provider: agents[index].provider, engine: agents[index].engine).rawValue }, set: { id in
                            guard let tool = WandAgentTool(rawValue: id) else { return }
                            agents[index].provider = tool.provider.rawValue; agents[index].engine = tool.engine; agents[index].model = "default"
                            agents[index].thinkingEffort = "off"; agents[index].mode = wandBoardNormalizedMode(provider: tool.provider.rawValue, mode: "default")
                            if tool.structuredOnly { agents[index].kind = "structured" }
                        }
                    )) {
                        ForEach(WandAgentTool.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden()
                    }
                    WandFormField("模型", hint: "default 跟随默认，也可直接填写模型 ID。") {
                        HStack(alignment: .top) {
                            TextField("模型 ID", text: $agents[index].model)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("候选\(index + 1)模型 ID")
                            Menu {
                                Button("跟随默认") { agents[index].model = "default" }
                                ForEach(catalog?.models(for: agents[index].provider) ?? []) { model in
                                    Button(model.label) { agents[index].model = model.id }
                                }
                            } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("选择候选\(index + 1)模型")
                        }
                    }
                    WandFormField("思考深度") {
                        Picker("思考深度", selection: $agents[index].thinkingEffort) {
                            let options = thinkingEffortOptions(provider: agents[index].provider,
                                selectedModel: agents[index].model, defaultModel: catalog?.defaultModelId(for: agents[index].provider),
                                models: catalog?.models(for: agents[index].provider) ?? [],
                                providerEfforts: catalog?.thinkingEfforts(for: agents[index].provider) ?? [])
                            ForEach(options) { Text($0.label).tag($0.id) }
                            if !options.contains(where: { $0.id == agents[index].thinkingEffort }) {
                                Text(agents[index].thinkingEffort).tag(agents[index].thinkingEffort)
                            }
                        }.labelsHidden()
                    }
                    WandFormField("执行模式") {
                        Picker("执行模式", selection: $agents[index].mode) {
                            ForEach(wandBoardSupportedModes(agents[index].provider), id: \.self) { mode in
                                Text(wandBoardModeLabel(mode)).tag(mode)
                            }
                        }.labelsHidden()
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if index < agents.count - 1 { Divider() }
            }
            if agents.count < 4 {
                Button("添加执行候选") { agents.append(ContactCandidate()) }
            }
        }
    }
}

/// Match Android's avatar upload boundary: downsample before decoding, JPEG
/// at most 128px and 60KB. Only an explicit profile Save persists this draft.
func contactAvatarDataURL(_ data: Data) -> String? {
    guard data.count <= 20 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
          ] as CFDictionary),
          let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85),
          jpeg.count <= 60 * 1024 else { return nil }
    return "data:image/jpeg;base64," + jpeg.base64EncodedString()
}

struct EmployeeProfilePanel: View {
    let id: String?
    let api: WandAPI
    @ObservedObject var directory: ContactsStore
    var onMessage: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var model: EmployeeProfileStore
    @State private var roleExpanded = false
    @State private var candidatesExpanded = false
    @State private var knowledgeExpanded = false
    @State private var confirmAction: String?
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var avatarMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduced

    init(id: String?, api: WandAPI, directory: ContactsStore, onMessage: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.id = id; self.api = api; self.directory = directory; self.onMessage = onMessage; self.onClose = onClose
        _model = StateObject(wrappedValue: EmployeeProfileStore(id: id, api: api))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ContactAvatar(id: model.employee?.id ?? "new", avatar: model.draft.avatar,
                              systemKey: model.employee?.systemKey, provider: model.draft.agents.first?.provider)
                Text(id == nil ? "新建硅基员工" : "员工资料").font(.headline)
                Spacer()
                Button("收起") { if !directory.busy { onClose() } }.disabled(directory.busy)
            }
            if model.loading && !model.ready { ProgressView().frame(height: 44) }
            if model.ready {
                VStack(alignment: .leading, spacing: 12) {
                    if model.builtin {
                        Text(model.draft.name).font(.title3.weight(.semibold))
                        Text(model.draft.duty).font(.subheadline)
                        Text("内置员工资料由服务端固定，可维护执行候选与系统调用历史保留上限。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(model.employee?.displayTags.joined(separator: " · ") ?? "")
                            .font(.caption).foregroundStyle(Theme.brand)
                    } else {
                        WandFormField("员工名字") {
                            TextField("员工名字", text: $model.draft.name)
                                .accessibilityIdentifier("contact-employee-name")
                        }
                        WandFormField("职责") {
                            TextField("描述这位员工负责什么", text: $model.draft.duty, axis: .vertical).lineLimit(2...5)
                                .accessibilityLabel("职责").accessibilityIdentifier("contact-employee-duty")
                        }
                        WandFormField("标签", hint: "用逗号分隔，最多 8 个，每个 20 字。") {
                            TextField("例如：开发，测试，设计", text: $model.draft.tagInput)
                                .accessibilityLabel("标签").accessibilityIdentifier("contact-employee-tags")
                        }
                        PhotosPicker(selection: $avatarPhoto, matching: .images) {
                            Label("上传头像", systemImage: "photo")
                        }.frame(minHeight: 44)
                        if let avatarMessage { Text(avatarMessage).font(.caption).foregroundStyle(Theme.danger) }
                        Menu("头像") {
                            Button("默认头像") { model.draft.avatar = "" }
                            ForEach(0..<ContactCatAvatar.coats.count) { shade in Button("猫咪 \(shade + 1)") { model.draft.avatar = "cat:\(shade)" } }
                        }
                    }
                    Divider().padding(.vertical, WandLayout.fieldGap)
                    WandFormField("并发任务上限", hint: "默认 2，可设 1–100；留空保存时恢复默认 2。超出上限的新派发显示为「排队中」，任务仍留在活动任务里；前序任务结束后按先后顺序自动开始。同一任务的多条派发不额外占用名额。") {
                        TextField("默认 2", text: $model.draft.maxConcurrentTasksInput)
                            .keyboardType(.numberPad).accessibilityLabel("并发任务上限")
                            .accessibilityIdentifier("employee-max-concurrent-tasks")
                    }
                    WandFormField("系统调用历史保留上限", hint: "0–10000，留空不限，0 不保留。仅保留标题生成等系统辅助功能的最新 N 条已结束记录，保存后永久清理超出部分。任务派发、agent 间调用（含决策）、手动聊天与运行中会话不计入，也不会清理。") {
                        TextField("留空表示不限", text: $model.draft.systemSessionLimitInput)
                            .keyboardType(.numberPad).accessibilityLabel("系统调用历史保留上限")
                            .accessibilityIdentifier("employee-system-session-limit")
                    }
                    DisclosureGroup("角色设定", isExpanded: $roleExpanded) {
                        if model.builtin {
                            Text(model.draft.prompt).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TextField("说明工作方式、边界和交付要求", text: $model.draft.prompt, axis: .vertical)
                                .lineLimit(4...10).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("员工角色设定")
                                .padding(.top, WandLayout.fieldGap)
                        }
                    }
                    DisclosureGroup("执行候选 · 按顺序降级", isExpanded: $candidatesExpanded) {
                        ContactCandidateEditor(agents: $model.draft.agents, catalog: model.catalog)
                            .padding(.top, WandLayout.fieldGap)
                    }
                }.disabled(model.busy || directory.editorBusy)
                HStack {
                    ContactActionButton(title: "保存", phase: model.phase, disabled: model.creationUnconfirmed || (directory.editorBusy && !model.busy)) {
                        model.save(onBusy: { directory.editorBusy = $0 }, onSaved: { directory.update($0) },
                                   onUnconfirmed: { directory.markUnconfirmed("new:employee") })
                    }
                    if let employee = model.employee, !employee.builtin {
                        Menu("管理") {
                            Button(employee.archived ? "恢复员工" : "归档员工") { confirmAction = employee.archived ? "unarchive" : "archive" }
                            Button("删除员工", role: .destructive) { confirmAction = "delete" }
                        }.disabled(model.busy || directory.editorBusy)
                    }
                }
                Text(model.message ?? " ").font(.caption)
                    .foregroundStyle(model.phase == .failed ? Theme.danger : Theme.success)
                    .frame(minHeight: 24, alignment: .leading)
                if let onMessage, model.employee != nil {
                    Button("发送消息", action: onMessage).frame(minHeight: 44).disabled(directory.busy)
                }
                if let employee = model.employee {
                    DisclosureGroup("独立知识库", isExpanded: $knowledgeExpanded) {
                        if knowledgeExpanded { ContactKnowledgePanel(employeeId: employee.id, api: api, directory: directory) }
                    }.disabled(model.busy || directory.editorBusy)
                }
            } else if let message = model.message {
                Text(message).foregroundStyle(Theme.danger).font(.caption)
                Button("重试加载资料") { Task { await model.load() } }
            }
        }
        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .buttonStyle(WandQuietButtonStyle())
        .animation(reduced ? nil : WandMotion.expansion, value: roleExpanded)
        .animation(reduced ? nil : WandMotion.expansion, value: candidatesExpanded)
        .animation(reduced ? nil : WandMotion.expansion, value: knowledgeExpanded)
        .task { await model.load(); directory.editorDirty = model.hasUnsavedChanges }
        .task(id: avatarPhoto) {
            guard let avatarPhoto else { return }
            let previous = model.draft.avatar
            avatarMessage = nil
            do {
                guard let data = try await avatarPhoto.loadTransferable(type: Data.self),
                      let value = contactAvatarDataURL(data) else {
                    if !Task.isCancelled { avatarMessage = "无法读取头像，请选择可用的图片。" }
                    return
                }
                guard !Task.isCancelled, !model.busy, model.draft.avatar == previous else { return }
                model.draft.avatar = value
            } catch {
                if !Task.isCancelled { avatarMessage = "头像读取失败，请重新选择。" }
            }
        }
        .onChange(of: model.draft) { _, _ in directory.editorDirty = model.hasUnsavedChanges }
        .onDisappear { model.close(); directory.editorDirty = false }
        .confirmationDialog("确认操作该员工？历史聊天不会改写。", isPresented: Binding(
            get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }
        ), titleVisibility: .visible) {
            Button("确认", role: .destructive) {
                guard let action = confirmAction, let employee = model.employee else { return }
                confirmAction = nil
                model.manage(action, onBusy: { directory.editorBusy = $0 }) {
                    directory.removedEmployee(employee.id); directory.refreshIfVisible(); onClose()
                }
            }
            Button("取消", role: .cancel) { confirmAction = nil }
        }
    }
}

struct ContactKnowledgePanel: View {
    let employeeId: String
    let api: WandAPI
    @ObservedObject var directory: ContactsStore
    @State private var entries: [EmployeeKnowledgeEntry] = []
    @State private var total = 0
    @State private var query = ""
    @State private var text = ""
    @State private var error: String?
    @State private var phase = ComposerSendPhase.idle
    @State private var confirmClear = false
    private var unconfirmed: Bool { directory.unconfirmedActions.contains("knowledge:" + employeeId) }
    @State private var generation = 0
    @State private var loading = false
    @State private var active = true
    @State private var mutationAdding = false
    @State private var textRevision = 0
    private var busy: Bool { loading || phase == .sending }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WandFormField("搜索知识") {
                TextField("搜索该员工知识", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { Task { await load() } }
            }.disabled(phase == .sending)
            HStack {
                Button("搜索") { Task { await load() } }.disabled(busy)
                Button("刷新") { Task { await load() } }.disabled(busy)
            }.disabled(phase == .sending)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.content).font(.caption).textSelection(.enabled)
                            Button("删除此条", role: .destructive) { remove(entry.id) }.disabled(busy)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if entries.isEmpty { Text(loading ? "正在读取…" : "没有匹配的知识").font(.caption).foregroundStyle(Theme.textSecondary) }
                }
            }.frame(height: 240)
            Text("\(total)/200条 · 仅属于该员工，不读取其他员工或私聊。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            WandFormField("添加明确知识", hint: "最多 4000 字符。") {
                TextField("希望这位员工记住什么？", text: Binding(
                    get: { text }, set: { text = $0; textRevision += 1 }
                ), axis: .vertical).lineLimit(2...6).accessibilityLabel("添加明确知识")
            }
            HStack {
                ContactActionButton(title: "记住", phase: phase, disabled: loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unconfirmed) { remember() }
                Spacer()
                Button("清空", role: .destructive) { confirmClear = true }.disabled(busy || total == 0)
            }
            if unconfirmed {
                Text("添加结果未确认，请刷新并核对该员工的知识。").font(.caption).foregroundStyle(Theme.danger)
                Button("我已核对，开始新的知识添加") { directory.acknowledgedUnconfirmed("knowledge:" + employeeId) }.font(.caption)
            }
            Text(error ?? " ").font(.caption).foregroundStyle(phase == .failed ? Theme.danger : Theme.textSecondary)
                .frame(minHeight: 24)
        }
        .task(id: query) {
            active = true
            if !query.isEmpty { try? await Task.sleep(nanoseconds: WandMotion.searchDebounce) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .onChange(of: query) { _, _ in generation += 1 }
        .onDisappear {
            active = false; generation += 1
            if phase == .sending && mutationAdding { directory.markUnconfirmed("knowledge:" + employeeId) }
        }
        .confirmationDialog("清空该员工的全部知识？其他员工和聊天历史不受影响。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空该员工知识", role: .destructive) { remove(nil) }
            Button("取消", role: .cancel) {}
        }
    }
    private func load() async {
        guard active, phase != .sending else { return }
        generation += 1; let request = generation; let search = query; loading = true
        do {
            let page = try await api.contactKnowledge(employeeId: employeeId, query: search)
            guard active, request == generation, query == search, !Task.isCancelled else { return }
            entries = page.entries; total = page.total; error = nil
        } catch { if request == generation { self.error = error.localizedDescription } }
        if request == generation { loading = false }
    }
    private func remember() {
        guard !busy, !unconfirmed else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, content.utf16.count <= 4000 else { phase = .failed; error = "知识不能为空且最多4000个字符。"; return }
        generation += 1; let request = generation; let revision = textRevision
        phase = .sending; mutationAdding = true; error = nil; directory.editorBusy = true
        Task {
            defer { directory.editorBusy = false }
            do {
                let entry = try await api.addContactKnowledge(employeeId: employeeId, text: content)
                guard entry.employeeId == employeeId else { throw WandAPI.APIError.network("知识回执归属错误") }
                guard request == generation else { return }
                if textRevision == revision { text = "" }
                phase = .sent
                await load()
            } catch {
                guard request == generation else { return }
                phase = .failed
                if !isDefiniteInputRejection(error) { directory.markUnconfirmed("knowledge:" + employeeId) }
                self.error = unconfirmed ? "添加结果未确认，请刷新核对，勿重复添加。" : error.localizedDescription
            }
        }
    }
    private func remove(_ entryId: String?) {
        guard !busy else { return }
        generation += 1; let request = generation; phase = .sending; mutationAdding = false; directory.editorBusy = true
        Task {
            defer { directory.editorBusy = false }
            do {
                try await api.deleteContactKnowledge(employeeId: employeeId, entryId: entryId)
                guard request == generation else { return }
                phase = .sent; await load()
            } catch {
                guard request == generation else { return }
                phase = .failed; self.error = error.localizedDescription
            }
        }
    }
}


struct ContactExecutionSubjectPicker: View {
    @Binding var subject: ContactExecutionSubject?
    let employees: [SiliconEmployee]
    var teams: [ContactTeam] = []
    var teamAllowed = false
    var loading = false
    var error: String?
    var onRetry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("执行主体", selection: $subject) {
                Text("CLI 工具").tag(ContactExecutionSubject?.none)
                ForEach(contactOrderedEmployees(employees).filter { !$0.archived && !$0.agents.isEmpty }) { employee in
                    Text("员工 · " + employee.name).tag(ContactExecutionSubject?.some(ContactExecutionSubject(type: "employee", id: employee.id)))
                }
                if teamAllowed {
                    ForEach(contactOrderedTeams(teams)) { team in
                        Text("团队 · " + team.name).tag(ContactExecutionSubject?.some(ContactExecutionSubject(type: "team", id: team.id)))
                    }
                }
                if let subject, !available(subject) { Text("原选择已不可用，请重新选择").tag(Optional(subject)) }
            }
            if let subject, let employee = employees.first(where: { $0.id == subject.id && subject.type == "employee" }) {
                HStack(spacing: 10) {
                    ContactAvatar(id: employee.id, avatar: employee.avatar, systemKey: employee.systemKey, provider: employee.agents.first?.provider)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(employee.name).font(.subheadline.weight(.semibold))
                        Text(employee.duty).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                        Text(employee.agents.map { (WandProvider(rawValue: $0.provider)?.title ?? $0.provider) + " · " + $0.model }.joined(separator: " → "))
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if !teamAllowed && !teams.isEmpty {
                Text("AI 团队需要选择已有的非全局项目，并使用结构化会话。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if loading { ProgressView().frame(height: 24) }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
                if let onRetry { Button("重试通讯录", action: onRetry).font(.caption) }
            }
        }
    }
    private func available(_ subject: ContactExecutionSubject) -> Bool {
        switch subject.type {
        case "employee": return employees.contains { $0.id == subject.id && !$0.archived && !$0.agents.isEmpty }
        case "team": return teamAllowed && teams.contains { $0.id == subject.id }
        case "cli": return WandProvider.normalizedID(subject.id) != nil
        default: return false
        }
    }
}
