import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Constructed performance fixture, not a claim about an unavailable 1.0.9 base.
/// Start from a stopped, current c14 bottle; change exactly one installed target
/// and its authenticated old catalogue. The target bytes come from R4, not invented data.
enum BottleSingleFileFixture {
    /// APFS clones have new file identities and a new prefix path. Verify all
    /// bytes before rebinding the TEST fixture; production relocation checks stay unchanged.
    static func rebindClone(prefix: URL, source: URL, out: URL) throws {
        let scope = "/c15/bottle-update-20261014/work/arms/"
        try #require(prefix.path.contains(scope) && source.path.contains(scope) && prefix != source)
        let name = ".macrunner-bottle.json"
        let sourceMarker = try Data(contentsOf: source.appendingPathComponent(name))
        let markerURL = prefix.appendingPathComponent(name)
        try #require(try Data(contentsOf: markerURL) == sourceMarker)
        var marker = try #require(JSONSerialization.jsonObject(with: sourceMarker) as? [String: Any])
        let encoded = try JSONSerialization.data(withJSONObject: try #require(marker["updateInputs"]))
        var catalogue = try JSONDecoder().decode(BottleUpdateCatalogue.self, from: encoded)
        try #require(try catalogue.delta(from: catalogue, prefix: source) == [])
        catalogue.ownership = try catalogue.adoptingLegacy(prefix: prefix).get()
        marker["updateInputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalogue))
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .prettyPrinted])
            .write(to: markerURL, options: .atomic)
        try #require(try Data(contentsOf: source.appendingPathComponent(name)) == sourceMarker)
        let proof: [String: Any] = ["source": source.path, "source_marker_sha256": BottleUpdateCatalogue.digest(sourceMarker),
            "cloned_targets_verified_by_sha256": catalogue.files.count,
            "changed_field": "updateInputs.ownership", "production_relocation_checks_changed": false]
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .prettyPrinted])
            .write(to: out.appendingPathComponent("clone-rebind-proof.json"), options: .atomic)
    }

    static func prepare(engine: BundledEngine, prefix: URL, out: URL, oldModule: URL) throws {
        let fm = FileManager.default
        try #require(oldModule.path.contains("/bottle-update-20261014/repair-r1/"))
        try #require(BottleSetup.isReady(engine: engine, prefix: prefix))
        let manifest = try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))
        var object = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        var declared = try #require(object["files"] as? [String: String])
        let source = "wine/lib/wine/aarch64-windows/xtajit64.dll"
        let target = "drive_c/windows/system32/xtajit64.dll"
        let beforeHash = try BottleUpdateCatalogue.digest(oldModule)
        let afterHash = try #require(declared[source])
        try #require(beforeHash != afterHash)
        declared[source] = beforeHash; object["files"] = declared
        let beforeManifest = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let beforeStamp = BottleUpdateCatalogue.digest(beforeManifest)
        let markerURL = prefix.appendingPathComponent(".macrunner-bottle.json")
        var marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        let layers = try #require(marker["layers"] as? [String])
        let root = BottleSetup.engineRootPath(engine)
        let before = try #require(try BottleUpdateCatalogue.make(manifest: beforeManifest, engineRoot: root,
            prefix: prefix, graphics: engine.graphics, layers: layers))
        let current = try #require(try BottleUpdateCatalogue.make(manifest: manifest, engineRoot: root,
            prefix: prefix, graphics: engine.graphics, layers: layers))
        try #require(current.files.keys.filter { before.files[$0] != current.files[$0] } == [target])
        let destination = prefix.appendingPathComponent(target)
        try fm.removeItem(at: destination); try fm.copyItem(at: oldModule, to: destination)
        let installed = try before.recordingInstallation(prefix: prefix)
        marker["engine"] = beforeStamp
        marker["updateInputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(installed))
        var wic = try #require(marker["wicRegistration"] as? [String: String]); wic["engine"] = beforeStamp
        marker["wicRegistration"] = wic
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .prettyPrinted]).write(to: markerURL, options: .atomic)
        try beforeManifest.write(to: out.appendingPathComponent("single-file-old-ENGINE.json"))
        let proof: [String: Any] = ["constructed_fixture": true, "real_release_baseline": false,
            "changed_targets": [target], "target_count": current.files.count,
            "before_sha256": beforeHash, "after_sha256": afterHash, "before_engine": beforeStamp,
            "after_engine": current.engine, "registration_class_changed": false]
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .prettyPrinted])
            .write(to: out.appendingPathComponent("single-file-fixture.json"))
    }
}
