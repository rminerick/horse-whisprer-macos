import Foundation

struct ModelCatalogService {
    // Sizes and SHA-256 digests are the Git LFS object IDs Hugging Face reports
    // for ggerganov/whisper.cpp at `main` (read 2026-10-03). A download that
    // does not match is rejected instead of installed.
    let whisperModels: [ASRModelDescriptor] = [
        Self.model(id: "tiny.en", displayName: "Whisper tiny.en", fileName: "ggml-tiny.en.bin", languages: "English", diskSizeDescription: "75 MB", notes: "Fastest English-only model", sha256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f", sizeBytes: 77_704_715),
        Self.model(id: "tiny", displayName: "Whisper tiny", fileName: "ggml-tiny.bin", languages: "Multilingual", diskSizeDescription: "75 MB", notes: "Fastest multilingual model", sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", sizeBytes: 77_691_713),
        Self.model(id: "base.en", displayName: "Whisper base.en", fileName: "ggml-base.en.bin", languages: "English", diskSizeDescription: "142 MB", notes: "Good default for lower-memory Macs", isRecommended: true, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", sizeBytes: 147_964_211),
        Self.model(id: "base", displayName: "Whisper base", fileName: "ggml-base.bin", languages: "Multilingual", diskSizeDescription: "142 MB", notes: "Balanced multilingual baseline", sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", sizeBytes: 147_951_465),
        Self.model(id: "small.en", displayName: "Whisper small.en", fileName: "ggml-small.en.bin", languages: "English", diskSizeDescription: "466 MB", notes: "Higher English accuracy", sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", sizeBytes: 487_614_201),
        Self.model(id: "small", displayName: "Whisper small", fileName: "ggml-small.bin", languages: "Multilingual", diskSizeDescription: "466 MB", notes: "Stronger multilingual accuracy", sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", sizeBytes: 487_601_967),
        Self.model(id: "medium.en", displayName: "Whisper medium.en", fileName: "ggml-medium.en.bin", languages: "English", diskSizeDescription: "1.5 GB", notes: "Large memory footprint", sha256: "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356", sizeBytes: 1_533_774_781),
        Self.model(id: "medium", displayName: "Whisper medium", fileName: "ggml-medium.bin", languages: "Multilingual", diskSizeDescription: "1.5 GB", notes: "Large memory footprint", sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", sizeBytes: 1_533_763_059),
        Self.model(id: "large-v3", displayName: "Whisper large-v3", fileName: "ggml-large-v3.bin", languages: "Multilingual", diskSizeDescription: "2.9 GB", notes: "Best accuracy, highest memory", sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", sizeBytes: 3_095_033_483),
        Self.model(id: "large-v3-turbo", displayName: "Whisper large-v3-turbo", fileName: "ggml-large-v3-turbo.bin", languages: "Multilingual", diskSizeDescription: "1.6 GB", notes: "Fastest high-accuracy model for Apple Silicon", isRecommended: true, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", sizeBytes: 1_624_555_275)
    ]

    let nativeModels: [ASRModelDescriptor] = [
        ASRModelDescriptor(id: "parakeet-unified", displayName: "Parakeet Unified 0.6B",
            fileName: "parakeet-unified", downloadURL: URL(string: "https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml")!,
            languages: "English", diskSizeDescription: "About 700 MB", notes: "Local English dictation on Apple Silicon. Model stays loaded between recordings.",
            isRecommended: true, expectedSHA256: nil, expectedFileSizeBytes: nil, engineKind: .parakeet),
        ASRModelDescriptor(id: "nemotron-streaming", displayName: "Nemotron Streaming 0.6B",
            fileName: "nemotron-streaming", downloadURL: URL(string: "https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml")!,
            languages: "English", diskSizeDescription: "About 700 MB", notes: "Transcribes while you speak on Apple Silicon. Inserts text while you speak in supported fields. Uses 1.12-second audio chunks.",
            isRecommended: false, expectedSHA256: nil, expectedFileSizeBytes: nil, engineKind: .nemotron)
    ]

    var models: [ASRModelDescriptor] { nativeModels + whisperModels }

    var defaultModel: ASRModelDescriptor {
        whisperModels.first(where: { $0.id == "base.en" }) ?? whisperModels[0]
    }

    func model(for id: String) -> ASRModelDescriptor? {
        models.first(where: { $0.id == id })
    }

    private static func model(
        id: String,
        displayName: String,
        fileName: String,
        languages: String,
        diskSizeDescription: String,
        notes: String,
        isRecommended: Bool = false,
        sha256: String? = nil,
        sizeBytes: Int64? = nil
    ) -> ASRModelDescriptor {
        ASRModelDescriptor(
            id: id,
            displayName: displayName,
            fileName: fileName,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)?download=true")!,
            languages: languages,
            diskSizeDescription: diskSizeDescription,
            notes: notes,
            isRecommended: isRecommended,
            expectedSHA256: sha256,
            expectedFileSizeBytes: sizeBytes
        )
    }
}
