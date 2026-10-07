import SwiftUI

struct HomeSectionHeader: View {
    let title: String
    @Binding var foldRaw: String
    var onCreate: (() -> Void)? = nil
    var creatingExpanded = false
    var disabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
            Spacer(minLength: 4)
            Picker("\(title)显示方式", selection: $foldRaw) {
                ForEach(HomeFoldMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 166)
            .disabled(disabled)
            if let onCreate {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .rotationEffect(.degrees(creatingExpanded ? 45 : 0))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.brand)
                .disabled(disabled)
                .accessibilityLabel(creatingExpanded ? "收起新建工作区" : "新建工作区")
                .animation(reduceMotion ? nil : WandMotion.stateSwap, value: creatingExpanded)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
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
            Text(group.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
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
