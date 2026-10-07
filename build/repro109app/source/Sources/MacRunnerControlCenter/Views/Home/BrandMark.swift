import SwiftUI

/// Знак MacRunner: монограмма MR на почти чёрной плитке.
///
/// Цвета в интерфейсе нет — вместо него работает свет. Здесь это перламутр:
/// светлая полоса медленно едет поперёк букв.
///
/// ★★★ КАК ИМЕННО СДЕЛАН ПЕРЕЛИВ И ПОЧЕМУ НЕ ИНАЧЕ.
///   Первая попытка красила буквы градиентом через `foregroundStyle` и двигала его
///   точки внутри `withAnimation`. Так НЕ РАБОТАЕТ: заливка (`ShapeStyle`) в SwiftUI
///   не анимируется, значение просто перескакивает в конечное, и знак стоит намертво.
///   Измерено 12.09.2026: три снимка окна с промежутком 2,5 с оказались побайтно
///   одинаковыми.
///   Рабочий способ — двигать не заливку, а ГЕОМЕТРИЮ: полоса света едет `offset`-ом
///   (он анимируется) внутри квадрата знака, а маска по форме букв стоит на месте.
///   Порядок важен: смещение применяется ДО маски, иначе маска поедет вместе с полосой.
///
/// ★ Ширина букв задана рамкой, а не отдана шрифту: подставится другой — и монограмма
///   съедет к краю. Ловилось на макете.
struct BrandMark: View {
    var size: CGFloat = 30

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var corner: CGFloat { size * 0.28 }
    private var bandWidth: CGFloat { size * 0.40 }
    private var travel: CGFloat { size * 0.9 }

    var body: some View {
        ZStack {
            tile
            letters.foregroundStyle(Color(white: 245.0 / 255.0))
            if !reduceMotion { sheen }
            // ★ Обводка у НАШЕГО знака своя и светлее общей. Общее правило серого
            //   контура писалось ради ряда чужих значков внизу меню — чтобы ни один
            //   не пропал на фоне. Этого ряда в витрине игрока больше нет, а знак
            //   MacRunner остался один и должен читаться сам по себе.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.Palette.brandMarkBorder, lineWidth: Theme.Border.glyphTile)
        }
        .frame(width: size, height: size)
        .onAppear(perform: startSweep)
        .accessibilityHidden(true)
    }

    // MARK: - Части

    private var tile: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.09), Color(white: 0.04), Color(white: 0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.62
                        )
                    )
            )
    }

    private var letters: some View {
        Text("MR")
            .font(.system(size: size * 0.39, weight: .heavy, design: .default))
            .kerning(-size * 0.022)
            .frame(width: size * 0.54)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    /// Полоса света внутри квадрата знака, обрезанная по форме букв.
    /// `Color.clear` задаёт систему координат: без неё маска считалась бы
    /// по сдвинутой полосе и ехала бы вместе с ней.
    private var sheen: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0), .white, .white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: bandWidth)
                    .rotationEffect(.degrees(14))
                    .offset(x: phase)
            )
            .mask(letters)
            .allowsHitTesting(false)
    }

    private func startSweep() {
        guard !reduceMotion else { return }
        phase = -travel
        withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
            phase = travel
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        BrandMark(size: 16)
        BrandMark(size: 30)
        BrandMark(size: 64)
    }
    .padding(24)
    .background(Color.black)
}
