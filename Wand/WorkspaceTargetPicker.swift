import SwiftUI

struct WorkspaceTargetPicker: View {
    @ObservedObject var store: WorkspaceStore
    let taskId: String

    @Environment(\.dismiss) private var dismiss
    @State private var subject: ContactExecutionSubject?
    @State private var employees: [SiliconEmployee] = []
    @State private var contactsLoading = false
    @State private var contactsError: String?
    @State private var contactGeneration = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                WandAmbientBackground()
                ScrollView {
                    pickerFields
                        .padding(16)
                        .padding(.bottom, 76)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("工作窗口类型")
                }
                submitBar
            }
            .navigationTitle("新建工作窗口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        store.dismissTargetPicker()
                        dismiss()
                    }
                    .disabled(store.creating)
                }
            }
        }
        .interactiveDismissDisabled(store.creating)
        .task { await loadContacts() }
        .onDisappear { contactGeneration += 1 }
    }

    private var pickerFields: some View {
        VStack(spacing: 8) {
            ContactExecutionSubjectPicker(subject: Binding(get: { subject }, set: { value in
                subject = value
                if value?.type == "employee" { store.rememberCreationChoice(kind: .structured) }
            }), employees: employees, loading: contactsLoading, error: contactsError,
               onRetry: { Task { await loadContacts() } }).disabled(store.creating)
            if subject == nil {
            ForEach(WorkspaceSessionTarget.allCases) { target in
                targetRow(target)
            }
            if store.selectedTarget != .shell {
                kindPicker
            }
            }
            if store.unconfirmedWindowTasks.contains(taskId) {
                Text("创建结果未确认，请先刷新任务并核对会话。").font(.caption).foregroundStyle(Theme.danger)
                Button("我已核对，开始新的创建操作") { store.acknowledgeUnconfirmedWindow(taskID: taskId) }
                    .font(.caption).disabled(store.creating)
            }
            if let error = store.creationError {
                errorBanner(error)
                    .padding(.top, 8)
            }
        }
    }

    private func targetRow(_ target: WorkspaceSessionTarget) -> some View {
        let selected = store.selectedTarget == target
        return Button {
            guard !store.creating else { return }
            subject = nil; store.rememberCreationChoice(provider: target)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Theme.brand.opacity(0.12) : Theme.surface)
                    BrandLogo(
                        provider: target.provider?.rawValue ?? "terminal",
                        color: selected ? Theme.brand : Theme.textSecondary
                    )
                    .frame(width: 21, height: 21)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.title)
                        .font(.wand(size: 15, weight: .semibold))
                        .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                    Text(target.summary)
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(selected ? Theme.brand : Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.06) : Theme.surface.opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.creating)
        .accessibilityLabel(target.title)
        .accessibilityValue(target.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会话类型")
                .font(.wand(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 8)
            HStack(spacing: 8) {
                ForEach(WorkspaceSessionKind.allCases) { option in
                    let selected = store.selectedKind == option
                    Button {
                        guard !store.creating else { return }
                        if option != .structured { subject = nil }
                        store.rememberCreationChoice(kind: option)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.wand(size: 15, weight: .semibold))
                                .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                            Text(option.summary)
                                .font(.wand(size: 12))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Theme.brand.opacity(0.06) : Theme.surface.opacity(0.88))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.creating)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var submitBar: some View {
        Button {
            Task { await store.createSelectedWindow(expectedTaskId: taskId, employeeID: subject?.type == "employee" ? subject?.id : nil) }
        } label: {
            HStack(spacing: 8) {
                if store.creating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(store.creating ? "创建中…" : "创建 " + (employees.first { $0.id == subject?.id }?.name ?? store.selectedTarget.title))
                    .font(.wand(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(store.creating ? Theme.brand.opacity(0.55) : Theme.brand)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.creating || store.unconfirmedWindowTasks.contains(taskId) ||
                  (subject != nil && !employees.contains(where: { $0.id == subject?.id && !$0.archived && !$0.agents.isEmpty })))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .wandGlassSurface()
    }

    private func loadContacts() async {
        contactGeneration += 1; let generation = contactGeneration; contactsLoading = true
        do {
            let people = try await store.contactEmployeesForPicker()
            guard generation == contactGeneration, !Task.isCancelled else { return }
            employees = people; contactsError = nil
        } catch { if generation == contactGeneration { contactsError = error.localizedDescription } }
        if generation == contactGeneration { contactsLoading = false }
    }
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundColor(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.danger.opacity(0.10))
            )
    }
}
