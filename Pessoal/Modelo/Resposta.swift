import Foundation

/// Uma ligação que o agente sugeriu, mostrada como linha tocável e nunca lida em voz alta.
struct Ligacao: Identifiable, Hashable {
    var titulo: String
    var url: URL

    var id: String { url.absoluteString }
    var dominio: String { url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

/// Resposta separada em parte falada e ligações.
///
/// O agente é instruído a responder em frases curtas e a pôr as ligações numa secção final
/// `Ligações:` com linhas `- Título | https://…`. Links em markdown ou soltos no texto também são
/// apanhados, para respostas antigas ou quando o modelo não cumpre o formato.
struct RespostaFalada {
    var fala: String
    var ligacoes: [Ligacao]

    /// Instruções enviadas com cada pedido (`instructions` em `/v1/runs`).
    static let instrucoes = """
    Vais ser ouvido, não lido: a tua resposta é convertida em voz. Responde em português de Portugal, \
    em uma a três frases curtas, no máximo 40 palavras, como numa conversa. Não uses markdown, listas, \
    títulos, emojis nem endereços web no texto falado. Se houver ligações úteis (páginas, documentos, \
    reuniões), acrescenta no fim, depois de uma linha em branco, uma secção exatamente neste formato, \
    uma ligação por linha, e não as menciones no texto falado:
    Ligações:
    - Título curto | https://endereço
    """

    init(_ texto: String) {
        var linhasFala: [String] = []
        var ligacoes: [Ligacao] = []
        var naSeccao = false

        for linha in texto.components(separatedBy: .newlines) {
            let limpa = linha.trimmingCharacters(in: .whitespaces)
            if limpa.lowercased().hasPrefix("ligações:") || limpa.lowercased().hasPrefix("ligacoes:") {
                naSeccao = true
                continue
            }
            if naSeccao {
                if let l = Self.ligacaoDeLinha(limpa) { ligacoes.append(l) }
                continue
            }
            linhasFala.append(linha)
        }

        // Links em markdown [título](url) e endereços soltos dentro do texto falado.
        var fala = linhasFala.joined(separator: "\n")
        let markdown = #/\[([^\]]+)\]\((https?://[^\s)]+)\)/#
        for m in fala.matches(of: markdown) {
            if let url = URL(string: String(m.2)) { ligacoes.append(Ligacao(titulo: String(m.1), url: url)) }
        }
        fala = fala.replacing(markdown) { String($0.1) }
        let solto = #/https?://[^\s)>\]]+/#
        for m in fala.matches(of: solto) {
            if let url = URL(string: String(m.0)) { ligacoes.append(Ligacao(titulo: url.host() ?? "Ligação", url: url)) }
        }
        fala = fala.replacing(solto, with: "")

        // Restos de markdown que não se devem ler nem mostrar.
        fala = fala.replacing(#/\*\*|__|`|^#+\s*/#.anchorsMatchLineEndings(), with: "")
        fala = fala.replacing(#/^\s*[-*•]\s+/#.anchorsMatchLineEndings(), with: "")

        var vistos = Set<String>()
        self.ligacoes = ligacoes.filter { vistos.insert($0.id).inserted }
        self.fala = fala.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ligacaoDeLinha(_ linha: String) -> Ligacao? {
        var corpo = linha
        if corpo.hasPrefix("-") || corpo.hasPrefix("•") || corpo.hasPrefix("*") { corpo = String(corpo.dropFirst()) }
        corpo = corpo.trimmingCharacters(in: .whitespaces)
        guard let intervalo = corpo.range(of: #"https?://\S+"#, options: .regularExpression),
              let url = URL(string: String(corpo[intervalo]).trimmingCharacters(in: CharacterSet(charactersIn: ")>]")))
        else { return nil }
        var titulo = String(corpo[..<intervalo.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " |–—:-("))
        if titulo.isEmpty { titulo = url.host() ?? "Ligação" }
        return Ligacao(titulo: titulo, url: url)
    }
}
