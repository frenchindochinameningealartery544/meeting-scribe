import Foundation

/// Local LLMs used for transcript summarization. Identified by their
/// HuggingFace repo ID — MLXLLM loads them through the standard
/// `LLMModelFactory.shared.loadContainer(configuration:)` pathway.
enum LanguageModel: String, CaseIterable, Codable, Identifiable, Hashable {
    case qwen3_5_4b_mlx_8bit      = "mlx-community/Qwen3.5-4B-8bit"
    case qwen3_5_9b_mlx_4bit      = "mlx-community/Qwen3.5-9B-MLX-4bit"

    var id: String { rawValue }
    var repoID: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     "Qwen3.5-4B 8-bit (~1.5 GB)"
        case .qwen3_5_9b_mlx_4bit:     "Qwen3.5-9B (~5 GB — better quality)"
        }
    }

    var approxDownloadGB: Double {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     1.5
        case .qwen3_5_9b_mlx_4bit:     5.0
        }
    }

    var approxActiveMemoryGB: Double {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     4.0
        case .qwen3_5_9b_mlx_4bit:     7.0
        }
    }

    var supportedLanguages: Set<TranscriptionLanguage> {
        switch self {
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:     [.english, .ukrainian]
        }
    }

    var shortName: String {
        switch self {
        case .qwen3_5_4b_mlx_8bit:     "qwen3.5-4b-8bit"
        case .qwen3_5_9b_mlx_4bit:     "qwen3.5-9b"
        }
    }

    /// Qwen3 / Qwen3.5 ship a hybrid reasoning mode that emits `<think>…</think>`
    /// tool-thought blocks before the answer. For summarization we only want the
    /// final answer, so we pass `enable_thinking=false` through the chat template
    /// context and also strip any leaked thought tags at display time.
    var usesThinkingMode: Bool {
        switch self {
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:     true
        }
    }
}
