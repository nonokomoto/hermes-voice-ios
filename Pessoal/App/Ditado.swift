import AVFoundation
import Foundation
import Observation
import Speech

/// Ditado em português de Portugal com o reconhecimento de voz do iPhone.
/// Sempre que o aparelho suporta, o áudio é processado no próprio telefone e não sai dele.
@MainActor
@Observable
final class Ditado {
    enum Estado: Equatable {
        case parado
        case aOuvir
        case erro(String)
    }

    private(set) var estado: Estado = .parado
    /// Texto reconhecido nesta gravação (vai mudando enquanto falas).
    private(set) var texto = ""
    /// Nível do som (0…1) para animar o botão.
    private(set) var nivel: Float = 0
    /// Quando começou a gravação atual.
    private(set) var desde: Date?

    @ObservationIgnored private let reconhecedor = SFSpeechRecognizer(locale: Locale(identifier: "pt-PT"))
    @ObservationIgnored private let motor = AVAudioEngine()
    @ObservationIgnored private let destino = DestinoAudio()
    @ObservationIgnored private var tarefa: SFSpeechRecognitionTask?
    @ObservationIgnored private var limite: Task<Void, Never>?
    /// Frases já fechadas nesta gravação; o reconhecedor recomeça do zero depois de uma pausa.
    @ObservationIgnored private var confirmado = ""
    /// Frase que o reconhecedor está a escrever agora.
    @ObservationIgnored private var parcial = ""

    static let duracaoMaxima: Duration = .seconds(90)

    var noTelefone: Bool { reconhecedor?.supportsOnDeviceRecognition ?? false }

    func alternar() async {
        if estado == .aOuvir { parar() } else { await comecar() }
    }

    func comecar() async {
        guard estado != .aOuvir else { return }
        texto = ""
        confirmado = ""
        parcial = ""
        guard await Self.autorizado() else {
            estado = .erro("Sem acesso ao microfone ou ao reconhecimento de voz. Ativa em Definições → Akili.")
            return
        }
        guard let reconhecedor, reconhecedor.isAvailable else {
            estado = .erro("O reconhecimento de voz em português não está disponível agora.")
            return
        }

        Leitor.partilhado.parar()
        do {
            let sessao = AVAudioSession.sharedInstance()
            try sessao.setCategory(.record, mode: .measurement, options: .duckOthers)
            try sessao.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            estado = .erro("Não consegui usar o microfone.")
            return
        }

        novaFrase(reconhecedor)

        let entrada = motor.inputNode
        let formato = entrada.outputFormat(forBus: 0)
        entrada.removeTap(onBus: 0)
        let destino = self.destino
        entrada.installTap(onBus: 0, bufferSize: 1024, format: formato) { @Sendable [weak self] buffer, _ in
            destino.acrescentar(buffer)
            let nivel = Self.nivel(de: buffer)
            Task { @MainActor in self?.nivel = nivel }
        }

        do {
            motor.prepare()
            try motor.start()
            estado = .aOuvir
            desde = .now
        } catch {
            parar()
            estado = .erro("Não consegui começar a gravar.")
            return
        }

        limite = Task { [weak self] in
            try? await Task.sleep(for: Self.duracaoMaxima)
            self?.parar()
        }
    }

    func parar() {
        limite?.cancel()
        if motor.isRunning { motor.stop() }
        motor.inputNode.removeTap(onBus: 0)
        destino.pedido?.endAudio()
        tarefa?.finish()
        destino.pedido = nil
        tarefa = nil
        nivel = 0
        desde = nil
        if estado == .aOuvir { estado = .parado }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func limparErro() {
        if case .erro = estado { estado = .parado }
    }

    // MARK: Interno

    /// Começa (ou recomeça, depois de uma pausa) um pedido de reconhecimento sobre o mesmo microfone.
    private func novaFrase(_ reconhecedor: SFSpeechRecognizer) {
        let pedido = SFSpeechAudioBufferRecognitionRequest()
        pedido.shouldReportPartialResults = true
        pedido.addsPunctuation = true
        if reconhecedor.supportsOnDeviceRecognition { pedido.requiresOnDeviceRecognition = true }
        destino.pedido = pedido

        tarefa = reconhecedor.recognitionTask(with: pedido) { @Sendable [weak self] resultado, erro in
            let dito = resultado?.bestTranscription.formattedString
            let final = resultado?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.destino.pedido === pedido else { return }
                if let dito { self.receber(dito) }
                guard self.estado == .aOuvir else { return }
                if final || erro != nil {
                    // Fim de frase (pausa longa): guarda o que foi dito e continua a ouvir.
                    self.fecharFrase()
                    if let r = self.reconhecedor, r.isAvailable { self.novaFrase(r) } else { self.parar() }
                }
            }
        }
    }

    private func receber(_ dito: String) {
        // Se o reconhecedor recomeçou (o novo texto não continua o anterior), fecha a frase anterior.
        if Self.recomecou(anterior: parcial, novo: dito) { fecharFrase() }
        parcial = dito
        texto = Self.juntar(confirmado, parcial)
    }

    private func fecharFrase() {
        confirmado = Self.juntar(confirmado, parcial)
        parcial = ""
        texto = confirmado
    }

    private static func juntar(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Verdadeiro quando o novo resultado já não é uma revisão do anterior mas uma frase nova.
    private static func recomecou(anterior: String, novo: String) -> Bool {
        let a = palavras(anterior), n = palavras(novo)
        guard a.count >= 2, !n.isEmpty else { return false }
        let mesmoInicio = n.prefix(2) == a.prefix(min(2, n.count))
        return !mesmoInicio && n.count < a.count
    }

    private static func palavras(_ t: String) -> [String] {
        t.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func autorizado() async -> Bool {
        let voz = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard voz == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private nonisolated static func nivel(de buffer: AVAudioPCMBuffer) -> Float {
        guard let canal = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var soma: Float = 0
        for i in 0..<Int(buffer.frameLength) { soma += canal[i] * canal[i] }
        let rms = sqrt(soma / Float(buffer.frameLength))
        return min(1, rms * 12)
    }
}

/// Recebe o áudio do microfone (numa thread de áudio) e entrega-o ao pedido de reconhecimento atual.
private final class DestinoAudio: @unchecked Sendable {
    private let trinco = NSLock()
    private var _pedido: SFSpeechAudioBufferRecognitionRequest?

    var pedido: SFSpeechAudioBufferRecognitionRequest? {
        get { trinco.withLock { _pedido } }
        set { trinco.withLock { _pedido = newValue } }
    }

    func acrescentar(_ buffer: AVAudioPCMBuffer) {
        pedido?.append(buffer)
    }
}
