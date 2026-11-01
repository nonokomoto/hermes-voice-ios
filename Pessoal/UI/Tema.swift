import SwiftUI
import UIKit

/// Paleta "Caderno de cor" (design 2.0 aprovado). Cada cor tem versão clara e escura.
enum P {
    static let papel = Color(claro: 0xEEF1EC, escuro: 0x101216)
    static let folha = Color(claro: 0xFFFFFF, escuro: 0x171A1F)
    static let tinta = Color(claro: 0x17181C, escuro: 0xEEF0F2)
    static let corpo = Color(claro: 0x3B3F45, escuro: 0xC9CDD3)
    static let suave = Color(claro: 0x62676E, escuro: 0x9AA0A8)
    static let linha = Color(claro: 0xDFE3DC, escuro: 0x262A31)
    static let linhaFina = Color(claro: 0xE9ECE6, escuro: 0x20242A)
    static let bordaCampo = Color(claro: 0xCFD5CC, escuro: 0x343942)
    static let painel = papel
    /// Texto sobre `tinta` (botões principais escuros no claro, claros no escuro).
    static let sobreTinta = Color(claro: 0xFFFFFF, escuro: 0x101216)

    static let ambar = Color(claro: 0xB45309, escuro: 0xF0A04B)
    static let ambarTexto = Color(claro: 0x8A3F00, escuro: 0xF6C68A)
    static let ambarFundo = Color(claro: 0xFFE9CC, escuro: 0x3A2A14)
    static let ambarBorda = Color(claro: 0xF2B870, escuro: 0x6B4A1E)
    static let perigo = Color(claro: 0xB3261E, escuro: 0xFF8A7A)
    static let perigoFundo = Color(claro: 0xFBE3E0, escuro: 0x3A1D1A)
    static let ok = Color(claro: 0x1E7A4F, escuro: 0x4ADE9B)
    static let codigo = Color(claro: 0x17181C, escuro: 0x0B0C0E)

    // Nomes antigos, usados ainda em alguns sítios.
    static let fundo = folha
    static let acento = CorAssunto.ultramar.texto
    static let aviso = ambarTexto
    static let avisoFundo = ambarFundo
}

/// A cor de separador de cada assunto, como num caderno.
enum CorAssunto: String, CaseIterable, Codable {
    case verde, ultramar, mostarda, ameixa, petroleo, cereja, ardosia

    private var valores: (texto: UInt32, claro: UInt32, marca: UInt32, vivo: UInt32) {
        switch self {
        case .verde: return (0x1E6B52, 0xDDEEE6, 0x1E6B52, 0x5CC39B)
        case .ultramar: return (0x3346C8, 0xE2E6FB, 0x3346C8, 0x98A6FF)
        case .mostarda: return (0x8A5500, 0xFBEACB, 0xA8660A, 0xF2B64A)
        case .ameixa: return (0x7B3F72, 0xF2E2EF, 0x7B3F72, 0xE09AD5)
        case .petroleo: return (0x146B7A, 0xD8ECEF, 0x146B7A, 0x62C6D6)
        case .cereja: return (0xA3244A, 0xF8DFE6, 0xA3244A, 0xFF8FB0)
        case .ardosia: return (0x3F4A5C, 0xE2E6EC, 0x3F4A5C, 0xA9B6CC)
        }
    }

    /// Texto e ícones na cor do assunto.
    var texto: Color { Color(claro: valores.texto, escuro: valores.vivo) }
    /// Fundo tingido (faixa do topo, cápsula da voz).
    var fundo: Color { Color(claro: valores.claro, escuro: 0x1F242B) }
    /// Preenchimento forte (separador, botão de ouvir, barra de progresso).
    var marca: Color { Color(claro: valores.marca, escuro: valores.vivo) }
    /// Texto sobre `marca`.
    var sobreMarca: Color { Color(claro: 0xFFFFFF, escuro: 0x101216) }
    /// Faixa do topo no escuro: a cor cheia; no claro: o tom claro.
    var faixa: Color { Color(claro: valores.claro, escuro: valores.marca) }
    var textoFaixa: Color { Color(claro: 0x17181C, escuro: 0xFFFFFF) }

    /// Cor estável para assuntos antigos, sem cor guardada.
    static func paraID(_ id: String) -> CorAssunto {
        let soma = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return allCases[soma % allCases.count]
    }
}

/// Letras do design 2.0 (todas OFL, dentro da app): Young Serif nos títulos, Literata na voz da
/// Akili, Roboto na interface, IBM Plex Mono nos passos e custos.
enum Letra {
    static func titulo(_ t: CGFloat) -> Font { .custom("YoungSerif-Regular", size: t, relativeTo: .title) }

    static func fala(_ t: CGFloat, media: Bool = false) -> Font {
        .custom(media ? "AkiliLiterata-Medium" : "AkiliLiterata-Regular", size: t, relativeTo: .body)
    }

    static func ui(_ t: CGFloat, _ peso: Font.Weight = .regular) -> Font {
        let nome: String
        switch peso {
        case .black, .heavy: nome = "AkiliRoboto-Black"
        case .bold, .semibold: nome = "AkiliRoboto-Bold"
        case .medium: nome = "AkiliRoboto-Medium"
        default: nome = "AkiliRoboto-Regular"
        }
        return .custom(nome, size: t, relativeTo: .body)
    }

    static func mono(_ t: CGFloat, media: Bool = false) -> Font {
        .custom(media ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size: t, relativeTo: .caption)
    }

    // Compatibilidade com nomes antigos.
    static func serif(_ t: CGFloat) -> Font { fala(t) }
    static func etiqueta() -> Font { mono(11, media: true) }
}

extension Color {
    init(claro: UInt32, escuro: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? escuro : claro)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Date {
    /// "08:05" hoje, "ontem", ou "20 set".
    var formatoCurto: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(.dateTime.hour().minute()) }
        if cal.isDateInYesterday(self) { return "ontem" }
        return formatted(.dateTime.day().month(.abbreviated))
    }

    var hora: String { formatted(.dateTime.hour().minute()) }
}

/// Linha de 1 px no topo ou no fundo de um bloco.
struct Traco: View {
    var cor: Color = P.linha
    var body: some View { Rectangle().fill(cor).frame(height: 1) }
}

/// O separador colorido de um assunto, com a inicial em Young Serif.
struct Separador: View {
    let assunto: Assunto
    var tamanho: CGFloat = 40

    var body: some View {
        let cor = assunto.corAssunto
        Text(String(assunto.titulo.prefix(1)).uppercased())
            .font(Letra.titulo(tamanho * 0.5))
            .foregroundStyle(cor.sobreMarca)
            .frame(width: tamanho, height: tamanho)
            .background(cor.marca, in: RoundedRectangle(cornerRadius: tamanho * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Etiqueta de secção em mono maiúsculo.
struct TituloSeccao: View {
    let texto: String
    var cor: Color = P.suave

    var body: some View {
        Text(texto.uppercased())
            .font(Letra.mono(11, media: true))
            .tracking(1.1)
            .foregroundStyle(cor)
    }
}
