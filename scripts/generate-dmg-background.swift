#!/usr/bin/env swift
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "dist/dmg-background.png"
let size = NSSize(width: 800, height: 480)
let image = NSImage(size: size)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

image.lockFocus()

color(248, 250, 252).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

let topWash = NSGradient(colors: [
    color(255, 255, 255, 1),
    color(239, 246, 255, 0.52)
])
topWash?.draw(in: NSRect(x: 0, y: 250, width: 800, height: 230), angle: 90)

let bottomWave = NSBezierPath()
bottomWave.move(to: NSPoint(x: 0, y: 0))
bottomWave.line(to: NSPoint(x: 0, y: 94))
bottomWave.curve(
    to: NSPoint(x: 800, y: 112),
    controlPoint1: NSPoint(x: 180, y: 18),
    controlPoint2: NSPoint(x: 540, y: 172)
)
bottomWave.line(to: NSPoint(x: 800, y: 0))
bottomWave.close()
color(226, 232, 240, 0.42).setFill()
bottomWave.fill()

let bottomWaveAccent = NSBezierPath()
bottomWaveAccent.move(to: NSPoint(x: 0, y: 0))
bottomWaveAccent.line(to: NSPoint(x: 0, y: 72))
bottomWaveAccent.curve(
    to: NSPoint(x: 800, y: 70),
    controlPoint1: NSPoint(x: 220, y: 130),
    controlPoint2: NSPoint(x: 530, y: 12)
)
bottomWaveAccent.line(to: NSPoint(x: 800, y: 0))
bottomWaveAccent.close()
color(219, 234, 254, 0.52).setFill()
bottomWaveAccent.fill()

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: color(15, 23, 42),
    .paragraphStyle: titleStyle
]
"RemoteCode".draw(in: NSRect(x: 0, y: 390, width: 800, height: 32), withAttributes: titleAttrs)

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: color(71, 85, 105),
    .paragraphStyle: titleStyle
]
"Drag to Applications".draw(in: NSRect(x: 0, y: 368, width: 800, height: 22), withAttributes: subtitleAttrs)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 341, y: 238))
arrow.curve(to: NSPoint(x: 461, y: 238), controlPoint1: NSPoint(x: 380, y: 270), controlPoint2: NSPoint(x: 422, y: 270))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
color(148, 163, 184, 0.30).setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 461, y: 238))
arrowHead.line(to: NSPoint(x: 436, y: 260))
arrowHead.move(to: NSPoint(x: 461, y: 238))
arrowHead.line(to: NSPoint(x: 436, y: 216))
arrowHead.lineWidth = 7
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
color(148, 163, 184, 0.30).setStroke()
arrowHead.stroke()

let leftHalo = NSBezierPath(ovalIn: NSRect(x: 126, y: 174, width: 180, height: 180))
color(59, 130, 246, 0.06).setFill()
leftHalo.fill()

let rightHalo = NSBezierPath(ovalIn: NSRect(x: 494, y: 174, width: 180, height: 180))
color(14, 165, 233, 0.06).setFill()
rightHalo.fill()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let data = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("failed to render DMG background")
}

try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: URL(fileURLWithPath: output))
