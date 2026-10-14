import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Раздел «Лицензия»: что куплено, к какому Mac привязано, как отвязать.
///
/// ★★★ ПРАВИЛО ЭТОГО ЭКРАНА: он показывает СОСТОЯНИЕ, а не обещания. Пока сервера
///   нет, здесь честно написано, что лицензии нет, и показаны тарифы. Ни одной
///   кнопки, которая делает вид, что работает.
struct LicenceView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var store = LicenceStore.shared

    @State private var confirmingUnbind = false
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                switch store.state {
                case .valid(let token), .leaseExpired(let token), .expired(let token):
                    current(token)
                case .wrongDevice(let expected, let actual):
                    problem(title: L("This licence belongs to another Mac"),
                            detail: String(format: L("Issued for %@, this Mac is %@"),
                                           short(expected), short(actual)))
                    tariffs
                case .invalidSignature:
                    problem(title: L("This licence token is not signed by MacRunner."),
                            detail: L("It was changed or came from somewhere else."))
                    tariffs
                case .absent:
                    problem(title: L("No licence on this Mac"),
                            detail: L("MacRunner needs a licence to start a game for the first time. Games you already run keep working."))
                    tariffs
                }

                if let failure {
                    Text(failure)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { store.reload() }
        .confirmationDialog(L("Unbind this Mac from the licence?"),
                            isPresented: $confirmingUnbind, titleVisibility: .visible) {
            Button(L("Unbind"), role: .destructive, action: unbind)
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            // ★ Правило про месяц говорим ДО нажатия, а не после. Человек, узнавший
            //   про ограничение уже потратив попытку, прав в своём возмущении.
            Text(L("The next unbind will only be allowed in one month."))
        }
    }

    // MARK: - Действующая лицензия

    private func current(_ token: LicenceToken) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 4) {
                Text(planTitle(token.plan))
                    .font(Theme.Font.title)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(stateLine(token))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
            }

            block {
                factRow(L("Licence"), token.licenceID)
                factRow(L("This Mac"), short(token.deviceFingerprint))
                factRow(L("Devices"), "\(token.deviceSlots)")
                if let paid = token.paidUntil {
                    factRow(L("Paid until"), date(paid))
                }
            }

            if token.allowsUnbind {
                Button(L("Unbind this Mac")) { confirmingUnbind = true }
                    .buttonStyle(.minimalSecondary)
            } else {
                Text(L("This licence is bound to this Mac permanently and cannot be moved."))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }
        }
    }

    private func stateLine(_ token: LicenceToken) -> String {
        switch store.state {
        case .valid: return L("Active")
        case .leaseExpired:
            return L("Connect to the internet once — the device lease needs renewing")
        case .expired:
            return L("Expired. Installed games keep working; new ones cannot be started.")
        default: return ""
        }
    }

    // MARK: - Нет лицензии

    private func problem(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Font.title)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(detail)
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Тарифы — ровно те, что продаются на странице цен (сверено 15.09.2026):
    /// 2 месяца $2, год $10, бессрочная $100 — по одному Mac; бизнес $50 в год на 10 Mac.
    /// ★ Бессрочный тариф ВЕРНУЛСЯ: запись «убран 12.09.2026» устарела, и экран
    ///   показывал три тарифа из четырёх, а на месте бизнеса — «напишите нам».
    /// Пробного периода нет; есть возврат денег в течение 14 дней — говорим это прямо.
    private var tariffs: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(L("PLANS"))
                .font(.system(size: 10, weight: .bold))
                .kerning(1.2)
                .foregroundColor(Theme.Palette.textTertiary(scheme))

            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                plan(price: "$2", period: L("2 months"), note: L("1 Mac"))
                plan(price: "$10", period: L("1 year"), note: L("1 Mac"))
                plan(price: "$100", period: L("Perpetual"), note: L("1 Mac, one-time, not transferable"))
                plan(price: "$50", period: L("Business"), note: L("10 Macs, per year"))
            }

            Text(L("No free trial. Refund within 14 days."))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))

            activationDoors

            // ★ Через `PurchaseService`, а не прямым адресом: так переменная
            //   `MACRUNNER_PURCHASE_URL` действует и на эту кнопку.
            Button {
                PurchaseService().openLifetimePurchase()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .bold))
                    Text(L("Buy on the site"))
                }
            }
            .buttonStyle(.minimalPrimary)
        }
    }

    /// ★★★ ТРЕТЬЯ ДВЕРЬ — ЕДИНСТВЕННАЯ, ЧТО РАБОТАЕТ БЕЗ СЕРВЕРА.
    ///
    ///   Дверей три (решено 12.09.2026): образ с ключом, ключ руками и файл лицензии.
    ///   Первые две требуют сервера — он проверяет, что ключ не потрачен, привязывает
    ///   его к отпечатку этого Mac и подписывает токен. Ничего из этого на чужой
    ///   машине сделать нельзя.
    ///
    ///   Файл лицензии подписан ЗАРАНЕЕ и проверяется целиком на месте: подпись,
    ///   отпечаток, срок. Поэтому он работает и в закрытом контуре, и там, где нет
    ///   связи, и сегодня — когда сервера ещё нет вовсе.
    private var activationDoors: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(L("Open a licence file"), action: importLicenceFile)
                .buttonStyle(.minimalSecondary)
            Text(L("Works without internet"))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Spacer(minLength: 0)
        }
    }

    /// Читаем файл и ставим токен.
    ///
    /// ★ Проверка идёт ДО сохранения — так устроен `install`. Негодный файл не
    ///   должен вытеснить годную лицензию, которая уже лежит в связке ключей.
    private func importLicenceFile() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a licence file")
        panel.prompt = L("Open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "mrlicence") {
            panel.allowedContentTypes = [type, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try store.install(rawToken: raw)
            store.reload()
            failure = nil
        } catch {
            // ★ Причину показываем дословно. «Не удалось» без причины превращает
            //   разбор в гадание, а причин ровно шесть, и все они названы.
            failure = error.localizedDescription
        }
    }

    private func plan(price: String, period: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(price)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(period)
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
            Text(note)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Palette.bgSecondary(scheme)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .stroke(Theme.Palette.border(scheme), lineWidth: 0.5))
    }

    // MARK: - Мелочи

    private func block<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Palette.bgSecondary(scheme)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Palette.border(scheme), lineWidth: 0.5))
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(Theme.Font.mono)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
            Spacer(minLength: 0)
        }
    }

    /// Отпечаток показываем коротко: целиком он нечитаем и человеку не нужен,
    /// а для разговора с поддержкой первых знаков достаточно.
    private func short(_ fingerprint: String) -> String {
        fingerprint.count > 12 ? String(fingerprint.prefix(12)).uppercased() : fingerprint.uppercased()
    }

    private func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.locale = Locale(identifier: Localization.shared.language.localeCode)
        return f.string(from: d)
    }

    private func planTitle(_ plan: LicenceToken.Plan) -> String {
        switch plan {
        case .trial: return L("Trial")
        case .monthly: return L("2 months")
        case .yearly: return L("1 year")
        case .lifetime: return L("Perpetual")
        case .business: return L("Business")
        }
    }

    private func unbind() {
        do {
            try store.remove()
            store.reload()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
