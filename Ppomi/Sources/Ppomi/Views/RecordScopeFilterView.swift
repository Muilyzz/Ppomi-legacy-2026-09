import SwiftUI

/// Shared selectors for journals and spatial usages. The all option lists records; it never totals scopes.
struct RecordScopeFilterView: View {
    let scopes: [RecordScope]
    @Binding var filter: RecordScopeFilter

    private var owners: [String] {
        Array(Set(scopes.filter { filter.kind == nil || $0.kind == filter.kind }.compactMap(\.ownerID))).sorted()
    }
    private var businesses: [String] {
        Array(Set(scopes.filter { $0.kind == .business && (filter.ownerID == nil || $0.ownerID == filter.ownerID) }
            .compactMap(\.businessID))).sorted()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { kindPicker; ownerPicker; businessPicker }
            VStack(alignment: .leading, spacing: 8) { kindPicker; ownerPicker; businessPicker }
        }
        .font(.ppomi(1))
        .controlSize(.ppomiSmall)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("개인·사업 구분")
    }

    private var kindPicker: some View {
        Picker("구분", selection: Binding(get: { filter.kind }, set: {
            filter = RecordScopeFilter(kind: $0)
        })) {
            Text("전체").tag(nil as RecordScope.Kind?)
            Text("개인").tag(RecordScope.Kind.personal as RecordScope.Kind?)
            Text("사업").tag(RecordScope.Kind.business as RecordScope.Kind?)
            Text("미분류").tag(RecordScope.Kind.unclassified as RecordScope.Kind?)
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false).frame(minWidth: 280)
        .accessibilityIdentifier("record-scope-kind")
    }

    @ViewBuilder private var ownerPicker: some View {
        if !owners.isEmpty {
            Picker("주체", selection: Binding(get: { filter.ownerID }, set: {
                filter = RecordScopeFilter(kind: filter.kind, ownerID: $0)
            })) {
                Text("전체").tag(nil as String?)
                ForEach(owners, id: \.self) { Text($0).tag($0 as String?) }
            }.frame(maxWidth: 270).accessibilityIdentifier("record-scope-owner")
        }
    }

    @ViewBuilder private var businessPicker: some View {
        if filter.kind == .business, !businesses.isEmpty {
            Picker("사업", selection: $filter.businessID) {
                Text("전체").tag(nil as String?)
                ForEach(businesses, id: \.self) { Text($0).tag($0 as String?) }
            }.frame(maxWidth: 270).accessibilityIdentifier("record-scope-business")
        }
    }
}
