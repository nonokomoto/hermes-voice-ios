import PhotosUI
import SwiftUI
import UIKit

/// Caixa de escrita: fotos (até 4), ditado e envio. O botão redondo é o microfone com a caixa
/// vazia, Parar enquanto ouve e Enviar quando há texto ou fotos; leva a cor do assunto.
struct Composer: View {
    @Binding var texto: String
    @Binding var fotos: [UIImage]
    let placeholder: String
    var ativo = true
    var cor: Color = P.tinta
    var corTexto: Color = P.sobreTinta
    let enviar: () -> Void

    @State private var itens: [PhotosPickerItem] = []
    @State private var escolher = false
    @State private var camara = false
    @State private var ditado = Ditado()
    @State private var textoAntesDoDitado = ""

    static let maximoFotos = 4

    private var vazio: Bool {
        texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fotos.isEmpty
    }

    private var aOuvir: Bool { ditado.estado == .aOuvir }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .erro(let mensagem) = ditado.estado {
                Button { ditado.limparErro() } label: {
                    Text(mensagem)
                        .font(Letra.ui(13, .medium))
                        .foregroundStyle(P.perigo)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
            if aOuvir { faixaDitado }
            if !fotos.isEmpty { fotosPendentes }

            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button { escolher = true } label: { Label("Fotografias", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { camara = true } label: { Label("Câmara", systemImage: "camera") }
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 46)
                }
                .foregroundStyle(P.corpo)
                .disabled(!ativo || fotos.count >= Self.maximoFotos || aOuvir)
                .accessibilityLabel("Anexar foto")

                TextField(aOuvir ? "A ouvir…" : placeholder, text: $texto, axis: .vertical)
                    .lineLimit(1...6)
                    .font(Letra.ui(16))
                    .foregroundStyle(P.tinta)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(aOuvir ? P.folha : P.papel, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                    .accessibilityLabel("Mensagem")

                botaoPrincipal
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(aOuvir ? P.perigoFundo : P.folha)
        .overlay(alignment: .top) { if !aOuvir { Traco() } }
        .animation(.easeOut(duration: 0.18), value: aOuvir)
        .photosPicker(
            isPresented: $escolher,
            selection: $itens,
            maxSelectionCount: max(1, Self.maximoFotos - fotos.count),
            matching: .images
        )
        .onChange(of: itens) { _, novos in
            guard !novos.isEmpty else { return }
            Task {
                for item in novos {
                    if let dados = try? await item.loadTransferable(type: Data.self), let imagem = UIImage(data: dados) {
                        fotos.append(imagem)
                    }
                }
                itens = []
            }
        }
        .fullScreenCover(isPresented: $camara) {
            Camara { fotos.append($0) }.ignoresSafeArea()
        }
        // O que vais dizendo aparece na caixa, a seguir ao que já lá estava.
        .onChange(of: ditado.texto) { _, dito in
            guard aOuvir || !dito.isEmpty else { return }
            let antes = textoAntesDoDitado.trimmingCharacters(in: .whitespacesAndNewlines)
            texto = antes.isEmpty ? dito : antes + " " + dito
        }
        .onDisappear { ditado.parar() }
    }

    private var faixaDitado: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(P.perigo)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(P.perigo.opacity(0.3), lineWidth: 4).scaleEffect(1.6))
            Text("A ouvir")
                .font(Letra.ui(14, .bold))
                .foregroundStyle(P.perigo)
            TimelineView(.periodic(from: ditado.desde ?? .now, by: 1)) { contexto in
                let s = Int(contexto.date.timeIntervalSince(ditado.desde ?? contexto.date))
                Text(String(format: "%d:%02d", s / 60, s % 60) + (ditado.noTelefone ? " · no iPhone" : " · Apple"))
                    .font(Letra.mono(11))
                    .foregroundStyle(P.perigo)
                    .monospacedDigit()
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in
                    Capsule()
                        .fill(P.perigo)
                        .frame(width: 3, height: 4 + CGFloat(ditado.nivel) * CGFloat([14, 8, 18, 10, 16, 6, 12, 18][i % 8]))
                }
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.12), value: ditado.nivel)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
    }

    private var fotosPendentes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(fotos.enumerated()), id: \.offset) { i, foto in
                    Image(uiImage: foto)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { fotos.remove(at: i) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(P.sobreTinta)
                                    .frame(width: 22, height: 22)
                                    .background(P.tinta, in: Circle())
                                    .overlay(Circle().stroke(P.folha, lineWidth: 2))
                                    .frame(width: 44, height: 44)
                            }
                            .offset(x: 16, y: -16)
                            .accessibilityLabel("Remover foto")
                        }
                }
            }
            .padding(.top, 14)
            .padding(.leading, 4)
            .padding(.trailing, 16)
        }
    }

    @ViewBuilder
    private var botaoPrincipal: some View {
        if aOuvir {
            Button { ditado.parar() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(P.perigo, in: Circle())
            }
            .accessibilityLabel("Parar de ouvir")
        } else if vazio {
            Button {
                textoAntesDoDitado = texto
                Task { await ditado.comecar() }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(corTexto)
                    .frame(width: 46, height: 46)
                    .background(cor, in: Circle())
            }
            .accessibilityLabel("Ditar")
            .disabled(!ativo)
            .opacity(ativo ? 1 : 0.35)
        } else {
            Button(action: enviar) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(corTexto)
                    .frame(width: 46, height: 46)
                    .background(cor, in: Circle())
            }
            .accessibilityLabel("Enviar")
            .disabled(!ativo)
            .opacity(ativo ? 1 : 0.35)
        }
    }
}

/// Câmara do sistema para tirar uma foto e anexá-la.
struct Camara: UIViewControllerRepresentable {
    let aoTirar: (UIImage) -> Void
    @Environment(\.dismiss) private var fechar

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordenador { Coordenador(self) }

    final class Coordenador: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let pai: Camara
        init(_ pai: Camara) { self.pai = pai }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let imagem = info[.originalImage] as? UIImage { pai.aoTirar(imagem) }
            pai.fechar()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            pai.fechar()
        }
    }
}
