import Foundation

enum Autor: String, Codable {
    case eu
    case agente
}

enum Estado: String, Codable {
    case aCorrer
    case feito
    case falhou
    case parado
}

/// Uma ferramenta que o agente usou durante uma resposta (lida do histórico da sessão no Hermes).
struct Passo: Identifiable, Codable, Hashable {
    var id: String
    /// `call_id` do Hermes; pode repetir-se entre chamadas, por isso não serve de `id`.
    var chamada: String?
    var ferramenta: String
    var argumentos: String
    var resultado: String?
    var inicio: Date
    var fim: Date?

    private static let nomes: [String: String] = [
        "terminal": "terminal",
        "web_search": "pesquisou na web",
        "web_extract": "leu uma página",
        "read_file": "leu um ficheiro",
        "write_file": "escreveu um ficheiro",
        "patch": "alterou um ficheiro",
        "search_files": "procurou ficheiros",
        "browser_navigate": "abriu no browser",
        "memory": "memória",
        "delegate_task": "delegou uma tarefa",
    ]

    var nomeLegivel: String { Self.nomes[ferramenta] ?? ferramenta }

    /// O argumento que melhor descreve a chamada (comando, pesquisa, endereço ou caminho).
    var argumentoPrincipal: String {
        guard let dados = argumentos.data(using: .utf8),
              let objeto = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
        else { return "" }
        for chave in ["command", "query", "url", "path", "pattern"] {
            if let valor = objeto[chave] as? String { return String(valor.prefix(80)) }
        }
        return ""
    }

    var resumo: String {
        let arg = argumentoPrincipal
        return arg.isEmpty ? nomeLegivel : "\(nomeLegivel) · \(arg)"
    }
}

/// Pedido de autorização do Hermes para um comando que considera perigoso (`waiting_for_approval`).
struct Aprovacao: Codable, Hashable {
    var pedidoID: String
    var comando: String
    var motivo: String
    var opcoes: [String]
    var desde: Date
    /// Tipos de comando (`pattern_keys`) que o Hermes assinalou; servem para lembrar "sempre neste assunto".
    var padroes: [String]?

    /// Os motivos vêm do Hermes em inglês; os mais comuns ficam traduzidos.
    var motivoLegivel: String { Self.legivel(motivo) }

    static func legivel(_ motivo: String) -> String {
        let m = motivo.lowercased()
        if m.contains("delete") || m.contains("rm ") { return "Apaga ficheiros" }
        if m.contains("sudo") || m.contains("root") { return "Mexe no sistema" }
        if m.contains("force") && m.contains("push") { return "Reescreve o histórico do git" }
        if m.contains("curl") || m.contains("pipe") || m.contains("download") { return "Corre código descarregado" }
        if m.contains("kill") { return "Termina processos" }
        if m.contains("chmod") || m.contains("chown") || m.contains("permission") { return "Muda permissões" }
        return motivo.prefix(1).uppercased() + motivo.dropFirst()
    }
}

struct Entrada: Identifiable, Codable, Hashable {
    var id = UUID()
    var autor: Autor
    var texto: String
    var data: Date
    var passos: [Passo] = []
    var estado: Estado = .feito
    var duracao: TimeInterval?
    var tokensEntrada: Int?
    var tokensSaida: Int?
    var erro: String?
    /// Run do Hermes (`/v1/runs`) que está a produzir esta resposta.
    var runID: String?
    /// Modelo que respondeu, tal como o Hermes o reporta em `runtime.model`.
    var modelo: String?
    /// Pedido de autorização pendente (só respostas do agente).
    var aprovacao: Aprovacao?
    /// Fotos anexadas (só pedidos teus): nomes de ficheiro na pasta local de anexos.
    var anexos: [String]?
    /// Texto exatamente como foi enviado ao Hermes (com os caminhos dos anexos no ProDesk).
    var pedidoEnviado: String?
    /// Tokens de entrada lidos da cache do fornecedor (mais baratos).
    var tokensCache: Int?
    /// Duração e voz do áudio gerado para esta resposta, para calcular o custo.
    var duracaoAudio: TimeInterval?
    var vozAudio: String?

    var tokensTotal: Int? {
        guard let e = tokensEntrada, let s = tokensSaida else { return nil }
        return e + s
    }
}

/// Um assunto é uma conversa com nome no Hermes (`"conversation"` na API).
struct Assunto: Identifiable, Codable, Hashable {
    var id: String
    var titulo: String
    var entradas: [Entrada] = []
    var atualizado: Date
    /// Tipos de comando permitidos para sempre neste assunto.
    var permitidos: [String]?
    /// Cor de separador; assuntos antigos recebem uma cor estável a partir do id.
    var cor: CorAssunto?

    var corAssunto: CorAssunto { cor ?? CorAssunto.paraID(id) }

    var aCorrer: Bool { entradas.last?.estado == .aCorrer }
    var aprovacaoPendente: Aprovacao? { entradas.last?.aprovacao }

    var ultimaLinha: String {
        let fonte = entradas.last(where: { $0.autor == .agente && !$0.texto.isEmpty }) ?? entradas.last
        let texto = fonte?.texto ?? ""
        return texto.split(separator: "\n").first.map(String.init) ?? texto
    }
}
