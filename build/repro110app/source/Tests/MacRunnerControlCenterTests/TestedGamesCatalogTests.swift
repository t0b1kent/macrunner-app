import Foundation
import Testing
@testable import MacRunnerControlCenter

struct TestedGamesCatalogTests {
    @Test func releaseScopeDoesNotPromoteHistoricalGameplay() throws {
        let factorio = try #require(GraphicsProfile.bundled.first { $0.id == "factorio" })
        #expect(factorio.known?.last?.reached == .notRechecked)
        #expect(factorio.known?.contains { $0.reached == .gameplay && $0.date == "2026-09-11" } == true)
        #expect(factorio.known?.contains { $0.reached == .fixture || $0.reached == .blocked } == false)
        let app = AppEntry.new(name: "Factorio", exePath: "/test/factorio.exe")
        #expect(GameStatus.confirmed(app)?.reached == .notRechecked)
        let elden = try #require(GraphicsProfile.bundled.first { $0.id == "elden-ring" })
        #expect(elden.known?.last?.date == "2026-09-23")
        #expect(elden.known?.last?.note?.contains("Tested & working") == true)
        #expect(elden.known?.last?.note?.contains("character missing") == false)
        for id in ["vampire-survivors", "doom-64", "dome-keeper"] {
            #expect(GraphicsProfile.bundled.first { $0.id == id }?.known?.last?.reached == .notRechecked)
        }
        #expect(GraphicsProfile.bundled.filter { $0.id == "indiana-jones-great-circle" }.count == 1)
        #expect(GraphicsProfile.bundled.first { $0.id == "heroes-iii" }?.known?.last?.note?.contains("Sound does not work correctly yet") == true)
    }
}
