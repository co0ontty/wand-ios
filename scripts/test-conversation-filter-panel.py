#!/usr/bin/env python3
"""Source-layout contracts only; not a substitute for native popover/device tests."""
import pathlib
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / "Wand/ConversationViews.swift").read_text()
PANEL = SOURCE.split("private struct ConversationFilterPanel: View {", 1)[1].split("private struct ConversationWorkspaceFilterPicker: View {", 1)[0]
PICKER = SOURCE.split("private struct ConversationWorkspaceFilterPicker: View {", 1)[1].split("struct ConversationGroupPanel: View {", 1)[0]
PRIMARY = PANEL.split("private var primaryFields: some View {", 1)[1].split("private var secondaryFields: some View {", 1)[0]
SECONDARY = PANEL.split("private var secondaryFields: some View {", 1)[1].split("private func fieldLabel", 1)[0]


class ConversationFilterPanelContracts(unittest.TestCase):
    def test_three_peer_fields_stay_in_one_non_scrolling_row(self):
        self.assertIn("HStack(alignment: .top, spacing: 8)", PRIMARY)
        for name in ("stage", "workspace", "archive"):
            self.assertIn(f'conversation-filter-{name}"', PRIMARY)
        self.assertNotIn("ScrollView", PANEL)
        self.assertNotIn("dynamicTypeSize", PANEL)
        self.assertNotIn("ViewThatFits", PRIMARY)
        self.assertEqual(PRIMARY.count(".frame(minWidth: 0, maxWidth: .infinity)"), 3)
        # Static width budget, not measured SwiftUI geometry.
        for viewport in (320, 390):
            width = min(340, max(240, viewport - 32))
            self.assertGreaterEqual((width - 24 - 2 * 8) / 3, 44)

    def test_native_selectors_keep_secondary_options_out_of_primary_row(self):
        self.assertIn('Picker("任务状态", selection: $draft.stage)', PRIMARY)
        self.assertIn('Picker("归档范围", selection: $draft.archive)', PRIMARY)
        self.assertIn('Picker("消息范围", selection: $tier)', SECONDARY)
        self.assertIn("Toggle(isOn: $draft.activeOnly)", SECONDARY)
        self.assertNotIn("$tier", PRIMARY)
        self.assertNotIn("$draft.activeOnly", PRIMARY)
        self.assertIn(".lineLimit(1).truncationMode(.tail)", PANEL)
        for value in ("draft.stage.title", "workspaceTitle", "draft.archive.title"):
            self.assertIn(f".accessibilityValue({value})", PRIMARY)

    def test_workspace_search_belongs_only_to_nested_popover(self):
        self.assertIn(".popover(isPresented: $workspaceOpen", PRIMARY)
        self.assertIn(".presentationCompactAdaptation(.popover)", PRIMARY)
        self.assertNotIn("TextField(", PANEL)
        self.assertIn('HomeSearchField(placeholder: "搜索工作区"', PICKER)
        self.assertIn("ScrollView", PICKER)
        self.assertIn("minHeight: 44", PICKER)
        self.assertNotIn("fullScreenCover", PANEL + PICKER)
        self.assertNotIn(".sheet(", PANEL + PICKER)

    def test_close_is_scoped_and_apply_still_owned_by_parent(self):
        self.assertIn("if workspaceOpen { workspaceOpen = false } else { onCancel() }", PANEL)
        self.assertIn("onClose: { workspaceOpen = false }", PANEL)
        self.assertIn('.onKeyPress(.escape) { onClose(); return .handled }', PICKER)
        self.assertIn('Button("返回", systemImage: "chevron.left", action: onClose)', PICKER)
        self.assertIn("selection = value\n            onClose()", PICKER)
        self.assertNotIn("onCancel", PICKER)
        self.assertNotIn("onApply", PICKER)
        self.assertNotIn(".onTapGesture", PANEL + PICKER)
        self.assertIn("draft = ConversationListFilters(); tier = .all", PANEL)
        self.assertIn('Button(action: onApply)', PANEL)
        self.assertIn('Text("应用筛选").frame(maxWidth: .infinity, minHeight: 44)', PANEL)
        self.assertIn("if !open { filterDraft = filters; tierDraft = tier }", SOURCE)


if __name__ == "__main__":
    unittest.main()
