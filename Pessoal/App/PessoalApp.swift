import SwiftUI
import UIKit
import UserNotifications

@main
struct PessoalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var fase
    @State private var store = Store.partilhado

    var body: some Scene {
        WindowGroup {
            AssuntosView()
                .environment(store)
                .tint(P.acento)
        }
        .onChange(of: fase) { _, nova in
            if nova == .active {
                store.retomar()
            } else {
                store.pausarAcompanhamento()   // segundo plano ou ecrã bloqueado: para de falar com o ProDesk
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notificacoes.registarCategorias()
        _ = Store.partilhado   // liga a vigia antes de chegarem eventos da sessão em segundo plano
        UNUserNotificationCenter.current().getNotificationSettings { definicoes in
            guard definicoes.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in Store.partilhado.registarDispositivo(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(false, forKey: "pushAtivo")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == VigiaRuns.identificador else { return completionHandler() }
        VigiaRuns.partilhado.concluirEventos = completionHandler
        _ = Store.partilhado
    }

    // Tocar num aviso abre o assunto.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let acao = response.actionIdentifier
        if [Notificacoes.permitir, Notificacoes.sempre, Notificacoes.recusar].contains(acao),
           let run = info["run"] as? String, let pedido = info["pedido"] as? String {
            let escolha = acao == Notificacoes.recusar ? "deny" : (acao == Notificacoes.sempre ? "session" : "once")
            let padroes = info["padroes"] as? [String] ?? []
            Task { @MainActor in
                await Store.partilhado.responderPorAviso(run: run, pedido: pedido, escolha: escolha, padroes: padroes)
                completionHandler()
            }
            return
        }
        if let id = info["assunto"] as? String {
            Task { @MainActor in Store.partilhado.abrirAssunto = id }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Com a app aberta, o cartão de aprovação e a resposta já aparecem no ecrã.
        completionHandler([])
    }
}
