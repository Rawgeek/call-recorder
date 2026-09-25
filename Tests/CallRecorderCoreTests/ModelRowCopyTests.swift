import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

/// What the models pane writes under a model's name.
///
/// The row is where a person reads what a copy is before deleting or reinstalling it, and the size
/// is a number the pane can state wrongly while everything still compiles. The copy is checked here
/// rather than only in a render, which no test reads.
struct ModelRowCopyTests {
    @Test("an installed row names the copy and what it takes on disk")
    func installedRowNamesTheCopyAndItsSize() {
        let detail = ModelSettingsView.installedComponentDetail(
            versionLabel: "1.7B, 8-bit, MLX",
            bytes: 2_458_260_000
        )

        #expect(detail.contains("1.7B, 8-bit, MLX"))
        #expect(detail.contains("2.3 GiB on disk"))
    }

    @Test("a copy smaller than a gibibyte is named in mebibytes")
    func smallCopyIsNamedInMebibytes() {
        let detail = ModelSettingsView.installedComponentDetail(
            versionLabel: "300M, q4, 256 dimensions",
            bytes: 200 * 1_048_576
        )

        #expect(detail.contains("200 MiB on disk"))
    }
}
