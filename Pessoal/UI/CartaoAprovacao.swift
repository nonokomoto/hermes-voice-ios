import SwiftUI

/// O agente parou antes de um comando que o Hermes considera perigoso e espera por ti.
struct CartaoAprovacao: View {
    let aprovacao: Aprovacao
    let assunto: Assunto?
    let responder: (String) async throws -> Void

    @State private var aResponder: String?
    @State private var erro: String?

    private var cor: CorAssunto { assunto?.corAssunto ?? .ultramar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Precisa da tua aprovação")
                        .font(Letra.ui(15, .black))
                    Text(aprovacao.motivoLegivel)
                        .font(Letra.ui(13, .bold))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(P.ambarTexto)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(P.ambarFundo)

            VStack(alignment: .leading, spacing: 12) {
                (Text("$ ").foregroundColor(Color(claro: 0xF2B870, escuro: 0xF2B870)) + Text(aprovacao.comando))
                    .font(Letra.mono(12.5))
                    .foregroundStyle(Color(claro: 0xF3F4F1, escuro: 0xF3F4F1))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(P.codigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 8) {
                    Button { decidir("deny") } label: {
                        etiqueta("Recusar", escolha: "deny")
                            .foregroundStyle(P.perigo)
                            .frame(width: 112, height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(P.perigo, lineWidth: 1.5))
                    }
                    Button { decidir("once") } label: {
                        etiqueta("Permitir", escolha: "once")
                            .foregroundStyle(P.sobreTinta)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(P.tinta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .font(Letra.ui(16, .bold))
                .buttonStyle(.plain)
                .disabled(aResponder != nil)

                if aprovacao.opcoes.contains("session") {
                    Button { decidir("session") } label: {
                        etiqueta("Permitir sempre \(assunto.map { "em \($0.titulo)" } ?? "neste assunto")", escolha: "session")
                            .font(Letra.ui(14, .bold))
                            .foregroundStyle(cor.texto)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(cor.fundo, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(aResponder != nil)

                    Text("O ProDesk passa a aprovar sozinho este tipo de comando neste assunto. Podes retirar em Definições.")
                        .font(Letra.mono(10.5))
                        .foregroundStyle(P.suave)
                        .lineSpacing(2)
                }

                if let erro {
                    Text(erro)
                        .font(Letra.ui(13, .medium))
                        .foregroundStyle(P.perigo)
                }
            }
            .padding(14)
        }
        .background(P.folha)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(P.ambarBorda, lineWidth: 1.5))
    }

    @ViewBuilder
    private func etiqueta(_ texto: String, escolha: String) -> some View {
        if aResponder == escolha {
            ProgressView().controlSize(.small)
        } else {
            Text(texto)
        }
    }

    private func decidir(_ escolha: String) {
        aResponder = escolha
        erro = nil
        Task {
            do {
                try await responder(escolha)
            } catch {
                self.erro = "Não consegui responder: \(error.localizedDescription)"
            }
            aResponder = nil
        }
    }
}
