import Foundation
import llama

enum RivaError: LocalizedError {
    case modelLoad
    case contextLoad
    case languagePair(String, String)
    case promptTooLong
    case decode
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelLoad: "Non riesco ad aprire il GGUF Riva in locale."
        case .contextLoad: "Memoria insufficiente per il contesto Riva."
        case .languagePair(let source, let target): "Coppia Riva non supportata: \(source) → \(target)."
        case .promptTooLong: "Frase troppo lunga per il contesto Riva."
        case .decode: "Inferenza Riva interrotta o fallita."
        case .invalidOutput: "Riva non ha generato testo UTF-8 valido."
        }
    }
}

// Exact prompt and greedy sampling convention of NVIDIA NeMo-Speech.cpp NMT.
// One context is reused sequentially so the phone never loads multiple GGUF copies.
final class RivaTranslator {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>

    init(url: URL) throws {
        llama_backend_init()
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif
        guard let model = llama_model_load_from_file(url.path, modelParams) else {
            llama_backend_free()
            throw RivaError.modelLoad
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 1024
        contextParams.n_batch = 512
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            llama_backend_free()
            throw RivaError.contextLoad
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.sampler = llama_sampler_init_greedy()
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    func translate(_ text: String, from source: String, to target: String) throws -> String {
        let a = source.lowercased().split(separator: "-").first.map(String.init) ?? source
        let b = target.lowercased().split(separator: "-").first.map(String.init) ?? target
        if a == b { return text }
        if a != "en" && b != "en" {
            // Riva v2 exposes the non-English pairs via English only.
            return try translate(translate(text, from: a, to: "en"), from: "en", to: b)
        }
        guard let sourceName = Self.languageNames[a], let targetName = Self.languageNames[b] else {
            throw RivaError.languagePair(source, target)
        }
        let prompt = "<s>System\nYou are an expert at translating text from \(sourceName) to \(targetName).</s>\n<s>User\nWhat is the \(targetName) translation of the sentence: \(text)</s>\n<s>Assistant\n"
        let utf8 = prompt.utf8.count
        var tokens = [llama_token](repeating: 0, count: utf8 + 2)
        let count = prompt.withCString { characters in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocab, characters, Int32(utf8), buffer.baseAddress,
                               Int32(buffer.count), false, true)
            }
        }
        guard count > 0, Int(count) < Int(llama_n_ctx(context)) else { throw RivaError.promptTooLong }
        llama_memory_clear(llama_get_memory(context), true)
        var offset = 0
        let batchSize = Int(llama_n_batch(context))
        while offset < Int(count) {
            try Task<Never, Never>.checkCancellation()
            let length = min(batchSize, Int(count) - offset)
            let result = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress!.advanced(by: offset), Int32(length)))
            }
            guard result == 0 else { throw RivaError.decode }
            offset += length
        }
        var bytes = Data()
        for _ in 0..<256 {
            try Task<Never, Never>.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var buffer = [CChar](repeating: 0, count: 256)
            var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            if length < 0 {
                buffer = [CChar](repeating: 0, count: Int(-length))
                length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
            }
            guard length >= 0 else { throw RivaError.decode }
            for character in buffer.prefix(Int(length)) {
                bytes.append(UInt8(bitPattern: character))
            }
            var next = token
            guard llama_decode(context, llama_batch_get_one(&next, 1)) == 0 else { throw RivaError.decode }
        }
        guard let result = String(data: bytes, encoding: .utf8) else { throw RivaError.invalidOutput }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Model's supported English ↔ language pairs (not all combinations).
    private static let languageNames = [
        "en": "English", "it": "Italian", "fr": "French", "de": "German",
        "es": "European Spanish", "pt": "Brazilian Portuguese", "zh": "Simplified Chinese",
        "ja": "Japanese", "ko": "Korean", "ar": "Arabic", "ru": "Russian",
        "nl": "Dutch", "pl": "Polish", "cs": "Czech", "sv": "Swedish",
        "da": "Danish", "fi": "Finnish", "no": "Norwegian", "hu": "Hungarian",
        "ro": "Romanian", "bg": "Bulgarian", "uk": "Ukrainian", "sk": "Slovak",
        "hr": "Croatian", "sl": "Slovenian", "et": "Estonian", "lv": "Latvian",
        "lt": "Lithuanian", "el": "Greek", "tr": "Turkish", "id": "Indonesian",
        "vi": "Vietnamese", "th": "Thai", "hi": "Hindi"
    ]
}
