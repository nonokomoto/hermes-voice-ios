import Foundation
import UIKit
import UserNotifications

/// Avisos locais quando uma resposta acaba com a app fora do ecrã.
enum Notificacoes {
    static let categoriaAprovacao = "APROVACAO"
    static let permitir = "PERMITIR"
    static let recusar = "RECUSAR"
    static let sempre = "SEMPRE"

    /// Botões Permitir/Recusar nas notificações de aprovação (pedem o Face ID antes de agir).
    static func registarCategorias() {
        let categoria = UNNotificationCategory(
            identifier: categoriaAprovacao,
            actions: [
                UNNotificationAction(identifier: permitir, title: "Permitir", options: [.authenticationRequired]),
                UNNotificationAction(identifier: sempre, title: "Permitir sempre neste assunto", options: [.authenticationRequired]),
                UNNotificationAction(identifier: recusar, title: "Recusar", options: [.authenticationRequired, .destructive]),
            ],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([categoria])
    }

    static func pedirAutorizacao() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { concedida, _ in
            guard concedida else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func avisar(assunto: Assunto, entrada: Entrada) {
        let conteudo = UNMutableNotificationContent()
        conteudo.title = assunto.titulo
        switch entrada.estado {
        case .falhou:
            conteudo.body = "Não conseguiu acabar: \(entrada.erro ?? "erro desconhecido")"
        case .parado:
            conteudo.body = "Parou a meio."
        default:
            let primeira = entrada.texto.split(separator: "\n").first.map(String.init) ?? "Acabou."
            conteudo.body = String(primeira.prefix(180))
        }
        conteudo.sound = .default
        conteudo.threadIdentifier = assunto.id
        conteudo.userInfo = ["assunto": assunto.id]
        let pedido = UNNotificationRequest(identifier: entrada.id.uuidString, content: conteudo, trigger: nil)
        UNUserNotificationCenter.current().add(pedido)
    }
}
