#!/usr/bin/env swift
// Значок приложения MacRunner из знака MR (Views/Home/BrandMark.swift).
//
// Запуск из каталога пакета:  swift scripts/make-app-icon.swift
// Итог:                        scripts/assets/AppIcon.icns  (+ AppIcon-1024.png для глаза)
//
// ★★★ КАЖДЫЙ РАЗМЕР РИСУЕТСЯ ЗАНОВО, А НЕ УМЕНЬШАЕТСЯ ИЗ 1024.
//   Уменьшенная копия размывает обводку в 1 пиксель до серой каши, и на 16×16
//   значок теряет край плитки. Поэтому геометрия считается от размера холста,
//   а толщина обводки не бывает тоньше одного настоящего пикселя.
//
// ★ Сетка значков macOS: плитка 824 из 1024, прозрачное поле и мягкая тень под
//   плиткой. Без поля значок в Dock выглядит крупнее соседей и «вылезает» из ряда.
//
// Цвета и пропорции — те же, что у `BrandMark`: скругление 28 % стороны, диагональ
// #171717 → #0A0A0A → #050505, свечение белым 10 %, буквы #F5F5F5, SF Heavy.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = packageRoot.appendingPathComponent("scripts/assets", isDirectory: true)
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("MacRunner-\(ProcessInfo.processInfo.processIdentifier).iconset", isDirectory: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ОТКАЗ: \(message)\n".utf8))
    exit(1)
}

/// Один холст `px × px` пикселей с плиткой по сетке macOS.
func render(px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("не создан холст \(px)×\(px)") }

    let canvas = CGFloat(px)
    let side = canvas * 824.0 / 1024.0
    // Плитку чуть приподнимаем над центром: тень под ней занимает нижнее поле.
    let origin = CGPoint(x: (canvas - side) / 2, y: (canvas - side) / 2 + canvas * 10.0 / 1024.0)
    let tile = CGRect(origin: origin, size: CGSize(width: side, height: side))
    let corner = side * 0.28
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Тень — только у крупных размеров: на 16 и 32 она ложится грязным ореолом.
    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 12.0 / 1024.0),
                      blur: canvas * 28.0 / 1024.0,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(tilePath)
        ctx.setFillColor(CGColor(gray: 0.02, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Диагональ сверху слева вниз направо (в CG ось y смотрит вверх).
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let hex: (Int) -> CGColor = { v in
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    let linear = CGGradient(colorsSpace: space,
                            colors: [hex(0x171717), hex(0x0A0A0A), hex(0x050505)] as CFArray,
                            locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(linear,
                           start: CGPoint(x: tile.minX, y: tile.maxY),
                           end: CGPoint(x: tile.maxX, y: tile.minY),
                           options: [])
    let glow = CGGradient(colorsSpace: space,
                          colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: tile.midX, y: tile.midY), startRadius: 0,
                           endCenter: CGPoint(x: tile.midX, y: tile.midY), endRadius: side * 0.62,
                           options: [])
    ctx.restoreGState()

    // Буквы. Ширина задана рамкой (54 % стороны), как в `BrandMark`: подставится
    // другой шрифт — монограмма ужмётся, а не уедет к краю.
    let fontSize = side * 0.39
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .kern: -side * 0.022,
        .foregroundColor: NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "MR", attributes: attributes))
    var bounds = CTLineGetImageBounds(line, ctx)
    let maxWidth = side * 0.54
    let scale = bounds.width > maxWidth ? maxWidth / bounds.width : 1
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: tile.midY)
    ctx.scaleBy(x: scale, y: scale)
    bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    // Обводка изнутри плитки: светлее общей, как у знака (#BDBDBD, 95 %).
    let stroke = max(1.0, canvas / 256.0)
    let inset = tile.insetBy(dx: stroke / 2, dy: stroke / 2)
    let insetCorner = max(corner - stroke / 2, 0)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: insetCorner, cornerHeight: insetCorner, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 0.74, alpha: 0.95))
    ctx.setLineWidth(stroke)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fail("холст \(px)×\(px) не отдал картинку") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("не открыт \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("не записан \(url.path)") }
}

do {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("каталоги не созданы: \(error.localizedDescription)")
}

// Имена — ровно те, что ждёт iconutil; иначе он молча пропускает размер.
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
var cache: [Int: CGImage] = [:]
for entry in entries {
    let image = cache[entry.px] ?? render(px: entry.px)
    cache[entry.px] = image
    writePNG(image, to: iconset.appendingPathComponent(entry.name))
}
writePNG(cache[1024]!, to: assets.appendingPathComponent("AppIcon-1024.png"))

let output = assets.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
do { try iconutil.run() } catch { fail("iconutil не запустился: \(error.localizedDescription)") }
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fail("iconutil вернул \(iconutil.terminationStatus)") }

let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
guard size > 0 else { fail("\(output.path) пуст") }
print("\(output.path) — \(size) байт")
