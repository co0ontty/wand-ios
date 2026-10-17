import SwiftUI

/// The same List owns every row; explicit insets keep labels moving inward at each level.
enum WorkspaceTreeLevel: CGFloat {
    case directory = 16, task = 32, session = 60
}

extension View {
    func workspaceTreeRow(_ level: WorkspaceTreeLevel) -> some View {
        listRowInsets(EdgeInsets(top: 2, leading: level.rawValue, bottom: 2, trailing: 12))
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
    }
}

struct WorkspaceDirectoryLabel: View {
    let group: TaskDirectoryGroup
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sessions: [WorkspaceSessionSummary] { group.tasks.flatMap(\.sessions) + group.standaloneSessions }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(group.isGlobal ? Theme.textSecondary : Theme.brand)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.workspaceName.isEmpty ? "任务目录" : group.workspaceName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .accessibilityIdentifier("workspace-name-" + group.id)
                if !group.isGlobal, let path = TaskListPresentation.directoryPathCaption(name: group.workspaceName, cwd: group.workspaceCwd) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(group.workspaceCwd)
                }
                Text("\(group.tasks.count) 个任务 · " + HomePresentation.sessionSummary(sessions))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }
}

struct WorkspaceSessionLabel: View {
    let session: WorkspaceSessionSummary
    let title: String
    let selected: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            BrandLogo(provider: session.provider ?? "terminal", color: selected ? Theme.brand : Theme.textSecondary)
                .frame(width: 16, height: 16)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(session.providerLabel + (session.sessionKind == "pty" ? " · 终端" : ""))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if dynamicTypeSize.isAccessibilitySize { status }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize { status }
        }
        .multilineTextAlignment(.leading)
    }

    @ViewBuilder private var status: some View {
        if HomePresentation.pulse(session) != .quiet || session.isJustCompleted {
                Text(session.isJustCompleted && HomePresentation.pulse(session) == .quiet ? "刚完成" : HomePresentation.statusLabel(session.activityStatus))
                    .font(.caption)
                    .foregroundStyle(HomePresentation.pulse(session) == .needsYou ? Theme.warning : Theme.success)
                    .fixedSize()
        }
    }
}

struct HomeSectionHeader: View {
    let title: String
    @Binding var foldRaw: String
    var onCreate: (() -> Void)? = nil
    var creatingExpanded = false
    var disabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                titleLabel.fixedSize()
                Spacer(minLength: 4)
                foldPicker.frame(width: 166)
                createButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { titleLabel; Spacer(minLength: 4); createButton }
                foldPicker
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
    }

    private var titleLabel: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
    }

    private var foldPicker: some View {
        Picker("\(title)显示方式", selection: $foldRaw) {
            ForEach(HomeFoldMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
    }

    @ViewBuilder private var createButton: some View {
        if let onCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .rotationEffect(.degrees(creatingExpanded ? 45 : 0))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.brand)
                .disabled(disabled)
                .accessibilityLabel(creatingExpanded ? "收起新建工作区" : "新建工作区")
                .animation(reduceMotion ? nil : WandMotion.stateSwap, value: creatingExpanded)
        }
    }
}

struct HomeRecentGroupHeader: View {
    let group: HomeRecentGroup
    let expanded: Bool
    let onToggle: (() -> Void)?
    var onCreate: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let onToggle {
                Button(action: onToggle) {
                    headerContent(showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title)，\(group.conversations.count) 个会话，\(expanded ? "收起" : "展开")")
            } else {
                headerContent(showsDisclosure: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.title)，\(group.conversations.count) 个会话")
            }
            if let onCreate {
                Button(action: onCreate) { Image(systemName: "plus").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundColor(Theme.brand).accessibilityLabel("新建空白终端")
            }
        }.padding(.vertical, 4)
    }

    private func headerContent(showsDisclosure: Bool) -> some View {
        HStack(spacing: 10) {
            avatar
            Text(group.title).font(.wand(size: 14, weight: .semibold)).lineLimit(1)
            Text("\(group.conversations.count)").font(.caption).foregroundColor(Theme.textMuted)
            Spacer(minLength: 2)
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
        }
        .foregroundColor(Theme.textPrimary)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        if group.kind == .employee || group.kind == .team {
            ContactAvatar(
                id: group.employeeId ?? group.id,
                avatar: group.avatar ?? "",
                systemKey: group.employeeSystemKey,
                team: group.kind == .team,
                size: 28
            )
        } else if group.kind == .cli {
            BrandLogo(provider: group.conversations.first?.session.provider ?? "terminal", color: Theme.brand)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: group.kind == .team ? "person.3" : (group.kind == .employee ? "person.crop.circle" : "terminal"))
                .foregroundColor(Theme.brand).frame(width: 32, height: 32)
                .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
