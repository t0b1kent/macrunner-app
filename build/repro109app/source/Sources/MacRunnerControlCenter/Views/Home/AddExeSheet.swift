import AppKit
import SwiftUI

/// Что человек выбрал кнопкой «Добавить игру» — и что с этим делать.
///
/// ★★★ РЕШАЕМ МЫ, НО ПОСЛЕДНЕЕ СЛОВО ЗА ЧЕЛОВЕКОМ.
///   Спрашивать «это установщик или игра?» нельзя: большинство не знает ответа,
///   а мы знаем — внутри `.exe` есть подписи сборщиков, манифест и строки версии.
///   Но угадывание ошибается, поэтому мы показываем ПОЧЕМУ так решили и даём
///   переспорить одним нажатием. Уверенность показываем числом: решение, поданное
///   как безусловное, невозможно оспорить.
///
/// ★★ И отдельно про деинсталлятор. Измерено 12.09.2026: `unins000.exe` собран тем
///   же Inno Setup и несёт В ТЕЛЕ ТУ ЖЕ ПОДПИСЬ, что установщик. По первым весам он
///   уверенно определялся как установщик — то есть мы предложили бы его ЗАПУСТИТЬ,
///   и человек снёс бы себе игру одним нажатием. Поэтому служебные файлы здесь
///   отделены в третий случай и запускать их мы не предлагаем.
struct AddExeSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared

    let url: URL
    let verdict: ExeVerdict
    /// Запустить установщик: он поставит игру, и в библиотеку пойдёт установленное.
    let onInstall: () -> Void
    /// Добавить как есть — сам файл игры.
    let onAddAsGame: () -> Void
    let onCancel: () -> Void
    /// Распаковать установщик Inno Setup без запуска (innoextract) в папку для игр.
    var onUnpack: ((InstallerUnpacker.Probe, URL) -> Void)? = nil

    /// ★ Установщики GOG 32-битные, а 32 бита движок пока не исполняет. Поэтому для установщика мы
    ///   СНАЧАЛА проверяем, можно ли его распаковать, и если да — это главное предложение.
    @State private var probe: InstallerUnpacker.Probe?
    @State private var probing = false
    @State private var baseFolder = InstallerUnpacker.baseFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Palette.separator(scheme))

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                verdictBlock
                reasonsBlock
                actions
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 520)
        .background(Theme.Palette.bgPrimary(scheme))
        .textSelection(.enabled)
        .task(id: url) {
            guard verdict.kind == .installer, onUnpack != nil else { return }
            probing = true
            probe = try? await InstallerUnpacker.probe(url)
            probing = false
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(Theme.Font.heading)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let arch = verdict.architecture {
                    Text(arch)
                        .font(Theme.Font.monoCaption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
            }
            Spacer(minLength: 0)
            Button(L("Cancel"), action: onCancel)
                .buttonStyle(.minimalGhost)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.l)
    }

    private var verdictBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.Font.title)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(subtitle)
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Доводы показываем ВСЕГДА. «Мы решили» без объяснения нечем оспорить,
    /// а ошибаться распознавание будет — оно опирается на признаки, а не на истину.
    @ViewBuilder
    private var reasonsBlock: some View {
        if !verdict.reasons.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: 6) {
                    Text(L("WHY WE THINK SO"))
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.2)
                    Spacer(minLength: 0)
                    Text(String(format: L("certainty %d%%"), Int(verdict.confidence * 100)))
                        .font(Theme.Font.monoCaption)
                }
                .foregroundColor(Theme.Palette.textTertiary(scheme))

                ForEach(verdict.reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 7) {
                        Text("·").foregroundColor(Theme.Palette.textTertiary(scheme))
                        Text(reason)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.Palette.textSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Palette.bgSecondary(scheme)))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch verdict.kind {
        case .installer:
            if let probe, probe.isRepack {
                // ★ Репак: innoextract достанет только оболочку, а разжать архивы рядом могут лишь его
                //   собственные 32-битные программы. Не обещаем того, что не сработает.
                repackCard(probe)
                HStack(spacing: Theme.Spacing.m) {
                    Button(L("Run the installer anyway"), action: onInstall)
                        .buttonStyle(.minimalSecondary)
                }
            } else if let probe, let onUnpack {
                unpackCard(probe)
                HStack(spacing: Theme.Spacing.m) {
                    Button(L("Unpack"), action: { onUnpack(probe, baseFolder) })
                        .buttonStyle(.minimalPrimary)
                        .disabled(notEnoughSpace(probe) != nil)
                    Button(L("Run the installer"), action: onInstall)
                        .buttonStyle(.minimalSecondary)
                    Button(L("No, this is the game itself"), action: onAddAsGame)
                        .buttonStyle(.minimalGhost)
                }
            } else {
                if probing {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(L("Checking whether it can be unpacked without running it…"))
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.Palette.textTertiary(scheme))
                    }
                }
                HStack(spacing: Theme.Spacing.m) {
                    Button(L("Run the installer"), action: onInstall)
                        .buttonStyle(.minimalPrimary)
                    Button(L("No, this is the game itself"), action: onAddAsGame)
                        .buttonStyle(.minimalSecondary)
                }
            }

        case .application:
            HStack(spacing: Theme.Spacing.m) {
                Button(L("Add to library"), action: onAddAsGame)
                    .buttonStyle(.minimalPrimary)
                Button(L("No, this is an installer"), action: onInstall)
                    .buttonStyle(.minimalSecondary)
            }

        case .auxiliary:
            // ★ Запуск НЕ предлагаем даже второй кнопкой: среди служебных файлов
            //   есть деинсталляторы, и предложение «запустить» тут стоит игры.
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Button(L("Add anyway"), action: onAddAsGame)
                    .buttonStyle(.minimalSecondary)
                Text(L("We do not offer to run this one: uninstallers look the same from outside."))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Распаковка

    private func unpackCard(_ probe: InstallerUnpacker.Probe) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: probe.totalBytes, countStyle: .file)
        let target = baseFolder.appendingPathComponent(InstallerUnpacker.folderName(for: probe.title))
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(L("It can be unpacked without running the installer"))
                .font(Theme.Font.bodyEmph)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(String(format: L("%@ · about %@"), probe.title, size))
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "folder")
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                Text((target.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Font.monoCaption)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(L("Change…"), action: chooseFolder)
                    .buttonStyle(.minimalGhost)
            }
            if let warning = notEnoughSpace(probe) {
                Text(warning)
                    .font(Theme.Font.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Palette.bgSecondary(scheme)))
    }

    private func repackCard(_ probe: InstallerUnpacker.Probe) -> some View {
        let shown = probe.repackSigns.prefix(4).joined(separator: ", ")
            + (probe.repackSigns.count > 4 ? " …" : "")
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "archivebox")
                    .foregroundColor(.orange)
                Text(L("This is a repack — not supported yet"))
                    .font(Theme.Font.bodyEmph)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
            }
            Text(L("The game is not inside this installer: it sits next to it in compressed archives, and only the installer's own 32-bit tools can unpack them. MacRunner cannot run 32-bit programs yet, so neither unpacking nor running this installer will work for now."))
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("If you have a regular installer (for example, from GOG) or an already installed game folder, add that instead."))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: L("Found: %@"), shown))
                .font(Theme.Font.monoCaption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Palette.bgSecondary(scheme)))
    }

    /// Места не хватает — текст предупреждения; хватает или неизвестно — nil. Запас 5 %.
    private func notEnoughSpace(_ probe: InstallerUnpacker.Probe) -> String? {
        guard let free = InstallerUnpacker.freeBytes(at: baseFolder) else { return nil }
        let needed = probe.totalBytes + probe.totalBytes / 20
        guard free < needed else { return nil }
        return InstallerUnpacker.Failure.noSpace(needed: needed, free: free).errorDescription
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Where to put unpacked games")
        panel.directoryURL = FileManager.default.fileExists(atPath: baseFolder.path)
            ? baseFolder : baseFolder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        baseFolder = chosen
        InstallerUnpacker.baseFolder = chosen
    }

    // MARK: - Тексты

    private var icon: String {
        switch verdict.kind {
        case .installer: return "shippingbox"
        case .application: return "gamecontroller"
        case .auxiliary: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch verdict.kind {
        case .installer: return L("This looks like an installer")
        case .application: return L("This looks like the game itself")
        case .auxiliary: return L("This looks like a helper file")
        }
    }

    private var subtitle: String {
        switch verdict.kind {
        case .installer:
            return L("We can run it — it will install the game, and the installed game goes to your library.")
        case .application:
            return L("We will add it as is and run it from your library.")
        case .auxiliary:
            return L("Uninstallers, runtimes and crash handlers look like this. Usually not what you want to add.")
        }
    }
}
