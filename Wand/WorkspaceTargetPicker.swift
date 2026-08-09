import SwiftUI

struct WorkspaceTargetPicker: View {
    @ObservedObject var store: WorkspaceStore
    let taskId: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                WandAmbientBackground()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(WorkspaceSessionTarget.allCases) { target in
                            targetRow(target)
                        }
                        if let error = store.creationError {
                            errorBanner(error)
                                .padding(.top, 8)
                        }
                    }
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
    }

    private func targetRow(_ target: WorkspaceSessionTarget) -> some View {
        let selected = store.selectedTarget == target
        return Button {
            guard !store.creating else { return }
            store.selectedTarget = target
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(selected ? Theme.brand : Theme.textPrimary)
                    Text(target.summary)
                        .font(.system(size: 12))
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

    private var submitBar: some View {
        Button {
            Task { await store.createSelectedWindow(expectedTaskId: taskId) }
        } label: {
            HStack(spacing: 8) {
                if store.creating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(store.creating ? "创建中…" : "创建 \(store.selectedTarget.title)")
                    .font(.system(size: 15, weight: .semibold))
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
        .disabled(store.creating)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .wandGlassSurface()
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
