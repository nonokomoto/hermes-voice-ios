import AVFoundation
import Foundation
import Observation
import UIKit

enum EstadoLigacao: Equatable {
    case porConfigurar
    case aTestar
    case ligado
    case erro(String)
}

/// Estado da app: assuntos guardados no iPhone, ligação ao Hermes e respostas em curso.
///
/// Cada resposta é um run no Hermes. O ProDesk continua a trabalhar com a app fechada; a app
/// acompanha o histórico da sessão enquanto está aberta e é acordada pela `VigiaRuns` quando o run acaba.
@MainActor
@Observable
final class Store {
    static let partilhado = Store()

    var assuntos: [Assunto] = []
    var ligacao: EstadoLigacao = .porConfigurar
    /// Assunto a abrir, pedido por um toque numa notificação.
    var abrirAssunto: String?
    /// Modelo, reservas e voz, lidos do ProDesk para as Definições.
    var agente: EstadoAgente?
    /// Permissões lembradas no ProDesk: assunto → tipos de comando.
    var permitidos: [String: [String]] = [:]

    var servidor: String {
        didSet { UserDefaults.standard.set(servidor, forKey: "servidor") }
    }

    var chave: String {
        didSet { Keychain.guardar(chave, conta: "api") }
    }

    @ObservationIgnored private var tarefas: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var clienteGuardado: HermesClient?

    /// Vazio: o endereço do servidor (ex.: `https://<máquina>.<tailnet>.ts.net`) preenche-se nas Definições.
    static let servidorPorOmissao = ""

    private init() {
        servidor = UserDefaults.standard.string(forKey: "servidor") ?? Self.servidorPorOmissao
        chave = Keychain.ler(conta: "api") ?? ""
        carregar()
        VigiaRuns.partilhado.aoTerminar = { [weak self] descricao, fim in
            self?.terminouNoServidor(descricao, fim)
        }
        VigiaRuns.partilhado.ativar()
    }

    var configurado: Bool { cliente != nil }

    var nomeServidor: String {
        URL(string: servidor)?.host()?.split(separator: ".").first.map(String.init) ?? servidor
    }

    private var cliente: HermesClient? {
        guard let url = URL(string: servidor), url.scheme != nil, !chave.isEmpty else { return nil }
        if let c = clienteGuardado, c.base == url, c.chave == chave { return c }
        let novo = HermesClient(base: url, chave: chave)
        clienteGuardado = novo
        return novo
    }

    func assunto(_ id: String) -> Assunto? { assuntos.first { $0.id == id } }

    /// Áudio da parte falada, pedido ao serviço /voz do ProDesk. Guarda a duração e a voz para o custo.
    func audio(de fala: String, entrada: UUID) async throws -> Data {
        guard let cliente = cliente else { throw ErroHermes.resposta }
        let (dados, voz) = try await cliente.voz(fala)
        let duracao = (try? AVAudioPlayer(data: dados))?.duration
        for a in assuntos where a.entradas.contains(where: { $0.id == entrada }) {
            alterar(a.id, entrada) { e in
                e.duracaoAudio = duracao
                e.vozAudio = voz ?? "gemini"
            }
        }
        guardar()
        return dados
    }

    // MARK: Custos

    /// Preços em uso: os do ProDesk quando disponíveis, senão os de setembro de 2026.
    var precos: Precos = {
        guard let dados = UserDefaults.standard.data(forKey: "precos"),
              let p = try? JSONDecoder().decode(Precos.self, from: dados)
        else { return .porOmissao }
        return p
    }()

    private func atualizarPrecos() {
        guard let cliente = cliente else { return }
        Task {
            guard let p = try? await cliente.precos() else { return }
            precos = p
            UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: "precos")
        }
    }

    private func sessaoID(_ assunto: String) -> String { "pessoal-\(assunto)" }

    // MARK: Ligação

    func testarLigacao() async {
        guard let cliente = cliente else {
            ligacao = .porConfigurar
            return
        }
        ligacao = .aTestar
        do {
            try await cliente.testar()
            ligacao = .ligado
        } catch {
            ligacao = .erro(error.localizedDescription)
        }
    }

    // MARK: Enviar

    /// Cria um assunto a partir do primeiro pedido e envia-o. Devolve o id para navegar.
    func novoAssunto(com texto: String, fotos: [Data] = []) -> String {
        let id = "a-" + UUID().uuidString.prefix(8).lowercased()
        let titulo = texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fotos.isEmpty ? "Foto" : Self.titulo(de: texto)
        var novo = Assunto(id: id, titulo: titulo, atualizado: .now)
        novo.cor = proximaCor()
        assuntos.insert(novo, at: 0)
        enviar(texto, em: id, fotos: fotos)
        return id
    }

    func enviar(_ texto: String, em id: String, fotos: [Data] = []) {
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty || !fotos.isEmpty, cliente != nil, let i = indice(id), !assuntos[i].aCorrer else { return }

        let nomes = fotos.compactMap { AnexosLocais.guardar($0) }
        let resposta = Entrada(autor: .agente, texto: "", data: .now, estado: .aCorrer)
        assuntos[i].entradas.append(Entrada(autor: .eu, texto: limpo, data: .now, anexos: nomes.isEmpty ? nil : nomes))
        assuntos[i].entradas.append(resposta)
        assuntos[i].atualizado = .now
        guardar()
        Notificacoes.pedirAutorizacao()
        iniciar(assunto: id, entrada: resposta.id)
    }

    /// Envia as fotos (se houver), cria o run (ou recupera-o, graças à chave de idempotência) e acompanha-o.
    private func iniciar(assunto: String, entrada: UUID) {
        guard let cliente = cliente,
              let i = indice(assunto),
              let j = assuntos[i].entradas.firstIndex(where: { $0.id == entrada }),
              j > 0, assuntos[i].entradas[j - 1].autor == .eu
        else { return }
        let meu = assuntos[i].entradas[j - 1]
        let sessao = sessaoID(assunto)
        tarefas[entrada] = Task { [weak self] in
            do {
                var pedido = meu.pedidoEnviado ?? ""
                if meu.pedidoEnviado == nil {
                    var caminhos: [String] = []
                    for nome in meu.anexos ?? [] {
                        guard let dados = AnexosLocais.dados(nome) else { continue }
                        caminhos.append(try await cliente.enviarAnexo(dados))
                    }
                    pedido = Self.compor(meu.texto, fotos: caminhos)
                    self?.alterar(assunto, meu.id) { $0.pedidoEnviado = pedido }
                }
                let run = try await cliente.criarRun(pedido, sessao: sessao, instrucoes: RespostaFalada.instrucoes, idempotencia: entrada.uuidString)
                guard let self else { return }
                self.alterar(assunto, entrada) { $0.runID = run }
                self.guardar()
                VigiaRuns.partilhado.vigiar(cliente.pedidoEventos(run), descricao: Self.descricao(assunto, entrada, run))
                let titulo = self.assunto(assunto)?.titulo ?? "Akili"
                Task { try? await cliente.vigiar(run: run, assunto: assunto, titulo: titulo, entrada: entrada.uuidString) }
                await self.acompanhar(assunto: assunto, entrada: entrada, run: run, cliente: cliente)
            } catch {
                if Task.isCancelled { return }   // app foi para segundo plano; retomar() volta a tentar
                self?.concluir(assunto: assunto, entrada: entrada, status: "failed", erro: error.localizedDescription)
            }
        }
    }

    // MARK: Acompanhar

    /// Enquanto a app está aberta: lê o estado do run e o histórico da sessão até o run acabar.
    private func acompanhar(assunto: String, entrada: UUID, run: String, cliente: HermesClient) async {
        let sessao = sessaoID(assunto)
        var falhas = 0
        while !Task.isCancelled {
            do {
                async let estado = cliente.estadoRun(run)
                async let historico = cliente.mensagens(sessao: sessao)
                let (e, m) = try await (estado, historico)
                sincronizar(assunto, entrada, com: m, texto: true)
                guard let e else {
                    // O Hermes já não guarda o run: acabou há algum tempo; o histórico tem a resposta.
                    concluir(assunto: assunto, entrada: entrada, status: "completed")
                    return
                }
                // Pedidos de um tipo já permitido neste assunto são aprovados pelo ProDesk: não mostrar.
                let permitidos = Set(self.assunto(assunto)?.permitidos ?? [])
                let visivel = e.aprovacao.flatMap { p in
                    (p.padroes ?? []).isEmpty || !Set(p.padroes ?? []).isSubset(of: permitidos) ? p : nil
                }
                if !e.terminal, assuntoEntrada(assunto, entrada)?.aprovacao != visivel {
                    alterar(assunto, entrada) { $0.aprovacao = visivel }
                    guardar()
                }
                if e.terminal {
                    concluir(assunto: assunto, entrada: entrada, status: e.status, output: e.output,
                             tokensEntrada: e.tokensEntrada, tokensSaida: e.tokensSaida, tokensCache: e.tokensCache, modelo: e.modelo, erro: e.erro)
                    return
                }
                falhas = 0
            } catch {
                falhas += 1
            }
            try? await Task.sleep(for: .seconds(falhas == 0 ? 1.5 : 5))
        }
    }

    /// Ao voltar à app: retoma o acompanhamento de tudo o que ainda está a correr e volta a armar a
    /// `VigiaRuns` (o `pausarAcompanhamento` desligou-a, para o iPhone arrefecer).
    func retomar() {
        Task { await testarLigacao() }
        atualizarPrecos()
        if let token = UserDefaults.standard.string(forKey: "tokenPush") { registarDispositivo(token) }
        for a in assuntos {
            for (j, e) in a.entradas.enumerated() where e.estado == .aCorrer && tarefas[e.id] == nil {
                if let run = e.runID, let cliente = cliente {
                    VigiaRuns.partilhado.esquecer(descricao: Self.descricao(a.id, e.id, run))
                    VigiaRuns.partilhado.vigiar(cliente.pedidoEventos(run), descricao: Self.descricao(a.id, e.id, run))
                    tarefas[e.id] = Task { [weak self] in
                        await self?.acompanhar(assunto: a.id, entrada: e.id, run: run, cliente: cliente)
                    }
                } else if j > 0, a.entradas[j - 1].autor == .eu {
                    iniciar(assunto: a.id, entrada: e.id)
                }
            }
        }
    }

    /// Ao sair da app ou bloquear o ecrã: pára de consultar o servidor e desliga os fluxos de eventos
    /// em segundo plano (são eles que mantêm o rádio do iPhone acordado e o aquecem). O run continua
    /// no ProDesk e, com o push ligado, é ele que avisa; sem push, a `VigiaRuns` fica à escuta.
    func pausarAcompanhamento() {
        tarefas.values.forEach { $0.cancel() }
        tarefas.removeAll()
        Leitor.partilhado.parar()
        if UserDefaults.standard.bool(forKey: "pushAtivo") {
            for a in assuntos {
                for e in a.entradas where e.estado == .aCorrer {
                    if let run = e.runID { VigiaRuns.partilhado.esquecer(descricao: Self.descricao(a.id, e.id, run)) }
                }
            }
        }
    }

    /// Pede ao Hermes para parar. O estado final chega pelo acompanhamento.
    func parar(_ id: String) {
        guard let a = assunto(id), let e = a.entradas.last, e.estado == .aCorrer else { return }
        if let run = e.runID, let cliente = cliente {
            Task { try? await cliente.pararRun(run) }
        } else {
            tarefas[e.id]?.cancel()
            tarefas[e.id] = nil
            concluir(assunto: id, entrada: e.id, status: "cancelled")
        }
    }

    /// Responde ao pedido de autorização pendente no assunto: `once`, `session` ou `deny`.
    ///
    /// No Hermes, `session` só dura até ao fim desta resposta; por isso, "sempre neste assunto" também
    /// guarda os tipos de comando no ProDesk, que passa a aprová-los sozinho nas respostas seguintes.
    func aprovar(_ id: String, escolha: String) async throws {
        guard let a = assunto(id), let e = a.entradas.last, let pedido = e.aprovacao,
              let run = e.runID, let cliente = cliente
        else { return }
        try await cliente.responderAprovacao(run: run, pedidoID: pedido.pedidoID, escolha: escolha)
        alterar(id, e.id) { $0.aprovacao = nil }
        if escolha == "session", let padroes = pedido.padroes, !padroes.isEmpty {
            try await lembrar(padroes, em: id, cliente: cliente)
        }
        guardar()
    }

    private func lembrar(_ padroes: [String], em assunto: String, cliente: HermesClient) async throws {
        try await cliente.permitir(assunto: assunto, padroes: padroes)
        if let i = indice(assunto) {
            assuntos[i].permitidos = Array(Set(assuntos[i].permitidos ?? []).union(padroes)).sorted()
        }
    }

    // MARK: Cores, gasto e definições

    /// A cor menos usada entre os assuntos recentes, para os separadores não se repetirem.
    private func proximaCor() -> CorAssunto {
        let usadas = assuntos.prefix(12).map(\.corAssunto)
        return CorAssunto.allCases.min { a, b in usadas.filter { $0 == a }.count < usadas.filter { $0 == b }.count } ?? .verde
    }

    func mudarCor(_ id: String, para cor: CorAssunto) {
        guard let i = indice(id) else { return }
        assuntos[i].cor = cor
        guardar()
    }

    /// Custo, em dólares, das respostas deste dia ou deste mês (a app mostra-o em euros).
    func gasto(_ periodo: Calendar.Component) -> Double {
        let cal = Calendar.current
        return assuntos.flatMap(\.entradas)
            .filter { $0.autor == .agente && cal.isDate($0.data, equalTo: .now, toGranularity: periodo) }
            .reduce(0) { $0 + precos.total($1) }
    }

    func atualizarDefinicoes() async {
        guard let cliente = cliente else { return }
        async let estado = try? cliente.estadoAgente()
        async let lista = try? cliente.permitidos()
        let (e, l) = await (estado, lista)
        if let e { agente = e }
        if let l { permitidos = l }
    }

    func retirarPermissao(assunto: String, padrao: String) async {
        guard let cliente = cliente else { return }
        guard (try? await cliente.retirar(assunto: assunto, padrao: padrao)) != nil else { return }
        permitidos[assunto]?.removeAll { $0 == padrao }
        if permitidos[assunto]?.isEmpty == true { permitidos[assunto] = nil }
        if let i = indice(assunto) {
            assuntos[i].permitidos?.removeAll { $0 == padrao }
            guardar()
        }
    }

    // MARK: Push

    /// Guarda o token do iPhone e regista-o no ProDesk (repetido a cada abertura, para o caso de o ProDesk o ter perdido).
    func registarDispositivo(_ token: String) {
        UserDefaults.standard.set(token, forKey: "tokenPush")
        guard let cliente = cliente else { return }
        #if DEBUG
        let ambiente = "sandbox"
        #else
        let ambiente = "producao"
        #endif
        Task {
            if let ligado = try? await cliente.registarDispositivo(token, ambiente: ambiente) {
                UserDefaults.standard.set(ligado, forKey: "pushAtivo")
            }
        }
    }

    /// Resposta dada a partir dos botões da notificação (a app pode estar em segundo plano).
    func responderPorAviso(run: String, pedido: String, escolha: String, padroes: [String] = []) async {
        guard let cliente = cliente else { return }
        do {
            try await cliente.responderAprovacao(run: run, pedidoID: pedido, escolha: escolha)
            if escolha == "session", !padroes.isEmpty,
               let assunto = assuntos.first(where: { $0.entradas.contains { $0.runID == run } })?.id {
                try await lembrar(padroes, em: assunto, cliente: cliente)
            }
        } catch {
            return
        }
        for a in assuntos {
            if let e = a.entradas.last(where: { $0.runID == run }), e.aprovacao?.pedidoID == pedido {
                alterar(a.id, e.id) { $0.aprovacao = nil }
            }
        }
        guardar()
    }

    func apagar(_ id: String) {
        parar(id)
        for e in assunto(id)?.entradas ?? [] { tarefas[e.id]?.cancel(); tarefas[e.id] = nil }
        assuntos.removeAll { $0.id == id }
        guardar()
    }

    // MARK: Fim

    /// A transferência em segundo plano terminou: o fluxo de eventos fechou porque o run acabou.
    private func terminouNoServidor(_ descricao: String, _ fim: FimDeRun?) {
        let partes = descricao.split(separator: "|").map(String.init)
        guard partes.count == 3, let entrada = UUID(uuidString: partes[1]) else { return }
        let (assunto, run) = (partes[0], partes[2])
        if let fim {
            concluir(assunto: assunto, entrada: entrada, status: fim.status, output: fim.output,
                     tokensEntrada: fim.tokensEntrada, tokensSaida: fim.tokensSaida, tokensCache: fim.tokensCache, modelo: fim.modelo, erro: fim.erro)
        } else if let cliente = cliente {
            Task { [weak self] in
                guard let e = try? await cliente.estadoRun(run), e.terminal else { return }
                self?.concluir(assunto: assunto, entrada: entrada, status: e.status, output: e.output,
                               tokensEntrada: e.tokensEntrada, tokensSaida: e.tokensSaida, tokensCache: e.tokensCache, modelo: e.modelo, erro: e.erro)
            }
        }
    }

    private func concluir(
        assunto: String, entrada: UUID, status: String, output: String? = nil,
        tokensEntrada: Int? = nil, tokensSaida: Int? = nil, tokensCache: Int? = nil,
        modelo: String? = nil, erro: String? = nil
    ) {
        guard let i = indice(assunto),
              let j = assuntos[i].entradas.firstIndex(where: { $0.id == entrada }),
              assuntos[i].entradas[j].estado == .aCorrer
        else { return }

        alterar(assunto, entrada) { e in
            switch status {
            case "completed": e.estado = .feito
            case "cancelled": e.estado = .parado
            case "interrupted":
                e.estado = .parado
                e.erro = "O ProDesk reiniciou a meio."
            default:
                e.estado = .falhou
                e.erro = erro ?? "O agente falhou."
            }
            if let output, !output.isEmpty { e.texto = output }
            e.texto = e.texto.trimmingCharacters(in: .whitespacesAndNewlines)
            e.tokensEntrada = tokensEntrada ?? e.tokensEntrada
            e.tokensSaida = tokensSaida ?? e.tokensSaida
            e.tokensCache = tokensCache ?? e.tokensCache
            e.modelo = modelo ?? e.modelo
            e.duracao = Date().timeIntervalSince(e.data)
            e.aprovacao = nil
        }
        assuntos[i].atualizado = .now
        tarefas[entrada]?.cancel()
        tarefas[entrada] = nil
        let final = assuntos[i].entradas[j]
        if let run = final.runID { VigiaRuns.partilhado.esquecer(descricao: Self.descricao(assunto, entrada, run)) }
        guardar()

        // Com push ligado, é o ProDesk que avisa; sem ele, a app avisa localmente.
        if UIApplication.shared.applicationState != .active && !UserDefaults.standard.bool(forKey: "pushAtivo") {
            Notificacoes.avisar(assunto: assuntos[i], entrada: final)
        }

        // Os passos finais podem ainda não ter sido lidos.
        if let cliente = cliente {
            let sessao = sessaoID(assunto)
            Task { [weak self] in
                guard let m = try? await cliente.mensagens(sessao: sessao) else { return }
                self?.sincronizar(assunto, entrada, com: m, texto: false)
                self?.guardar()
            }
        }
    }

    // MARK: Histórico da sessão → passos

    /// Reconstrói os passos (e, durante o run, o texto) a partir das mensagens posteriores ao pedido.
    private func sincronizar(_ assunto: String, _ entrada: UUID, com mensagens: [MensagemSessao], texto: Bool) {
        guard let i = indice(assunto),
              let j = assuntos[i].entradas.firstIndex(where: { $0.id == entrada }),
              j > 0
        else { return }
        let pedido = assuntos[i].entradas[j - 1].pedidoEnviado ?? assuntos[i].entradas[j - 1].texto
        // Só conta a partir do nosso pedido; antes de o Hermes o registar, ainda não há nada deste run.
        guard let inicio = mensagens.lastIndex(where: { $0.papel == "user" && $0.conteudo == pedido }) else { return }

        var passos: [Passo] = []
        var resposta: String?
        for m in mensagens[(inicio + 1)...] {
            switch m.papel {
            case "assistant":
                for (k, c) in m.chamadas.enumerated() {
                    passos.append(Passo(id: "\(m.id)-\(k)", chamada: c.id, ferramenta: c.nome, argumentos: c.argumentos, inicio: m.data))
                }
                if m.chamadas.isEmpty, !m.conteudo.isEmpty { resposta = m.conteudo }
            case "tool":
                if let k = passos.firstIndex(where: { $0.resultado == nil && $0.chamada == m.idChamada }) {
                    passos[k].resultado = HermesClient.textoDoResultado(m.conteudo)
                    passos[k].fim = m.data
                }
            default:
                break
            }
        }
        alterar(assunto, entrada) { e in
            if e.passos != passos { e.passos = passos }
            if texto, let resposta, e.texto != resposta { e.texto = resposta.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    // MARK: Utilitários

    private static func descricao(_ assunto: String, _ entrada: UUID, _ run: String) -> String {
        "\(assunto)|\(entrada.uuidString)|\(run)"
    }

    private func alterar(_ assunto: String, _ entrada: UUID, _ mudar: (inout Entrada) -> Void) {
        guard let i = indice(assunto),
              let j = assuntos[i].entradas.firstIndex(where: { $0.id == entrada })
        else { return }
        mudar(&assuntos[i].entradas[j])
    }

    private func indice(_ id: String) -> Int? { assuntos.firstIndex { $0.id == id } }

    private func assuntoEntrada(_ assunto: String, _ entrada: UUID) -> Entrada? {
        self.assunto(assunto)?.entradas.first { $0.id == entrada }
    }

    /// Texto enviado ao agente: o teu pedido e, se houver, onde ficaram as fotos no ProDesk.
    static func compor(_ texto: String, fotos: [String]) -> String {
        guard !fotos.isEmpty else { return texto }
        let base = texto.isEmpty ? "Vê o que te mandei." : texto
        let umas = fotos.count == 1 ? "uma foto, guardada" : "\(fotos.count) fotos, guardadas"
        let pron = fotos.count == 1 ? "a" : "as"
        return base + "\n\n[Anexei \(umas) no ProDesk em: \(fotos.joined(separator: ", ")). Usa a ferramenta de visão para \(pron) ver.]"
    }

    static func titulo(de texto: String) -> String {
        let palavras = texto.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        return palavras.isEmpty ? "Novo assunto" : palavras
    }

    // MARK: Guardar no iPhone

    private var ficheiro: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "assuntos.json")
    }

    private func carregar() {
        guard let dados = try? Data(contentsOf: ficheiro),
              let lidos = try? JSONDecoder().decode([Assunto].self, from: dados)
        else { return }
        assuntos = lidos
    }

    private func guardar() {
        let destino = ficheiro
        try? FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dados = try? JSONEncoder().encode(assuntos) else { return }
        try? dados.write(to: destino, options: .atomic)
    }
}
