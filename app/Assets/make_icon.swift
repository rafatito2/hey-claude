// Genera el ícono de Hey Claude (PNG 1024x1024) con AppKit, sin dependencias.
// Uso:  swift make_icon.swift salida.png [--flat]
//   --flat  = sin fondo (solo la marca, para el widget o el README)
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "logo-1024.png"
let flat = args.contains("--flat")

let size: CGFloat = 1024
let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #D97757
let terracottaDark = NSColor(srgbRed: 0.72, green: 0.36, blue: 0.25, alpha: 1)
let cream = NSColor(srgbRed: 0.965, green: 0.945, blue: 0.91, alpha: 1)          // #F6F1E8
let creamDark = NSColor(srgbRed: 0.93, green: 0.89, blue: 0.84, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

// Fondo: cuadrado redondeado de macOS (con margen transparente alrededor)
if !flat {
    let margin = size * 0.1
    let rect = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // sombra suave
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    cream.setFill(); path.fill()
    ctx.restoreGState()
    // degradado crema
    ctx.saveGState()
    path.addClip()
    let gradient = NSGradient(starting: cream, ending: creamDark)!
    gradient.draw(in: rect, angle: -90)
    // brillo sutil arriba
    let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.3))!
    glow.draw(in: rect, angle: 90)
    ctx.restoreGState()
}

// Marca: sol de rayos asimétricos en terracota
let c = CGPoint(x: size * (flat ? 0.5 : 0.46), y: size * (flat ? 0.5 : 0.55))
let r = size * (flat ? 0.42 : 0.27)
let lengths: [CGFloat] = [1.0, 0.66, 0.9, 0.58, 1.0, 0.7, 0.86, 0.6, 0.98, 0.68, 0.9, 0.62]
ctx.saveGState()
ctx.setStrokeColor(terracotta.cgColor)
ctx.setLineCap(.round)
ctx.setLineWidth(r * 0.245)
let inner = r * 0.16
for (i, l) in lengths.enumerated() {
    let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi + 0.2
    ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
    ctx.addLine(to: CGPoint(x: c.x + cos(a) * r * l, y: c.y + sin(a) * r * l))
}
ctx.strokePath()
// centro relleno (sin hueco)
ctx.setFillColor(terracotta.cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - inner * 1.2, y: c.y - inner * 1.2, width: inner * 2.4, height: inner * 2.4))
ctx.restoreGState()

// Detalle de voz: onda de barras redondeadas abajo a la derecha
if !flat {
    let bars: [CGFloat] = [0.35, 0.7, 1.0, 0.55, 0.3]
    let barW = size * 0.028
    let gap = size * 0.02
    let maxH = size * 0.11
    let totalW = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    let x0 = size * 0.60
    let yMid = size * 0.255
    ctx.saveGState()
    ctx.setFillColor(terracottaDark.cgColor)
    for (i, h) in bars.enumerated() {
        let bh = maxH * h
        let rect = CGRect(x: x0 + CGFloat(i) * (barW + gap), y: yMid - bh / 2, width: barW, height: bh)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }
    _ = totalW
    ctx.fillPath()
    ctx.restoreGState()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("Escrito \(outPath)")
