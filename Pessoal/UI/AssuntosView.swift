import SwiftUI

enum Rota: Hashable {
    case assunto(String)
    case definicoes
}

/// Ecrã inicial: resumo no topo, o que precisa de ti em âmbar, o resto numa folha com separadores.
struct AssuntosView: View {
    @Environment(Store.self) private var store
    @State private var caminho: [Rota] = []
    @State private var pedido = ""
    @State private var fotos: [UIImage] = []

    var body: some View {
        NavigationStack(path: $caminho) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cabecalho
                    if !store.configurado { avisoLigacao }
                    lista
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(P.papel)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                Composer(texto: $pedido, fotos: $fotos, placeholder: "Pedir uma coisa nova…", ativo: store.configurado) {
                    let id = store.novoAssunto(com: pedido, fotos: fotos.compactMap { AnexosLocais.preparar($0) })
                    pedido = ""
                    fotos = []
                    caminho.append(.assunto(id))
                }
            }
            .navigationDestination(for: Rota.self) { rota in
                switch rota {
                case .assunto(let id): CadernoView(assuntoID: id)
                case .definicoes: DefinicoesView()
                }
            }
            .task { store.retomar() }
            .onChange(of: store.abrirAssunto) { _, id in
                guard let id, store.assunto(id) != nil else { return }
                caminho = [.assunto(id)]
                store.abrirAssunto = nil
            }
        }
    }

    private var precisam: [Assunto] { store.assuntos.filter { $0.aprovacaoPendente != nil } }
    private var aCorrer: [Assunto] { store.assuntos.filter { $0.aCorrer && $0.aprovacaoPendente == nil } }
    private var recentes: [Assunto] { store.assuntos.filter { !$0.aCorrer }.sorted { $0.atualizado > $1.atualizado } }

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Assuntos")
                    .font(Letra.titulo(40))
                    .foregroundStyle(P.tinta)
                Spacer()
                Button {
                    caminho.append(.definicoes)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(P.tinta)
                        .frame(width: 44, height: 44)
                        .background(P.folha, in: Circle())
                }
                .accessibilityLabel("Definições")
            }
            HStack(spacing: 8) {
                if !precisam.isEmpty {
                    Resumo(numero: "\(precisam.count)", texto: "precisa de ti", fundo: P.ambarFundo, cor: P.ambarTexto)
                }
                if !aCorrer.isEmpty {
                    Resumo(numero: "\(aCorrer.count)", texto: "a trabalhar", fundo: CorAssunto.mostarda.fundo, cor: CorAssunto.mostarda.texto)
                }
                Resumo(numero: store.precos.euros(store.gasto(.month)),
                       texto: "em " + Date.now.formatted(.dateTime.month(.wide)),
                       fundo: P.tinta, cor: P.sobreTinta)
            }
            if case .erro(let mensagem) = store.ligacao {
                Text("Sem ligação ao ProDesk · \(mensagem)")
                    .font(Letra.mono(11))
                    .foregroundStyle(P.perigo)
            }
        }
    }

    private var avisoLigacao: some View {
        Button {
            caminho.append(.definicoes)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Falta a chave de acesso ao agente.")
                    .font(Letra.fala(16))
                    .foregroundStyle(P.tinta)
                Text("Abrir definições")
                    .font(Letra.ui(15, .bold))
                    .foregroundStyle(CorAssunto.ultramar.texto)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(P.folha, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var lista: some View {
        if !precisam.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                TituloSeccao(texto: "Precisa de ti", cor: P.ambarTexto).padding(.leading, 2)
                ForEach(precisam) { a in
                    ligacao(a) {
                        LinhaAssunto(assunto: a)
                            .padding(14)
                            .background(P.ambarFundo, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
        let resto = aCorrer + recentes
        if !resto.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(resto.enumerated()), id: \.element.id) { i, a in
                    ligacao(a) {
                        LinhaAssunto(assunto: a)
                            .padding(.vertical, 14)
                            .overlay(alignment: .top) { if i > 0 { Traco() } }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(P.folha, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func ligacao<C: View>(_ a: Assunto, @ViewBuilder _ conteudo: () -> C) -> some View {
        NavigationLink(value: Rota.assunto(a.id)) { conteudo() }
            .buttonStyle(.plain)
            .contextMenu {
                Menu("Cor") {
                    ForEach(CorAssunto.allCases, id: \.self) { cor in
                        Button(cor.rawValue.capitalized) { store.mudarCor(a.id, para: cor) }
                    }
                }
                Button("Apagar assunto", role: .destructive) { store.apagar(a.id) }
            }
    }
}

struct Resumo: View {
    let numero: String
    let texto: String
    let fundo: Color
    let cor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(numero)
                .font(Letra.titulo(22))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(texto)
                .font(Letra.ui(12, .bold))
                .lineLimit(1)
        }
        .foregroundStyle(cor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(fundo, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct LinhaAssunto: View {
    @Environment(Store.self) private var store
    let assunto: Assunto

    var body: some View {
        let cor = assunto.corAssunto
        HStack(alignment: .top, spacing: 14) {
            Separador(assunto: assunto)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(assunto.titulo)
                        .font(Letra.ui(17, .bold))
                        .foregroundStyle(P.tinta)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(assunto.aCorrer ? "a correr" : assunto.atualizado.formatoCurto)
                        .font(Letra.mono(11, media: true))
                        .foregroundStyle(assunto.aCorrer ? cor.texto : P.suave)
                }
                let fala = RespostaFalada(assunto.ultimaLinha).fala
                if !fala.isEmpty {
                    Text(fala)
                        .font(Letra.fala(15))
                        .foregroundStyle(P.corpo)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 10) {
                    if let pedido = assunto.aprovacaoPendente {
                        Text("Aprovar · \(pedido.motivoLegivel)")
                            .font(Letra.ui(12, .bold))
                            .foregroundStyle(P.ambarTexto)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(P.folha, in: Capsule())
                    } else if assunto.aCorrer, let ultimo = assunto.entradas.last?.passos.last {
                        HStack(spacing: 6) {
                            Circle().fill(cor.marca).frame(width: 7, height: 7)
                            Text(ultimo.resumo)
                        }
                        .font(Letra.mono(11))
                        .foregroundStyle(P.suave)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(store.precos.euros(store.precos.total(assunto)))
                        .font(Letra.mono(11))
                        .foregroundStyle(P.suave)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
