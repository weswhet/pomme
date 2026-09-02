import Testing

@Suite("TUI VM lifecycle actions")
struct TUIVMActionTests {
    @Test("Pause and Resume are explicit lifecycle actions with stable shortcuts")
    func pauseAndResumeActions() {
        let pause = TUIVMAction.pause.menuItem
        let resume = TUIVMAction.resume.menuItem

        #expect(pause.title == "Pause")
        #expect(pause.shortcut == "p")
        #expect(pause.detail.contains("running VM"))
        #expect(resume.title == "Resume")
        #expect(resume.shortcut == "r")
        #expect(resume.detail.contains("paused VM"))
    }

    @Test("TUI VM action inventory no longer exposes suspend")
    func actionInventoryRejectsSuspendVocabulary() {
        let items = TUIVMAction.allCases.map(\.menuItem)

        #expect(items.contains { $0.title == "Suspend" } == false)
        #expect(items.contains { $0.shortcut == "u" } == false)
        #expect(items.first(where: { $0.shortcut == "p" })?.title == "Pause")
        #expect(items.first(where: { $0.shortcut == "r" })?.title == "Resume")
    }

    @Test("Snapshots are available from the selected VM menu with a stable shortcut")
    func snapshotAction() {
        let snapshot = TUIVMAction.snapshots.menuItem

        #expect(snapshot.title == "Snapshots")
        #expect(snapshot.shortcut == "v")
        #expect(snapshot.detail.contains("named VM snapshots"))
        #expect(snapshot.role == .normal)
    }
}
