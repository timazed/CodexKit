import CodexKit
import XCTest

final class CodexModelTests: XCTestCase {
    func testCatalogContainsSupportedBundledModels() {
        XCTAssertEqual(
            CodexModel.knownModels,
            [
                .gpt6Astra,
                .gpt61Sol,
                .gpt6Sol,
                .gpt6Luna,
                .gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
                .daybreakBlueLatest,
                .daybreakRedLatest,
                .codexAutoReview,
            ]
        )
        XCTAssertEqual(Set(CodexModel.knownModels).count, CodexModel.catalog.count)

        for info in CodexModel.catalog {
            XCTAssertEqual(info.model.info, info)
        }
    }

    func testUserFacingModelsMatchCurrentCodexPicker() {
        XCTAssertEqual(
            CodexModel.userFacingModels,
            [
                .gpt6Astra,
                .gpt61Sol,
                .gpt6Sol,
                .gpt6Luna,
                .gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
            ]
        )
        for model in [CodexModel.daybreakBlueLatest, .daybreakRedLatest] {
            XCTAssertFalse(CodexModel.userFacingModels.contains(model))
        }
        XCTAssertFalse(CodexModel.userFacingModels.contains(.codexAutoReview))
        XCTAssertEqual(CodexModel.codexAutoReview.info?.availability, .internalUse)
    }

    func testCurrentModelMetadataMatchesCodexCatalog() throws {
        let sol = try XCTUnwrap(CodexModel.gpt56Sol.info)
        XCTAssertEqual(sol.defaultReasoningEffort, .low)
        XCTAssertEqual(
            sol.supportedReasoningEfforts,
            [.low, .medium, .high, .extraHigh, .max, .ultra]
        )
        XCTAssertEqual(sol.contextWindowTokenCount, 272_000)
        XCTAssertEqual(sol.inputModalities, [.text, .image])

        let terra = try XCTUnwrap(CodexModel.gpt56Terra.info)
        XCTAssertEqual(terra.defaultReasoningEffort, .medium)
        XCTAssertEqual(terra.supportedReasoningEfforts, sol.supportedReasoningEfforts)

        let luna = try XCTUnwrap(CodexModel.gpt56Luna.info)
        XCTAssertEqual(luna.defaultReasoningEffort, .medium)
        XCTAssertEqual(
            luna.supportedReasoningEfforts,
            [.low, .medium, .high, .extraHigh, .max]
        )
    }

    func testLegacyModelsAreAbsentFromBundledMetadataButStillDecode() throws {
        for identifier in ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark", "gpt-5.3-codex", "gpt-5.2"] {
            let model = CodexModel(rawValue: identifier)
            XCTAssertNil(model.info)
            XCTAssertFalse(CodexModel.knownModels.contains(model))
            XCTAssertFalse(CodexModel.userFacingModels.contains(model))
            XCTAssertEqual(try JSONDecoder().decode(CodexModel.self, from: JSONEncoder().encode(model)), model)
        }
    }

    func testUnknownModelRemainsUsableAndCodable() throws {
        let futureModel = CodexModel(rawValue: "gpt-6-codex")
        XCTAssertNil(futureModel.info)

        let encoded = try JSONEncoder().encode(futureModel)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"gpt-6-codex\"")
        XCTAssertEqual(try JSONDecoder().decode(CodexModel.self, from: encoded), futureModel)
    }

    func testTypedConfigurationUsesCatalogDefaults() {
        let backendConfiguration = CodexResponsesBackendConfiguration(model: .gpt56Terra)
        XCTAssertEqual(backendConfiguration.model, CodexModel.gpt56Terra.rawValue)
        XCTAssertEqual(backendConfiguration.codexModel, .gpt56Terra)
        XCTAssertEqual(backendConfiguration.reasoningEffort, .medium)

        var threadConfiguration = AgentThreadConfiguration(
            model: .gpt6Astra
        )
        XCTAssertEqual(threadConfiguration.model, CodexModel.gpt6Astra.rawValue)
        XCTAssertEqual(threadConfiguration.codexModel, .gpt6Astra)
        XCTAssertEqual(threadConfiguration.reasoningEffort, .low)

        threadConfiguration.codexModel = .gpt56Luna
        XCTAssertEqual(threadConfiguration.model, CodexModel.gpt56Luna.rawValue)

        let stringConfiguration = CodexResponsesBackendConfiguration(model: "gpt-5.5")
        XCTAssertEqual(stringConfiguration.reasoningEffort, .medium)
    }
}
