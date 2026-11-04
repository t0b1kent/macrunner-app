import SwiftUI

/// ★★★ КОЛЬЦА ДЫШАТ ОТ ЧАСОВ, А НЕ `repeatForever` (02.11.2026). Бесконечная анимация SwiftUI
///   пересчитывает граф видов в нашем процессе на каждом кадре экрана и не знает, что окно в фоне.
///   Теперь фаза колец считается из `TimelineView`: не чаще 30 раз в секунду (вдох длится 2 с —
///   глазу хватает), и расписание на паузе, пока окно не активно или включено «Уменьшить
///   движение». Вид прежний: прозрачность от 0,7/0,5/0,3 до нуля и масштаб до 1,05, плавно туда
///   и обратно, второе и третье кольцо — с опозданием 0,3 и 0,6 с.
struct EmptyLibraryView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var loc = Localization.shared
    let onAdd: () -> Void

    @State private var start = Date()

    /// Где кольцо `ring` в своём вдохе: 0 — покой, 1 — полностью растаяло.
    private func pulse(_ ring: Int, at date: Date) -> Double {
        let t = date.timeIntervalSince(start) - Double(ring) * 0.3
        guard t > 0 else { return 0 }
        let cycle = t.truncatingRemainder(dividingBy: 4)
        let x = cycle < 2 ? cycle / 2 : (4 - cycle) / 2
        return (1 - cos(.pi * x)) / 2
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !appearsActive || reduceMotion)) { context in
                ZStack {
                    ForEach(0..<3) { i in
                        let p = reduceMotion ? 0 : pulse(i, at: context.date)
                        Circle()
                            .stroke(
                                Theme.Palette.separator(scheme),
                                style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                            )
                            .frame(width: CGFloat(160 + i * 60), height: CGFloat(160 + i * 60))
                            .opacity(Double(0.7 - Double(i) * 0.2) * (1 - p))
                            .scaleEffect(1 + 0.05 * p)
                    }
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
                .frame(height: 280)
            }

            VStack(spacing: Theme.Spacing.s) {
                Text(L("Your library is empty"))
                    .font(Theme.Font.title)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                // ★ Обещание «перетащите» теперь держится: приёмник стоит в `HomeView`
                //   (`onDrop`) и ведёт в тот же разбор, что кнопка.
                Text(L("Drop a Windows .exe here, or browse to add one."))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
            }

            // ★ Без своего ⌘N: то же сочетание уже висит на «Добавить игру» в шапке,
            //   а два одинаковых сочетания на экране дают неопределённость, чья сработает.
            Button(L("Add game"), action: onAdd)
                .buttonStyle(.minimalPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { start = Date() }
    }
}
