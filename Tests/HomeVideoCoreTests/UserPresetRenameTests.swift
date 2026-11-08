import XCTest
@testable import HomeVideoCore

/// A user preset can be renamed and deleted, the file on disk follows, a name in use gets
/// " 2", and the Look picker lists the built-in Looks before the user's presets.
@MainActor
final class UserPresetRenameTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("homevideo-presets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let folder {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        Looks.user = []
    }

    /// Rental with a moved slider, so the preset matches no built-in Look.
    func rentalChain(cut: Double = 2.137) -> SignalChain {
        let chain = SignalChain.standard()
        Presets(vhs: chain.vhs!, audio: chain.audio).setLook(Looks.look(id: "rental")!)
        chain.vhs!.luma.setParameter("cut", to: .float(cut))
        return chain
    }

    func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testRenameMovesTheFileAndKeepsTheContents() throws {
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Warm Rental", chain: rentalChain())
        let before = try json(saved.url)

        let renamed = try store.rename(saved, to: "Porch Tape")

        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path), "the old file is gone")
        XCTAssertEqual(renamed.url.lastPathComponent, "Porch Tape.homevideopreset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
        XCTAssertEqual(renamed.name, "Porch Tape")
        XCTAssertEqual(renamed.id, UserPresets.idPrefix + "Porch Tape")

        var after = try json(renamed.url)
        XCTAssertEqual(after["name"] as? String, "Porch Tape")
        var expected = before
        expected["name"] = nil
        after["name"] = nil
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: expected),
                       "every key but the name is kept")
        XCTAssertEqual(renamed.look.overrides, saved.look.overrides, "the preset applies the same values")
        XCTAssertEqual(store.presets.map(\.name), ["Porch Tape"])
        XCTAssertEqual(Looks.user.map(\.id), [renamed.id], "the picker follows")
    }

    func testRenameKeepsTheChainReadingBackAsThePreset() throws {
        let store = UserPresets(folder: folder)
        let chain = rentalChain()
        let presets = Presets(vhs: chain.vhs!, audio: chain.audio)
        let saved = try store.save(name: "Warm Rental", chain: chain)
        XCTAssertEqual(presets.look?.id, saved.id)
        let renamed = try store.rename(saved, to: "Porch Tape")
        XCTAssertEqual(presets.look?.id, renamed.id, "the chosen preset stays chosen under its new name")
    }

    func testRenameToANameInUseGetsTwo() throws {
        let store = UserPresets(folder: folder)
        _ = try store.save(name: "Porch Tape", chain: rentalChain(cut: 2.0))
        let other = try store.save(name: "Warm Rental", chain: rentalChain(cut: 2.2))

        let renamed = try store.rename(other, to: "Porch Tape")
        XCTAssertEqual(renamed.name, "Porch Tape 2")
        XCTAssertEqual(renamed.url.lastPathComponent, "Porch Tape 2.homevideopreset")
        XCTAssertEqual(store.presets.map(\.name), ["Porch Tape", "Porch Tape 2"])

        let third = try store.save(name: "Third", chain: rentalChain(cut: 2.4))
        XCTAssertEqual(try store.rename(third, to: "porch tape").name, "porch tape 3",
                       "a name in use in any case gets the next number")
        XCTAssertEqual(store.presets.count, 3, "nothing was replaced")
    }

    func testRenameToItsOwnNameChangesNothingAndACaseChangeRenames() throws {
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Porch Tape", chain: rentalChain())
        XCTAssertEqual(try store.rename(saved, to: "  Porch Tape "), saved)
        let lower = try store.rename(saved, to: "porch tape")
        XCTAssertEqual(lower.name, "porch tape")
        XCTAssertEqual(store.presets.map(\.name), ["porch tape"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, ["porch tape.homevideopreset"])
    }

    func testRenameRefusesABadNameAndAnUnwritableFolder() throws {
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Porch Tape", chain: rentalChain())
        XCTAssertThrowsError(try store.rename(saved, to: "a/b"))
        XCTAssertThrowsError(try store.rename(saved, to: "   "))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try store.rename(saved, to: "Other"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path), "the file keeps its name")
        XCTAssertEqual(store.presets.map(\.name), ["Porch Tape"])
    }

    func testDeleteRemovesTheFile() throws {
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Porch Tape", chain: rentalChain())
        try store.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertTrue(Looks.user.isEmpty)
        XCTAssertTrue(UserPresets.pickerOrder(user: store.presets).user.isEmpty, "no separator without presets")
    }

    func testDeleteFallsBackToTheLookThePresetWasBuiltOn() throws {
        let store = UserPresets(folder: folder)
        let saved = try store.save(name: "Porch Tape", chain: rentalChain())
        XCTAssertEqual(UserPresets.baseLook(of: saved).id, "rental")

        let fresh = SignalChain.standard()
        Presets(vhs: fresh.vhs!, audio: fresh.audio).setLook(Looks.look(id: "clean-sp")!)
        let unchanged = try store.save(name: "Plain", chain: fresh)
        XCTAssertEqual(UserPresets.baseLook(of: unchanged).id, "clean-sp")
    }

    func testThePickerPutsUserPresetsAfterTheBuiltIns() throws {
        let store = UserPresets(folder: folder)
        _ = try store.save(name: "Zebra", chain: rentalChain(cut: 2.0))
        _ = try store.save(name: "apple", chain: rentalChain(cut: 2.2))
        _ = try store.save(name: "Mango 10", chain: rentalChain(cut: 2.4))
        _ = try store.save(name: "Mango 9", chain: rentalChain(cut: 2.6))

        let order = UserPresets.pickerOrder(user: store.presets.reversed())
        // The built-in Looks come in the menu's sections, every one of them once.
        let builtIn = order.builtIn.flatMap(\.looks)
        XCTAssertEqual(order.builtIn.map(\.category), [.tape, .film, .telecine, .display], "the sections in the menu's order")
        XCTAssertEqual(builtIn.map(\.id), Looks.grouped.flatMap(\.looks).map(\.id), "the built-in Looks first, in their sections")
        XCTAssertEqual(Set(builtIn.map(\.id)), Set(Looks.all.map(\.id)), "every built-in Look, once")
        XCTAssertEqual(builtIn.count, Looks.all.count)
        XCTAssertEqual(order.user.map(\.name), ["apple", "Mango 9", "Mango 10", "Zebra"], "then the presets by name")
        XCTAssertTrue(Set(builtIn.map(\.id)).isDisjoint(with: order.user.map(\.id)))
    }
}
