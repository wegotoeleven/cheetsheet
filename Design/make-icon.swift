// Draws Cheetsheet's app icon as layers for Apple's .icon format (macOS 26 and later):
// cheetah fur in the background and a ⌘ in front. macOS adds the rounded shape,
// shadow and glass effect itself, so the layers are plain full-size squares.
//
// Usage: swift Design/make-icon.swift Cheetsheet/AppIcon.icon/Assets Design/AppIcon-preview.png
import AppKit

let size: CGFloat = 1024
let centre = CGPoint(x: size / 2, y: size / 2)
let spotColour = NSColor(srgbRed: 0.13, green: 0.08, blue: 0.04, alpha: 1)

/// Small seeded random generator so the spots are the same on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Runs `draw` on a blank, transparent 1024×1024 canvas and returns the result.
func render(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.current = nil
    return rep
}

func save(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// Irregular cheetah spots with a clear area in the middle for the ⌘. With `fur`, they sit
/// on a golden background; without, they're on transparency (used for dark mode).
func drawSpots(_ cg: CGContext, colour: NSColor, fur: Bool) {
    if fur {
        NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.76, blue: 0.36, alpha: 1),
                            NSColor(srgbRed: 0.80, green: 0.50, blue: 0.14, alpha: 1)])!
            .draw(in: CGRect(x: 0, y: 0, width: size, height: size), angle: -90)
    }

    var random = SeededRandom(state: 7)
    let spacing: CGFloat = 118
    for row in -1...10 {
        for column in -1...10 {
            let offset = row.isMultiple(of: 2) ? 0 : spacing / 2
            var point = CGPoint(x: CGFloat(column) * spacing + offset, y: CGFloat(row) * spacing)
            point.x += .random(in: -34...34, using: &random)
            point.y += .random(in: -34...34, using: &random)
            if abs(point.x - centre.x) < 250 && abs(point.y - centre.y) < 250 { continue }
            let spot = CGFloat.random(in: 44...84, using: &random)
            cg.saveGState()
            cg.translateBy(x: point.x, y: point.y)
            cg.rotate(by: .random(in: 0...(.pi), using: &random))
            // Two or three overlapping ovals make an uneven blob rather than a perfect dot.
            let blob = NSBezierPath()
            for _ in 0..<Int.random(in: 2...3, using: &random) {
                let w = spot * .random(in: 0.7...1, using: &random)
                let h = spot * .random(in: 0.55...0.85, using: &random)
                let dx = CGFloat.random(in: -spot * 0.18...spot * 0.18, using: &random)
                let dy = CGFloat.random(in: -spot * 0.12...spot * 0.12, using: &random)
                blob.append(NSBezierPath(ovalIn: CGRect(x: dx - w / 2, y: dy - h / 2, width: w, height: h)))
            }
            colour.withAlphaComponent(colour.alphaComponent * .random(in: 0.88...1, using: &random)).setFill()
            blob.fill()
            cg.restoreGState()
        }
    }
}

/// The ⌘ alone on a transparent canvas. `operation: .destinationOut` erases its shape instead.
func drawCommand(_ cg: CGContext, colour: NSColor = .white, operation: NSCompositingOperation = .sourceOver) {
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
        .applying(.init(paletteColors: [colour]))
    let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: CGRect(x: centre.x - symbol.size.width / 2, y: centre.y - symbol.size.height / 2,
                           width: symbol.size.width, height: symbol.size.height),
                from: .zero, operation: operation, fraction: 1)
}

// One set of layers per look; icon.json picks which show in light, dark and tinted styles.
let assets = CommandLine.arguments[1]
let fur = render { drawSpots($0, colour: spotColour, fur: true) }
let darkSpots = render { drawSpots($0, colour: NSColor(srgbRed: 0.85, green: 0.6, blue: 0.25, alpha: 0.55), fur: false) }
let darkCommand = render { drawCommand($0, colour: spotColour) }  // on the gold fur
let lightCommand = render { drawCommand($0, colour: .white) }     // on dark backgrounds
save(fur, to: "\(assets)/fur.png")
save(darkSpots, to: "\(assets)/spots-dark-mode.png")
save(darkCommand, to: "\(assets)/command-dark.png")
save(lightCommand, to: "\(assets)/command-light.png")

// A flattened light-mode preview with roughly the shape macOS gives it.
if CommandLine.arguments.count > 2 {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let preview = render { _ in
        NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).addClip()
        for layer in [fur, darkCommand] {
            NSImage(size: CGSize(width: size, height: size), flipped: false) { _ in layer.draw(); return true }.draw(in: body)
        }
    }
    save(preview, to: CommandLine.arguments[2])
}
