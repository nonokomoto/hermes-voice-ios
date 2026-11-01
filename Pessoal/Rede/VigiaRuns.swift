import Foundation

/// Mantém aberto, numa transferência em segundo plano do iOS, o fluxo de eventos de cada run.
///
/// O servidor só fecha esse fluxo quando o run termina. O sistema continua a transferência com a app
/// suspensa e acorda-a no fim, o que permite avisar com uma notificação local sem servidor de push.
final class VigiaRuns: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let partilhado = VigiaRuns()
    static let identificador = (Bundle.main.bundleIdentifier ?? "hermes-voice") + ".runs"

    /// Chamado na thread principal com a descrição da tarefa (`assunto|entrada|run`) e o evento final, se houver.
    var aoTerminar: (@MainActor (String, FimDeRun?) -> Void)?
    /// Guardado pelo AppDelegate quando o sistema relança a app por causa desta sessão.
    var concluirEventos: (() -> Void)?

    private lazy var sessao: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identificador)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 120      // o Hermes manda ": keepalive" a cada 10 s
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Recria a sessão ao arrancar, para receber os eventos de transferências iniciadas antes.
    func ativar() { _ = sessao }

    func vigiar(_ pedido: URLRequest, descricao: String) {
        let tarefa = sessao.downloadTask(with: pedido)
        tarefa.taskDescription = descricao
        tarefa.resume()
    }

    func esquecer(descricao: String) {
        sessao.getAllTasks { tarefas in
            tarefas.filter { $0.taskDescription == descricao }.forEach { $0.cancel() }
        }
    }

    // O ficheiro só existe durante esta chamada: tem de ser lido aqui.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let texto = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
        let fim = FimDeRun.ler(texto)
        let descricao = downloadTask.taskDescription ?? ""
        Task { @MainActor in self.aoTerminar?(descricao, fim) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        // Sem ligação a meio: a app confirma o estado do run quando voltar a abrir.
        let descricao = task.taskDescription ?? ""
        Task { @MainActor in self.aoTerminar?(descricao, nil) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.concluirEventos?()
            self.concluirEventos = nil
        }
    }
}
