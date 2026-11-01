import SwiftUI

/// Definições em grupos com cor própria: ligação, agente, voz, gasto, permitidos sempre e acesso.
struct DefinicoesView: View {
    @Environment(Store.self) private var store
    @State private var chaveNova = ""
    @AppStorage("tocarSozinho") private var tocarSozinho = true

    private var leitor: Leitor { .partilhado }

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Definições")
                    .font(Letra.titulo(36))
                    .padding(.horizontal, 4)

                estadoLigacao

                Grupo(titulo: "Agente", cor: .ultramar, icone: "brain") {
                    Linha(rotulo: "Modelo") { Valor(store.agente?.modelo ?? "—") }
                    Linha(rotulo: "Reserva", sub: "quando o principal falha", ultimo: true) {
                        Valor(store.agente?.reservas.first ?? "nenhuma")
                    }
                }

                Grupo(titulo: "Voz", cor: .verde, icone: "speaker.wave.2.fill") {
                    Linha(rotulo: "Voz") { Valor(store.agente?.voz ?? "—") }
                    Linha(rotulo: "Tocar respostas sozinho") {
                        Toggle("", isOn: $tocarSozinho).labelsHidden().tint(CorAssunto.verde.marca)
                    }
                    Linha(rotulo: "Velocidade", ultimo: true) {
                        Picker("Velocidade", selection: Binding(get: { leitor.velocidade }, set: { leitor.mudarVelocidade($0) })) {
                            ForEach(Leitor.velocidades, id: \.self) { v in Text(Leitor.texto(v)).tag(v) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }

                Grupo(titulo: "Gasto", cor: .mostarda, icone: "eurosign.circle.fill") {
                    Linha(rotulo: "Hoje") { Valor(store.precos.euros(store.gasto(.day))) }
                    Linha(rotulo: Date.now.formatted(.dateTime.month(.wide)).capitalized, sub: "estimado a partir dos tokens", ultimo: true) {
                        Valor(store.precos.euros(store.gasto(.month)))
                    }
                }

                Grupo(titulo: "Permitidos sempre", corLivre: P.ambar, icone: "checkmark.shield.fill") {
                    let itens = store.permitidos.sorted { $0.key < $1.key }.flatMap { a, ps in ps.map { (a, $0) } }
                    if itens.isEmpty {
                        Linha(rotulo: "Nenhum", sub: "Escolhe \"Permitir sempre\" num pedido de aprovação", ultimo: true) { EmptyView() }
                    } else {
                        ForEach(Array(itens.enumerated()), id: \.offset) { i, item in
                            let (assuntoID, padrao) = item
                            Linha(rotulo: store.assunto(assuntoID)?.titulo ?? "Assunto apagado",
                                  sub: Aprovacao.legivel(padrao),
                                  assunto: store.assunto(assuntoID),
                                  ultimo: i == itens.count - 1) {
                                Button("Retirar") {
                                    Task { await store.retirarPermissao(assunto: assuntoID, padrao: padrao) }
                                }
                                .font(Letra.ui(14, .bold))
                                .foregroundStyle(P.perigo)
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }

                Grupo(titulo: "Acesso", cor: .petroleo, icone: "key.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Servidor").font(Letra.ui(14, .medium)).foregroundStyle(P.corpo)
                        TextField("https://…", text: $store.servidor)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(Letra.mono(13))
                            .padding(12)
                            .background(P.papel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(14)
                    Traco(cor: P.linhaFina)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chave de acesso").font(Letra.ui(14, .medium)).foregroundStyle(P.corpo)
                        SecureField(store.chave.isEmpty ? "Colar chave" : "Guardada no Keychain · colar outra para trocar", text: $chaveNova)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Letra.ui(15))
                            .padding(12)
                            .background(P.papel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        HStack {
                            Button("Guardar chave") {
                                store.chave = chaveNova.trimmingCharacters(in: .whitespacesAndNewlines)
                                chaveNova = ""
                                Task { await store.testarLigacao(); await store.atualizarDefinicoes() }
                            }
                            .disabled(chaveNova.isEmpty)
                            Spacer()
                            Button("Testar ligação") {
                                Task { await store.testarLigacao(); await store.atualizarDefinicoes() }
                            }
                        }
                        .font(Letra.ui(15, .bold))
                        .foregroundStyle(CorAssunto.petroleo.texto)
                        .frame(minHeight: 44)
                    }
                    .padding(14)
                }

                Text("Akili \(versao) · Hermes · perfil pessoal")
                    .font(Letra.mono(10))
                    .foregroundStyle(P.suave)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .foregroundStyle(P.tinta)
        .background(P.papel)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(P.tinta)
        .task { await store.atualizarDefinicoes() }
    }

    private var versao: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var estadoLigacao: some View {
        let (texto, cor): (String, Color) = {
            switch store.ligacao {
            case .ligado: return ("Ligado ao \(store.nomeServidor)", P.ok)
            case .aTestar: return ("A ligar…", P.suave)
            case .porConfigurar: return ("Por configurar", P.suave)
            case .erro(let m): return (m, P.perigo)
            }
        }()
        return HStack(spacing: 12) {
            Circle().fill(cor).frame(width: 10, height: 10)
                .overlay(Circle().stroke(cor.opacity(0.3), lineWidth: 4).scaleEffect(1.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(texto).font(Letra.ui(16, .bold)).lineLimit(2)
                Text("via Tailscale · push \(store.agente?.push == true ? "ligado" : "desligado")")
                    .font(Letra.mono(11))
                    .opacity(0.8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(P.sobreTinta)
        .padding(16)
        .background(P.tinta, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Um grupo das definições: ícone com a cor do grupo, título em mono e folha branca.
struct Grupo<Conteudo: View>: View {
    let titulo: String
    let cor: Color
    let icone: String
    let conteudo: Conteudo

    init(titulo: String, cor: CorAssunto, icone: String, @ViewBuilder conteudo: () -> Conteudo) {
        self.init(titulo: titulo, corLivre: cor.marca, icone: icone, conteudo: conteudo)
    }

    init(titulo: String, corLivre: Color, icone: String, @ViewBuilder conteudo: () -> Conteudo) {
        self.titulo = titulo
        self.cor = corLivre
        self.icone = icone
        self.conteudo = conteudo()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icone)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(cor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                TituloSeccao(texto: titulo)
            }
            .padding(.leading, 2)
            VStack(spacing: 0) { conteudo }
                .background(P.folha, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct Linha<Direita: View>: View {
    let rotulo: String
    var sub: String? = nil
    var assunto: Assunto? = nil
    var ultimo = false
    @ViewBuilder let direita: () -> Direita

    var body: some View {
        HStack(spacing: 12) {
            if let assunto { Separador(assunto: assunto, tamanho: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text(rotulo).font(Letra.ui(16, .medium))
                if let sub { Text(sub).font(Letra.mono(11)).foregroundStyle(P.suave) }
            }
            Spacer(minLength: 8)
            direita()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 54)
        .overlay(alignment: .bottom) { if !ultimo { Traco(cor: P.linhaFina) } }
    }
}

struct Valor: View {
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto)
            .font(Letra.ui(15))
            .foregroundStyle(P.corpo)
            .multilineTextAlignment(.trailing)
    }
}
