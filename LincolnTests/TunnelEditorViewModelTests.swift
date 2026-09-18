import XCTest
import LincolnCore
@testable import Lincoln

@MainActor
final class TunnelEditorViewModelTests: XCTestCase {
    func testDraftTracksChangesAndCommits() {
        let tunnel = TestFixtures.tunnel()
        let editor = TunnelEditorViewModel(tunnel: tunnel)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertNil(editor.commit())

        editor.draft.name = "Renamed"
        editor.userText = " alice "
        editor.portText = "2222"
        XCTAssertTrue(editor.hasChanges)
        XCTAssertTrue(editor.canSave)
        let committed = editor.commit()!
        XCTAssertEqual(committed.name, "Renamed")
        XCTAssertEqual(committed.user, "alice")
        XCTAssertEqual(committed.port, 2222)
        XCTAssertFalse(editor.hasChanges)
    }

    func testValidationBlocksSave() {
        let editor = TunnelEditorViewModel(tunnel: TestFixtures.tunnel())
        editor.portText = "abc"
        XCTAssertTrue(editor.validationErrors.contains("Port must be a number."))
        XCTAssertFalse(editor.canSave)
        editor.portText = ""
        editor.draft.host = ""
        XCTAssertTrue(editor.validationErrors.contains("Host is required."))
    }

    func testRevertRestoresOriginal() {
        let editor = TunnelEditorViewModel(tunnel: TestFixtures.tunnel())
        editor.draft.name = "changed"
        editor.identityFileText = "~/.ssh/key"
        editor.revert()
        XCTAssertEqual(editor.draft.name, "Gateway")
        XCTAssertEqual(editor.identityFileText, "")
        XCTAssertFalse(editor.hasChanges)
    }

    func testForwardAndOptionHelpers() {
        let editor = TunnelEditorViewModel(tunnel: TestFixtures.tunnel())
        editor.addForward(kind: .dynamic)
        XCTAssertEqual(editor.draft.forwards.map(\.listenPort), [1080, 1081])
        editor.addForward(kind: .local)
        XCTAssertEqual(editor.draft.forwards.last?.kind, .local)
        XCTAssertEqual(editor.draft.forwards.last?.targetHost, "localhost")
        editor.removeForward(id: editor.draft.forwards[1].id)
        XCTAssertEqual(editor.draft.forwards.count, 2)
        editor.addOption()
        XCTAssertEqual(editor.draft.extraOptions.count, 1)
        XCTAssertTrue(editor.validationErrors.contains { $0.contains("invalid name") })
        editor.removeOption(id: editor.draft.extraOptions[0].id)
        XCTAssertTrue(editor.configSnippet.hasPrefix("Host lincoln-gateway"))
        XCTAssertTrue(editor.commandPreview.contains("-D 1080"))
    }
}
