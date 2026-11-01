import Foundation

/// Tabela de preços (USD por 1 milhão de tokens), servida pelo ProDesk em /avisos/precos
/// a partir de `servidor/precos.json`. Mudar preços não obriga a um novo build.
struct Precos: Codable, Equatable {
    struct Modelo: Codable, Equatable {
        var entrada: Double
        var saida: Double
        var cache: Double
    }

    struct Voz: Codable, Equatable {
        var texto: Double
        var audio: Double
        var tokensPorSegundo: Double
        var gratuito: Bool

        enum CodingKeys: String, CodingKey {
            case texto, audio, gratuito
            case tokensPorSegundo = "tokens_por_segundo"
        }
    }

    /// Euros por dólar (taxa de referência diária do BCE, trazida pelo ProDesk).
    struct Cambio: Codable, Equatable {
        var eurPorUsd: Double
        var data: String?
        var fonte: String?

        enum CodingKeys: String, CodingKey {
            case data, fonte
            case eurPorUsd = "eur_por_usd"
        }
    }

    var modelos: [String: Modelo]
    var voz: [String: Voz]
    var cambio: Cambio?

    /// Os preços dos fornecedores estão em dólares; a app mostra sempre euros.
    func euros(_ dolares: Double) -> String {
        Dinheiro.texto(dolares * (cambio?.eurPorUsd ?? 0.88))
    }

    /// Valores de setembro de 2026, usados até o ProDesk responder.
    static let porOmissao = Precos(
        modelos: [
            "glm-5.3-flash": .init(entrada: 0.15, saida: 0.50, cache: 0.03),
            "deepseek-v4.1-flash": .init(entrada: 0.30, saida: 1.20, cache: 0.006),
            "kimi-k3": .init(entrada: 3.00, saida: 15.00, cache: 0.30),
            "space-bunny-free": .init(entrada: 0, saida: 0, cache: 0),
        ],
        voz: [
            "gemini": .init(texto: 0.50, audio: 9.00, tokensPorSegundo: 25, gratuito: true),
            "edge": .init(texto: 0, audio: 0, tokensPorSegundo: 0, gratuito: true),
        ],
        cambio: .init(eurPorUsd: 0.88, data: nil, fonte: "estimativa")
    )

    // MARK: Cálculo

    /// Custo da chamada ao modelo: tokens de entrada (menos os lidos da cache), da cache e de saída.
    func chamada(_ e: Entrada) -> Double? {
        guard let nome = e.modelo, let p = modelos[nome], let entrada = e.tokensEntrada, let saida = e.tokensSaida
        else { return nil }
        let cache = min(e.tokensCache ?? 0, entrada)
        return (Double(entrada - cache) * p.entrada + Double(cache) * p.cache + Double(saida) * p.saida) / 1_000_000
    }

    /// Custo do áudio: o que valeria no nível pago, e se foi gratuito.
    func audio(_ e: Entrada) -> (valor: Double, gratuito: Bool)? {
        guard let duracao = e.duracaoAudio, let voz = e.vozAudio else { return nil }
        let p = voz.hasPrefix("gemini") ? self.voz["gemini"] : self.voz["edge"]
        guard let p else { return nil }
        let tokensTexto = Double(RespostaFalada(e.texto).fala.count) / 4
        let valor = (tokensTexto * p.texto + duracao * p.tokensPorSegundo * p.audio) / 1_000_000
        return (valor, p.gratuito)
    }

    /// O que a resposta custou de facto (o áudio gratuito conta zero).
    func total(_ e: Entrada) -> Double {
        let voz = audio(e).map { $0.gratuito ? 0 : $0.valor } ?? 0
        return (chamada(e) ?? 0) + voz
    }

    func total(_ a: Assunto) -> Double {
        a.entradas.reduce(0) { $0 + total($1) }
    }
}

enum Dinheiro {
    private static let formato: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.numberStyle = .decimal
        return f
    }()

    /// "0,0041 €", "0,12 €", "1,40 €"; valores ínfimos aparecem como "< 0,0001 €".
    static func texto(_ valor: Double) -> String {
        if valor == 0 { return "0 €" }
        if valor < 0.0001 { return "< 0,0001 €" }
        formato.minimumFractionDigits = valor < 0.1 ? 4 : 2
        formato.maximumFractionDigits = valor < 0.1 ? 4 : 2
        return (formato.string(from: NSNumber(value: valor)) ?? "\(valor)") + " €"
    }
}
