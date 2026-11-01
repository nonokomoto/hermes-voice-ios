import Foundation

/// Estado de um run, tal como `GET /v1/runs/{id}` o devolve.
struct EstadoRun: Sendable {
    var status: String
    var output: String?
    var tokensEntrada: Int?
    var tokensSaida: Int?
    var tokensCache: Int?
    var modelo: String?
    var erro: String?
    var aprovacao: Aprovacao?

    var terminal: Bool { ["completed", "failed", "cancelled", "interrupted"].contains(status) }
}

/// Uma linha do histórico de uma sessão (`GET /api/sessions/{id}/messages`).
struct MensagemSessao: Sendable {
    struct Chamada: Sendable {
        var id: String
        var nome: String
        var argumentos: String
    }

    var id: String
    var papel: String
    var conteudo: String
    var chamadas: [Chamada]
    var idChamada: String?
    var data: Date
}

struct EstadoAgente: Sendable, Equatable {
    var modelo: String?
    var reservas: [String]
    var voz: String?
    var push: Bool
}

enum ErroHermes: LocalizedError {
    case resposta
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .resposta: return "O servidor respondeu de forma inesperada."
        case .http(401, _): return "A chave de acesso não é aceite (401)."
        case .http(let codigo, let corpo):
            return corpo.isEmpty ? "Erro do servidor (\(codigo))." : "Erro do servidor (\(codigo)): \(corpo.prefix(160))"
        }
    }
}

/// Cliente do servidor de API do Hermes (`API_SERVER_ENABLED`).
///
/// As respostas correm como runs (`/v1/runs`): o trabalho continua no ProDesk mesmo com a app fechada.
final class HermesClient: Sendable {
    let base: URL
    let chave: String
    private let sessao: URLSession

    init(base: URL, chave: String) {
        self.base = base
        self.chave = chave
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        sessao = URLSession(configuration: config)
    }

    func pedido(_ caminho: String, metodo: String = "GET", corpo: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: base.appending(path: caminho))
        r.httpMethod = metodo
        r.setValue("Bearer \(chave)", forHTTPHeaderField: "Authorization")
        if let corpo {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: corpo)
        }
        return r
    }

    /// Devolve o JSON e o código HTTP; lança erro para códigos fora de 2xx exceto os indicados em `aceitar`.
    private func json(_ r: URLRequest, aceitar: Set<Int> = []) async throws -> (Any?, Int) {
        let (dados, resposta) = try await sessao.data(for: r)
        guard let http = resposta as? HTTPURLResponse else { throw ErroHermes.resposta }
        let obj = try? JSONSerialization.jsonObject(with: dados)
        if (200..<300).contains(http.statusCode) || aceitar.contains(http.statusCode) {
            return (obj, http.statusCode)
        }
        let mensagem = ((obj as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            ?? String(data: dados.prefix(300), encoding: .utf8) ?? ""
        throw ErroHermes.http(http.statusCode, mensagem)
    }

    func testar() async throws {
        _ = try await json(pedido("v1/capabilities"))
    }

    /// Cria um run na sessão indicada. `idempotencia` evita um run duplicado se o pedido for repetido.
    func criarRun(_ texto: String, sessao sessaoID: String, instrucoes: String, idempotencia: String) async throws -> String {
        var r = pedido("v1/runs", metodo: "POST", corpo: ["input": texto, "session_id": sessaoID, "instructions": instrucoes])
        r.setValue(idempotencia, forHTTPHeaderField: "Idempotency-Key")
        let (obj, _) = try await json(r)
        guard let id = (obj as? [String: Any])?["run_id"] as? String else { throw ErroHermes.resposta }
        return id
    }

    /// `nil` quando o Hermes já não guarda o run (os estados finais só ficam retidos algum tempo).
    func estadoRun(_ id: String) async throws -> EstadoRun? {
        let (obj, codigo) = try await json(pedido("v1/runs/\(id)"), aceitar: [404])
        guard codigo != 404, let d = obj as? [String: Any], let status = d["status"] as? String else { return nil }
        let uso = d["usage"] as? [String: Any]
        return EstadoRun(
            status: status,
            output: d["output"] as? String,
            tokensEntrada: uso?["input_tokens"] as? Int,
            tokensSaida: uso?["output_tokens"] as? Int,
            tokensCache: uso?["cache_read_tokens"] as? Int,
            modelo: (d["runtime"] as? [String: Any])?["model"] as? String,
            erro: Self.textoDeErro(d["error"]),
            aprovacao: status == "waiting_for_approval" ? Self.aprovacao(d["approval"]) : nil
        )
    }

    private static func aprovacao(_ valor: Any?) -> Aprovacao? {
        guard let a = valor as? [String: Any], let pedido = a["request_id"] as? String else { return nil }
        return Aprovacao(
            pedidoID: pedido,
            comando: a["command"] as? String ?? "",
            motivo: a["description"] as? String ?? a["pattern_key"] as? String ?? "",
            opcoes: a["choices"] as? [String] ?? ["once", "deny"],
            desde: Date(timeIntervalSince1970: a["timestamp"] as? Double ?? Date().timeIntervalSince1970),
            padroes: a["pattern_keys"] as? [String] ?? (a["pattern_key"] as? String).map { [$0] }
        )
    }

    /// Responde a um pedido de autorização: `once`, `session`, `always` ou `deny`.
    func responderAprovacao(run: String, pedidoID: String, escolha: String) async throws {
        _ = try await json(pedido("v1/runs/\(run)/approval", metodo: "POST", corpo: ["choice": escolha, "request_id": pedidoID]))
    }

    /// Envia uma foto para a pasta de trabalho do agente no ProDesk e devolve o caminho lá.
    func enviarAnexo(_ dados: Data, tipo: String = "image/jpeg") async throws -> String {
        var r = pedido("anexos", metodo: "POST")
        r.setValue(tipo, forHTTPHeaderField: "Content-Type")
        r.httpBody = dados
        r.timeoutInterval = 120
        let (obj, _) = try await json(r)
        guard let caminho = (obj as? [String: Any])?["caminho"] as? String else { throw ErroHermes.resposta }
        return caminho
    }

    /// Regista este iPhone para receber notificações push do ProDesk. Devolve se o push está ligado lá.
    func registarDispositivo(_ token: String, ambiente: String) async throws -> Bool {
        let (obj, _) = try await json(pedido("avisos/dispositivo", metodo: "POST", corpo: ["token": token, "ambiente": ambiente]))
        return (obj as? [String: Any])?["push"] as? Bool ?? false
    }

    /// Pede ao ProDesk para avisar (push) quando o run pedir aprovação ou acabar.
    func vigiar(run: String, assunto: String, titulo: String, entrada: String) async throws {
        _ = try await json(pedido("avisos/vigiar", metodo: "POST",
                                  corpo: ["run": run, "assunto": assunto, "titulo": titulo, "entrada": entrada]))
    }

    /// Lembra no ProDesk tipos de comando permitidos para sempre neste assunto (o ProDesk aprova-os sozinho).
    func permitir(assunto: String, padroes: [String]) async throws {
        _ = try await json(pedido("avisos/permitir", metodo: "POST", corpo: ["assunto": assunto, "padroes": padroes]))
    }

    /// Permissões lembradas no ProDesk: assunto → tipos de comando.
    func permitidos() async throws -> [String: [String]] {
        let (obj, _) = try await json(pedido("avisos/permitidos"))
        return obj as? [String: [String]] ?? [:]
    }

    func retirar(assunto: String, padrao: String?) async throws {
        var corpo: [String: Any] = ["assunto": assunto]
        if let padrao { corpo["padrao"] = padrao }
        _ = try await json(pedido("avisos/retirar", metodo: "POST", corpo: corpo))
    }

    /// Modelo principal, reservas e voz em uso no ProDesk.
    func estadoAgente() async throws -> EstadoAgente {
        let (obj, _) = try await json(pedido("avisos/estado"))
        let d = obj as? [String: Any] ?? [:]
        return EstadoAgente(
            modelo: d["modelo"] as? String,
            reservas: d["reservas"] as? [String] ?? [],
            voz: d["voz"] as? String,
            push: d["push"] as? Bool ?? false
        )
    }

    func pararRun(_ id: String) async throws {
        _ = try await json(pedido("v1/runs/\(id)/stop", metodo: "POST", corpo: [:]), aceitar: [404])
    }

    /// Histórico da sessão por ordem cronológica. Sessão inexistente devolve lista vazia.
    func mensagens(sessao sessaoID: String) async throws -> [MensagemSessao] {
        let (obj, codigo) = try await json(pedido("api/sessions/\(sessaoID)/messages"), aceitar: [404])
        guard codigo != 404, let linhas = (obj as? [String: Any])?["data"] as? [[String: Any]] else { return [] }
        return linhas.map { m in
            let chamadas = (m["tool_calls"] as? [[String: Any]] ?? []).map { c in
                let funcao = c["function"] as? [String: Any]
                return MensagemSessao.Chamada(
                    id: c["call_id"] as? String ?? c["id"] as? String ?? "",
                    nome: funcao?["name"] as? String ?? "ferramenta",
                    argumentos: funcao?["arguments"] as? String ?? ""
                )
            }
            return MensagemSessao(
                id: "\(m["id"] ?? UUID().uuidString)",
                papel: m["role"] as? String ?? "",
                conteudo: m["content"] as? String ?? "",
                chamadas: chamadas,
                idChamada: m["tool_call_id"] as? String,
                data: Date(timeIntervalSince1970: m["timestamp"] as? Double ?? Date().timeIntervalSince1970)
            )
        }
    }

    /// Áudio MP3 da parte falada, gerado pelo serviço /voz do ProDesk (Gemini, com reserva pt-PT).
    /// Devolve o MP3 e a voz usada (cabeçalho `X-Voz`: `gemini-Aoede` ou `pt-PT-RaquelNeural`).
    func voz(_ texto: String) async throws -> (dados: Data, voz: String?) {
        var r = pedido("voz", metodo: "POST", corpo: ["texto": texto])
        r.timeoutInterval = 60
        let (dados, resposta) = try await sessao.data(for: r)
        guard let http = resposta as? HTTPURLResponse else { throw ErroHermes.resposta }
        guard http.statusCode == 200 else { throw ErroHermes.http(http.statusCode, "") }
        return (dados, http.value(forHTTPHeaderField: "X-Voz"))
    }

    /// Tabela de preços mantida no ProDesk.
    func precos() async throws -> Precos {
        let (dados, resposta) = try await sessao.data(for: pedido("avisos/precos"))
        guard (resposta as? HTTPURLResponse)?.statusCode == 200 else { throw ErroHermes.resposta }
        return try JSONDecoder().decode(Precos.self, from: dados)
    }

    /// Pedido do fluxo de eventos de um run, para a transferência em segundo plano.
    func pedidoEventos(_ runID: String) -> URLRequest {
        var r = pedido("v1/runs/\(runID)/events")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return r
    }

    static func textoDeErro(_ valor: Any?) -> String? {
        if let s = valor as? String, !s.isEmpty { return s }
        if let d = valor as? [String: Any] { return d["message"] as? String }
        return nil
    }

    /// O resultado de uma ferramenta vem como texto; o terminal embrulha-o em JSON `{"output": …}`.
    static func textoDoResultado(_ texto: String) -> String {
        if let dados = texto.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
           let saida = obj["output"] as? String {
            return saida
        }
        return texto
    }
}

/// O último evento terminal (`run.completed`, `run.failed`, …) de um fluxo de eventos guardado em ficheiro.
struct FimDeRun: Sendable {
    var evento: String
    var output: String?
    var tokensEntrada: Int?
    var tokensSaida: Int?
    var tokensCache: Int?
    var modelo: String?
    var erro: String?

    var status: String {
        switch evento {
        case "run.completed": return "completed"
        case "run.cancelled": return "cancelled"
        case "run.interrupted": return "interrupted"
        default: return "failed"
        }
    }

    static func ler(_ texto: String) -> FimDeRun? {
        var fim: FimDeRun?
        for linha in texto.split(separator: "\n") where linha.hasPrefix("data:") {
            let json = linha.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let dados = json.data(using: .utf8),
                  let d = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
                  let evento = d["event"] as? String,
                  ["run.completed", "run.failed", "run.cancelled", "run.interrupted"].contains(evento)
            else { continue }
            let uso = d["usage"] as? [String: Any]
            fim = FimDeRun(
                evento: evento,
                output: d["output"] as? String,
                tokensEntrada: uso?["input_tokens"] as? Int,
                tokensSaida: uso?["output_tokens"] as? Int,
                tokensCache: uso?["cache_read_tokens"] as? Int,
                modelo: (d["runtime"] as? [String: Any])?["model"] as? String,
                erro: HermesClient.textoDeErro(d["error"])
            )
        }
        return fim
    }
}
