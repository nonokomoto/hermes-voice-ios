import Foundation
import UIKit

/// Fotos anexadas aos teus pedidos, guardadas no iPhone para mostrar na conversa e reenviar se preciso.
enum AnexosLocais {
    private static var pasta: URL {
        let p = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "anexos")
        try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }

    static func url(_ nome: String) -> URL { pasta.appending(path: nome) }

    static func guardar(_ dados: Data) -> String? {
        let nome = "\(UUID().uuidString).jpg"
        do {
            try dados.write(to: url(nome), options: .atomic)
            return nome
        } catch {
            return nil
        }
    }

    static func dados(_ nome: String) -> Data? { try? Data(contentsOf: url(nome)) }

    static func imagem(_ nome: String) -> UIImage? { UIImage(contentsOfFile: url(nome).path()) }

    /// Reduz para no máximo 2048 px no lado maior e comprime em JPEG: chega para o agente ler texto
    /// e poupa rede e tokens de visão.
    static func preparar(_ imagem: UIImage, ladoMaximo: CGFloat = 2048) -> Data? {
        let maior = max(imagem.size.width, imagem.size.height)
        let escala = min(1, ladoMaximo / max(maior, 1))
        let tamanho = CGSize(width: (imagem.size.width * escala).rounded(), height: (imagem.size.height * escala).rounded())
        let formato = UIGraphicsImageRendererFormat.default()
        formato.scale = 1
        let reduzida = UIGraphicsImageRenderer(size: tamanho, format: formato).image { _ in
            imagem.draw(in: CGRect(origin: .zero, size: tamanho))
        }
        return reduzida.jpegData(compressionQuality: 0.8)
    }
}
