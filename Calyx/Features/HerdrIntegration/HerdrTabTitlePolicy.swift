// HerdrTabTitlePolicy.swift
// Calyx
//
// Decides HerdrNativeTabPlan.title for a newly opened herdr workspace,
// extracted as an explicit, pure decision mirroring HerdrChildExitedPolicy's
// own extraction shape: HerdrTabCoordinator.openWorkspace resolves the
// workspace's own label via workspace.get (WorkspaceInfo's own required,
// non-nullable "label" field -- herdr api schema --json) before calling
// in, rather than this function reaching into the wire response itself.
//
// A workspace created outside any project directory carries label "~";
// one created inside a project directory carries that directory's own
// name (e.g. "Calyx") -- either is preferred over the bare workspace id
// ("wB", "wJ") whenever present. `label` is typed `String?` here, wider
// than WorkspaceInfo's own non-optional field: the schema's required,
// non-nullable guarantee covers only a conforming response, and this
// policy still needs a defined answer for a caller with no label to
// offer.
//

import Foundation

enum HerdrTabTitlePolicy {

    /// `label` present and non-blank after trimming whitespace -> `label`
    /// itself, unmodified (never the trimmed copy). `nil`, or blank
    /// after trimming, -> `workspaceID`, so a tab always has a name.
    static func title(label: String?, workspaceID: String) -> String {
        guard let label, hasNonBlankLabel(label) else {
            return workspaceID
        }
        return label
    }

    /// The blank rule `title(label:workspaceID:)` uses: `label` present
    /// and non-blank after trimming whitespace and newlines.
    static func hasNonBlankLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
