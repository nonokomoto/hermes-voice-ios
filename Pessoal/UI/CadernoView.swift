import SafariServices
import SwiftUI

/// Uma conversa: faixa com a cor do assunto no topo, as tuas mensagens curtas, a resposta em voz
/// com legenda, as ligações à parte e as ferramentas na margem.
struct CadernoView: View {
    @Environment(Store.self) private var store
    let assuntoID: String

    @State private var texto = ""
    @State private var fotos: [UIImage] = []
    @State private var passosDe: UUID?
    @State private var ligacaoAberta: Ligacao?
    @AppStorage("tocarSozinho") private var tocarSozinho = true

    private var assunto: Assunto? { store.assunto(assuntoID) }
    private var entradas: [Entrada] { assunto?.entradas ?? [] }
    private var cor: CorAssunto { assunto?.corAssunto ?? .ultramar }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entradas.enumerated()), id: \.element.id) { i, e in
                        if i == 0 || !Calendar.current.isDate(e.data, inSameDayAs: entradas[i - 1].data) {
                            DivisorDia(data: e.data)
                        }
                        LinhaEntrada(
                            entrada: e,
                            assunto: assunto,
                            ultima: i == entradas.count - 1,
                            verPassos: { passosDe = e.id },
                            abrir: { ligacaoAberta = $0 },
                            aprovar: { escolha in try await store.aprovar(assuntoID, escolha: escolha) }
                        )
                    }
                    Color.clear.frame(height: 1).id("fim")
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entradas.last?.texto) { _, _ in proxy.scrollTo("fim", anchor: .bottom) }
            .onChange(of: entradas.last?.passos.count) { _, _ in proxy.scrollTo("fim", anchor: .bottom) }
            .onChange(of: entradas.last?.aprovacao) { _, _ in proxy.scrollTo("fim", anchor: .bottom) }
        }
        .background(P.folha)
        .safeAreaInset(edge: .top, spacing: 0) { faixa }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(cor.faixa, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(cor.texto)
        .safeAreaInset(edge: .bottom) {
            if assunto?.aCorrer == true {
                BarraParar(cor: cor) { store.parar(assuntoID) }
            } else {
                Composer(texto: $texto, fotos: $fotos, placeholder: "Escrever em \(assunto?.titulo ?? "")…",
                         ativo: store.configurado, cor: cor.marca, corTexto: cor.sobreMarca) {
                    store.enviar(texto, em: assuntoID, fotos: fotos.compactMap { AnexosLocais.preparar($0) })
                    texto = ""
                    fotos = []
                }
            }
        }
        // Quando uma resposta acaba com o assunto aberto, toca sozinha.
        .onChange(of: entradas.last?.estado) { antigo, novo in
            guard antigo == .aCorrer, novo == .feito, tocarSozinho, let e = entradas.last else { return }
            let fala = RespostaFalada(e.texto).fala
            let id = e.id
            Leitor.partilhado.tocar(id, fala: fala) { try await store.audio(de: fala, entrada: id) }
        }
        .sheet(isPresented: Binding(get: { passosDe != nil }, set: { if !$0 { passosDe = nil } })) {
            if let id = passosDe {
                PassosSheet(assuntoID: assuntoID, entradaID: id)
            }
        }
        .sheet(item: $ligacaoAberta) { l in
            Safari(url: l.url).ignoresSafeArea()
        }
    }

    /// Faixa do topo: separador, nome do assunto em Young Serif, número de respostas e custo.
    private var faixa: some View {
        HStack(spacing: 12) {
            if let assunto { Separador(assunto: assunto, tamanho: 44) }
            VStack(alignment: .leading, spacing: 2) {
                Text(assunto?.titulo ?? "")
                    .font(Letra.titulo(28))
                    .foregroundStyle(cor.textoFaixa)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(meta)
                    .font(Letra.mono(11))
                    .foregroundStyle(cor.textoFaixa.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(cor.faixa)
    }

    private var meta: String {
        let respostas = entradas.filter { $0.autor == .agente }.count
        let estado = assunto?.aprovacaoPendente != nil ? "à espera de ti" : (assunto?.aCorrer == true ? "a trabalhar" : "\(respostas) respostas")
        let custo = assunto.map { store.precos.euros(store.precos.total($0)) } ?? ""
        return "\(estado) · \(custo)"
    }
}

struct DivisorDia: View {
    let data: Date

    var body: some View {
        let dia = data.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).uppercased()
        Text(Calendar.current.isDateInToday(data) ? "HOJE · \(dia)" : dia)
            .font(Letra.mono(10, media: true))
            .tracking(1)
            .foregroundStyle(P.suave)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

struct LinhaEntrada: View {
    @Environment(Store.self) private var store
    let entrada: Entrada
    let assunto: Assunto?
    let ultima: Bool
    let verPassos: () -> Void
    let abrir: (Ligacao) -> Void
    let aprovar: (String) async throws -> Void

    @State private var expandida = false
    @State private var pedidoCompleto = false

    private var aCorrer: Bool { entrada.estado == .aCorrer }
    private var cor: CorAssunto { assunto?.corAssunto ?? .ultramar }

    static let maxPalavras = 14
    static let palavrasVisiveis = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entrada.data.hora)
                .font(Letra.mono(11))
                .foregroundStyle(P.suave)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                if entrada.autor == .eu { pedido } else { resposta }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !ultima { Traco(cor: P.linhaFina) }
        }
    }

    // MARK: A tua mensagem: leve e truncada pelo número de palavras

    @ViewBuilder
    private var pedido: some View {
        if let anexos = entrada.anexos, !anexos.isEmpty {
            HStack(spacing: 8) {
                ForEach(anexos, id: \.self) { nome in
                    if let img = AnexosLocais.imagem(nome) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel("Foto anexada")
                    }
                }
            }
        }
        if !entrada.texto.isEmpty {
            let palavras = entrada.texto.split(whereSeparator: \.isWhitespace)
            if palavras.count > Self.maxPalavras && !pedidoCompleto {
                (Text(palavras.prefix(Self.palavrasVisiveis).joined(separator: " ") + "… ")
                    + Text("ver tudo").font(Letra.ui(14, .bold)).foregroundColor(cor.texto))
                    .font(Letra.ui(15, .medium))
                    .foregroundStyle(P.corpo)
                    .lineSpacing(2)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { pedidoCompleto = true } }
                    .accessibilityHint("Toca para ler a mensagem inteira")
            } else {
                Text(entrada.texto)
                    .font(Letra.ui(15, .medium))
                    .foregroundStyle(P.corpo)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: A resposta da Akili

    @ViewBuilder
    private var resposta: some View {
        let r = RespostaFalada(entrada.texto)

        if let pedido = entrada.aprovacao {
            CartaoAprovacao(aprovacao: pedido, assunto: assunto, responder: aprovar)
        }

        if aCorrer {
            if !r.fala.isEmpty {
                Text(r.fala + "▍")
                    .font(Letra.fala(17))
                    .foregroundStyle(P.tinta)
                    .lineSpacing(4)
            }
        } else if !r.fala.isEmpty {
            LinhaVoz(id: entrada.id, fala: r.fala, cor: cor)
            Text(r.fala)
                .font(Letra.fala(17))
                .foregroundStyle(P.tinta)
                .lineSpacing(4)
                .lineLimit(expandida ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expandida.toggle() } }
        }

        if !r.ligacoes.isEmpty {
            VStack(spacing: 8) {
                ForEach(r.ligacoes) { l in
                    Button { abrir(l) } label: {
                        HStack(spacing: 12) {
                            Text(String(l.dominio.prefix(1)).uppercased())
                                .font(Letra.titulo(16))
                                .foregroundStyle(cor.texto)
                                .frame(width: 34, height: 34)
                                .background(cor.fundo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.titulo)
                                    .font(Letra.ui(15, .bold))
                                    .foregroundStyle(P.tinta)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(l.dominio)
                                    .font(Letra.mono(11))
                                    .foregroundStyle(P.suave)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(cor.texto)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(P.folha, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.linha))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Abre \(l.dominio)")
                }
            }
        }

        margem
    }

    private var margem: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entrada.passos) { p in
                if aCorrer && p.fim == nil {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(cor.marca)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(cor.fundo, lineWidth: 4).scaleEffect(1.5))
                        Text("\(p.resumo)…")
                    }
                    .foregroundStyle(P.tinta)
                } else {
                    Text("› \(p.resumo)")
                }
            }
            if aCorrer {
                TimelineView(.periodic(from: entrada.data, by: 1)) { contexto in
                    let s = Int(contexto.date.timeIntervalSince(entrada.data))
                    Text(entrada.passos.isEmpty ? "a pensar · \(s) s" : "\(entrada.passos.count) passos · \(s) s")
                }
            }
            if entrada.estado == .parado { Text("› parado") }
            if let erro = entrada.erro {
                Text("› falhou · \(erro)").foregroundStyle(P.perigo)
            }
            if !aCorrer, let rodape = rodape {
                Button(action: verPassos) {
                    Text(rodape)
                        .font(Letra.mono(11, media: true))
                        .foregroundStyle(cor.texto)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Letra.mono(11))
        .foregroundStyle(P.suave)
        .lineLimit(2)
    }

    private var rodape: String? {
        var partes: [String] = []
        if let d = entrada.duracao { partes.append("\(Int(d.rounded())) s") }
        if !entrada.passos.isEmpty { partes.append("\(entrada.passos.count) \(entrada.passos.count == 1 ? "passo" : "passos")") }
        if store.precos.chamada(entrada) != nil { partes.append(store.precos.euros(store.precos.total(entrada))) }
        guard !partes.isEmpty else { return nil }
        partes.append(entrada.passos.isEmpty ? "detalhes" : "ver passos")
        return partes.joined(separator: " · ")
    }
}

/// Cápsula de voz: botão de ouvir na cor do assunto, onda com o progresso, tempo e velocidade.
struct LinhaVoz: View {
    @Environment(Store.self) private var store
    let id: UUID
    let fala: String
    let cor: CorAssunto

    private var leitor: Leitor { .partilhado }

    /// Alturas da onda, estáveis por resposta (decorativas: não é a forma real do áudio).
    private var alturas: [CGFloat] {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return (0..<30).map { i in CGFloat(5 + Int(bytes[i % 16] ^ UInt8(i * 7 & 0xFF)) % 17) }
    }

    var body: some View {
        let estado = leitor.estado(de: id)
        let ativa = leitor.entrada == id
        let feitas = Int(Double(alturas.count) * (ativa ? leitor.progresso : 0))

        HStack(spacing: 10) {
            Button {
                let store = store
                let fala = fala
                let entradaID = self.id
                leitor.alternar(entradaID, fala: fala) { try await store.audio(de: fala, entrada: entradaID) }
            } label: {
                ZStack {
                    Circle().fill(cor.marca)
                    if estado == .aPreparar {
                        ProgressView().controlSize(.small).tint(cor.sobreMarca)
                    } else {
                        Image(systemName: estado == .aTocar ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(cor.sobreMarca)
                            .offset(x: estado == .aTocar ? 0 : 1)
                    }
                }
                .frame(width: 40, height: 40)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(estado == .aTocar ? "Pausa" : "Ouvir resposta")

            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(alturas.enumerated()), id: \.offset) { i, h in
                    Capsule()
                        .fill(ativa ? (i < feitas ? cor.marca : P.folha) : cor.marca.opacity(0.4))
                        .frame(width: 3, height: h)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26)
            .clipped()
            .accessibilityHidden(true)

            Text(rotulo(estado))
                .font(Letra.mono(12, media: true))
                .foregroundStyle(P.corpo)
                .monospacedDigit()

            Button { leitor.mudarVelocidade() } label: {
                Text(Leitor.texto(leitor.velocidade))
                    .font(Letra.mono(11, media: true))
                    .foregroundStyle(P.tinta)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 30)
                    .background(P.folha, in: Capsule())
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Velocidade \(Leitor.texto(leitor.velocidade))")
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(cor.fundo, in: Capsule())
    }

    private func rotulo(_ estado: Leitor.Estado) -> String {
        switch estado {
        case .aPreparar: return "…"
        case .parado: return "ouvir"
        case .aTocar, .emPausa:
            guard leitor.duracao > 0 else { return "a falar" }
            let resta = Int((leitor.duracao * (1 - leitor.progresso) / Double(leitor.velocidade)).rounded())
            return String(format: "%d:%02d", resta / 60, resta % 60)
        }
    }
}

/// Safari dentro da app, para abrir uma ligação sem sair da conversa.
struct Safari: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

struct BarraParar: View {
    var cor: CorAssunto = .ultramar
    let parar: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: parar) {
                Label("Parar", systemImage: "stop.fill")
                    .font(Letra.ui(16, .bold))
                    .foregroundStyle(cor.texto)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(cor.fundo, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Podes sair da app. Aviso-te quando acabar.")
                .font(Letra.ui(13))
                .foregroundStyle(P.suave)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(P.folha)
        .overlay(alignment: .top) { Traco() }
    }
}
