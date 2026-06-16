@testable import DistillCore
import MLXLLM
import XCTest

/// Ungated structural tests for the patched gemma4 port (no checkpoint required). These prove the
/// registration wiring and that both `// RC FIX` paths INSTANTIATE without the 4.3 GB model — the
/// numerical correctness is proven separately by the env-gated `DistillE4BModelLoadTests` /
/// `DistillE4BRawGenerationProbe`.
final class RCGemma4ModelOverrideTests: XCTestCase {
    /// A tiny gemma4 config: 4 layers with `num_kv_shared_layers: 2`, so the last two layers are
    /// KV-shared. Instantiating it exercises Fix A (KV-shared layers must allocate WITHOUT
    /// k_proj/v_proj/k_norm) and Fix B (`per_layer_model_projection` is a plain `Linear`). Dims are
    /// deliberately tiny so allocation is cheap.
    private static let tinyGemma4Config = """
    {"model_type":"gemma4","text_config":{
      "model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":4,
      "intermediate_size":128,"num_attention_heads":2,"head_dim":16,"global_head_dim":16,
      "num_key_value_heads":1,"num_kv_shared_layers":2,"hidden_size_per_layer_input":8,
      "vocab_size":128,"vocab_size_per_layer_input":128,"sliding_window":8,
      "layer_types":["sliding_attention","full_attention","sliding_attention","full_attention"]
    }}
    """.data(using: .utf8)!

    func test_registerInstallsPatchedGemma4CreatorThatInstantiatesWithoutCheckpoint() async throws {
        await RCGemma4ModelOverride.register()

        // The registry must now resolve `gemma4` to the patched model, and instantiating it must
        // succeed for a config WITH KV-shared layers — proving Fix A's optional projections and
        // Fix B's Linear allocate cleanly (a regression here would crash or throw at init).
        let model = try await LLMTypeRegistry.shared.createModel(
            configuration: Self.tinyGemma4Config, modelType: "gemma4")
        XCTAssertTrue(model is RCGemma4Model,
                      "WHY: register() must override the vendored gemma4 creator with the patched RCGemma4Model")
    }

    func test_patchedConfigDecodesNestedTextConfigFields() throws {
        // The wrapper config must read the nested `text_config` (Gemma 4 stores text params there);
        // a regression that read the top level would silently fall back to defaults.
        let configuration = try JSONDecoder().decode(RCGemma4Configuration.self, from: Self.tinyGemma4Config)
        XCTAssertEqual(configuration.textConfig.numHiddenLayers, 4)
        XCTAssertEqual(configuration.textConfig.numKvSharedLayers, 2)
        XCTAssertEqual(configuration.textConfig.hiddenSize, 64)
    }
}
