import CodexKit
import XCTest

final class CodexModelTests: XCTestCase {
    func testCatalogContainsEveryBundledAndLiveCodexModel() {
        XCTAssertEqual(
            CodexModel.knownModels,
            [
                .gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
                .gpt55,
                .gpt54,
                .gpt54Mini,
                .gpt53CodexSpark,
                .gpt52,
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
                .gpt56Sol,
                .gpt56Terra,
                .gpt56Luna,
                .gpt55,
                .gpt54,
                .gpt54Mini,
                .gpt53CodexSpark,
            ]
        )
        XCTAssertFalse(CodexModel.userFacingModels.contains(.gpt52))
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
        XCTAssertEqual(sol.contextWindowTokenCount, 372_000)
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

    func testSparkMetadataAndEarlierModels() throws {
        let spark = try XCTUnwrap(CodexModel.gpt53CodexSpark.info)
        XCTAssertEqual(spark.model.rawValue, "gpt-5.3-codex-spark")
        XCTAssertEqual(spark.defaultReasoningEffort, .high)
        XCTAssertEqual(spark.contextWindowTokenCount, 128_000)
        XCTAssertEqual(spark.inputModalities, [.text])
        XCTAssertEqual(spark.availability, .researchPreview)
        XCTAssertEqual(
            spark.supportedReasoningEfforts,
            [.low, .medium, .high, .extraHigh]
        )

        for model in [CodexModel.gpt55, .gpt54, .gpt54Mini, .gpt52, .codexAutoReview] {
            let info = try XCTUnwrap(model.info)
            XCTAssertEqual(info.defaultReasoningEffort, .medium)
            XCTAssertEqual(
                info.supportedReasoningEfforts,
                [.low, .medium, .high, .extraHigh]
            )
            XCTAssertEqual(info.contextWindowTokenCount, 272_000)
            XCTAssertEqual(info.inputModalities, [.text, .image])
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
            model: .gpt53CodexSpark
        )
        XCTAssertEqual(threadConfiguration.model, CodexModel.gpt53CodexSpark.rawValue)
        XCTAssertEqual(threadConfiguration.codexModel, .gpt53CodexSpark)
        XCTAssertEqual(threadConfiguration.reasoningEffort, .high)

        threadConfiguration.codexModel = .gpt52
        XCTAssertEqual(threadConfiguration.model, CodexModel.gpt52.rawValue)

        let stringConfiguration = CodexResponsesBackendConfiguration(model: "gpt-5.5")
        XCTAssertEqual(stringConfiguration.reasoningEffort, .medium)
    }
}
