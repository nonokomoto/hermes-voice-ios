import AVFoundation
import Foundation
import Observation

/// Toca a parte falada das respostas. Vai buscar o áudio ao serviço /voz do ProDesk e guarda-o
/// em cache; se o ProDesk não responder, usa a voz pt-PT do próprio iPhone.
@MainActor
@Observable
final class Leitor: NSObject {
    static let partilhado = Leitor()

    enum Estado: Equatable {
        case parado
        case aPreparar
        case aTocar
        case emPausa
    }

    private(set) var entrada: UUID?
    private(set) var estado: Estado = .parado
    private(set) var progresso: Double = 0
    private(set) var duracao: TimeInterval = 0
    /// Velocidade da voz (1×, 1,25×, 1,5×), guardada entre sessões.
    private(set) var velocidade: Float = {
        let v = UserDefaults.standard.float(forKey: "velocidadeVoz")
        return v > 0 ? v : 1
    }()

    static let velocidades: [Float] = [1, 1.25, 1.5]

    func mudarVelocidade(_ v: Float? = nil) {
        let seguinte = v ?? Self.velocidades[((Self.velocidades.firstIndex(of: velocidade) ?? 0) + 1) % Self.velocidades.count]
        velocidade = seguinte
        UserDefaults.standard.set(seguinte, forKey: "velocidadeVoz")
        player?.rate = seguinte
    }

    static func texto(_ v: Float) -> String {
        v == 1 ? "1×" : String(format: "%g×", v).replacingOccurrences(of: ".", with: ",")
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let sintetizador = AVSpeechSynthesizer()
    @ObservationIgnored private var relogio: Task<Void, Never>?
    @ObservationIgnored private var carregamento: Task<Void, Never>?

    private override init() {
        super.init()
        sintetizador.delegate = self
    }

    func estado(de id: UUID) -> Estado { entrada == id ? estado : .parado }

    func alternar(_ id: UUID, fala: String, obterAudio: @escaping () async throws -> Data) {
        if entrada == id {
            switch estado {
            case .aTocar: return pausar()
            case .emPausa: return continuar()
            case .aPreparar: return parar()
            case .parado: break
            }
        }
        tocar(id, fala: fala, obterAudio: obterAudio)
    }

    func tocar(_ id: UUID, fala: String, obterAudio: @escaping () async throws -> Data) {
        parar()
        guard !fala.isEmpty else { return }
        entrada = id
        estado = .aPreparar
        ativarSessao()

        let ficheiro = Self.pastaCache.appending(path: "\(id.uuidString).mp3")
        carregamento = Task { [weak self] in
            var dados = try? Data(contentsOf: ficheiro)
            if dados == nil {
                dados = try? await obterAudio()
                if let dados { try? dados.write(to: ficheiro, options: .atomic) }
            }
            guard let self, !Task.isCancelled, self.entrada == id else { return }
            if let dados, let p = try? AVAudioPlayer(data: dados) {
                p.delegate = self
                p.enableRate = true
                p.rate = self.velocidade
                self.player = p
                self.duracao = p.duration
                p.play()
                self.estado = .aTocar
                self.seguirProgresso()
            } else {
                self.falarNoTelefone(fala)
            }
        }
    }

    func pausar() {
        if let player {
            player.pause()
        } else {
            sintetizador.pauseSpeaking(at: .word)
        }
        estado = .emPausa
    }

    func continuar() {
        if let player {
            player.play()
        } else {
            sintetizador.continueSpeaking()
        }
        estado = .aTocar
    }

    func parar() {
        carregamento?.cancel()
        relogio?.cancel()
        player?.stop()
        player = nil
        if sintetizador.isSpeaking { sintetizador.stopSpeaking(at: .immediate) }
        entrada = nil
        estado = .parado
        progresso = 0
        duracao = 0
    }

    // MARK: Interno

    private func falarNoTelefone(_ fala: String) {
        let frase = AVSpeechUtterance(string: fala)
        frase.voice = AVSpeechSynthesisVoice(language: "pt-PT")
        frase.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.3, velocidade)
        sintetizador.speak(frase)
        estado = .aTocar
        duracao = 0
    }

    private func seguirProgresso() {
        relogio?.cancel()
        relogio = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.player else { return }
                self.progresso = p.duration > 0 ? p.currentTime / p.duration : 0
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func ativarSessao() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private static var pastaCache: URL {
        let pasta = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "voz")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        return pasta
    }
}

extension Leitor: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.parar() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.parar() }
    }
}
