import SwiftUI
import UIKit

/// Tudo o que o agente fez numa resposta, e quanto custou (chamada e áudio), em euros.
struct PassosSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let assuntoID: String
    let entradaID: UUID

    private var assunto: Assunto? { store.assunto(assuntoID) }
    private var entrada: Entrada? { assunto?.entradas.first { $0.id == entradaID } }
    private var cor: CorAssunto { assunto?.corAssunto ?? .ultramar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    HStack(spacing: 12) {
                        if let assunto { Separador(assunto: assunto) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("O que ele fez")
                                .font(Letra.titulo(24))
                            Text("\(assunto?.titulo ?? "") · resposta das \(entrada?.data.hora ?? "")")
                                .font(Letra.mono(11))
                                .foregroundStyle(P.suave)
                        }
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(P.tinta)
                    .accessibilityLabel("Fechar")
                    .padding(.top, -6)
                    .padding(.trailing, -10)
                }

                HStack(spacing: 8) {
                    Mosaico(etiqueta: "CHAMADA", valor: custoChamada, nota: entrada?.modelo ?? "—", fundo: cor.fundo, cor: cor.texto)
                    Mosaico(etiqueta: "ÁUDIO", valor: custoAudio.valor, nota: custoAudio.nota, fundo: P.papel, cor: P.tinta)
                }

                if let passos = entrada?.passos, !passos.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(passos) { p in LinhaPasso(passo: p) }
                    }
                    .overlay(alignment: .bottom) { Traco(cor: P.linhaFina) }
                } else {
                    Text("Respondeu sem usar ferramentas.")
                        .font(Letra.fala(16))
                        .foregroundStyle(P.corpo)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Dado(titulo: "ENTRADA", valor: entrada?.tokensEntrada?.formatted() ?? "—")
                        Dado(titulo: "DA CACHE", valor: entrada?.tokensCache?.formatted() ?? "—")
                        Dado(titulo: "SAÍDA", valor: entrada?.tokensSaida?.formatted() ?? "—")
                    }
                    GridRow {
                        Dado(titulo: "TEMPO", valor: entrada?.duracao.map { "\(Int($0.rounded())) s" } ?? "—")
                        Dado(titulo: "PASSOS", valor: "\(entrada?.passos.count ?? 0)")
                        Dado(titulo: "CÂMBIO", valor: cambio)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    UIPasteboard.general.string = registo
                } label: {
                    Text("Copiar registo")
                        .font(Letra.ui(15, .bold))
                        .foregroundStyle(P.tinta)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(P.papel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .foregroundStyle(P.tinta)
        .background(P.folha)
        .presentationDragIndicator(.visible)
    }

    private var custoChamada: String {
        guard let e = entrada else { return "—" }
        if let v = store.precos.chamada(e) { return store.precos.euros(v) }
        return "—"
    }

    private var custoAudio: (valor: String, nota: String) {
        guard let e = entrada, let a = store.precos.audio(e) else { return ("—", "ainda não ouvido") }
        let voz = e.vozAudio.map { $0.hasPrefix("gemini-") ? String($0.dropFirst(7)) : ($0.contains("Raquel") ? "Raquel" : $0) } ?? ""
        let segundos = e.duracaoAudio.map { "\(Int($0.rounded())) s" } ?? ""
        if a.gratuito {
            return ("grátis", "valeria \(store.precos.euros(a.valor)) · \(voz) · \(segundos)")
        }
        return (store.precos.euros(a.valor), "\(voz) · \(segundos)")
    }

    private var cambio: String {
        guard let c = store.precos.cambio else { return "—" }
        return String(format: "%.4f", c.eurPorUsd).replacingOccurrences(of: ".", with: ",") + " € · " + (c.fonte ?? "")
    }

    private var registo: String {
        guard let e = entrada else { return "" }
        var linhas = ["\(assunto?.titulo ?? "") · \(e.data.formatted())"]
        for p in e.passos {
            linhas.append("[\(p.inicio.formatted(.dateTime.hour().minute().second()))] \(p.ferramenta) \(p.argumentos)")
            if let r = p.resultado { linhas.append(r) }
        }
        linhas.append("tokens: \(e.tokensEntrada ?? 0) entrada (\(e.tokensCache ?? 0) da cache), \(e.tokensSaida ?? 0) saída")
        linhas.append("custo: \(custoChamada) chamada · \(custoAudio.valor) áudio")
        return linhas.joined(separator: "\n")
    }
}

struct Mosaico: View {
    let etiqueta: String
    let valor: String
    let nota: String
    let fundo: Color
    let cor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(etiqueta).font(Letra.mono(10, media: true)).tracking(0.8).foregroundStyle(cor)
            Text(valor).font(Letra.titulo(24)).foregroundStyle(cor).lineLimit(1).minimumScaleFactor(0.6)
            Text(nota).font(Letra.mono(11)).foregroundStyle(P.corpo).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(fundo, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct LinhaPasso: View {
    let passo: Passo

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(passo.inicio.formatted(.dateTime.hour().minute().second()))
                .font(Letra.mono(11))
                .foregroundStyle(P.suave)
                .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(passo.nomeLegivel)
                    .font(Letra.ui(15, .bold))
                if !passo.argumentoPrincipal.isEmpty {
                    Text(passo.argumentoPrincipal)
                        .font(Letra.mono(11))
                        .foregroundStyle(P.corpo)
                }
                if let r = passo.resultado, !r.isEmpty {
                    Text(String(r.prefix(400)))
                        .font(Letra.mono(11))
                        .foregroundStyle(P.suave)
                        .lineLimit(6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Traco(cor: P.linhaFina) }
    }
}

struct Dado: View {
    let titulo: String
    let valor: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo)
                .font(Letra.mono(10, media: true))
                .tracking(0.8)
                .foregroundStyle(P.suave)
            Text(valor)
                .font(Letra.ui(14, .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
