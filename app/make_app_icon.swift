#!/usr/bin/env swift
// Original vector artwork for Canon LUT 工具. No vendor logos or font assets.
// Rebuild: swift app/make_app_icon.swift app/assets
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor],
              start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let ramp = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(ramp, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2), transform: nil)
}

func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
    CGPoint(x: 512 + cos(angle) * radius, y: 514 + sin(angle) * radius)
}

func drawIcon(_ context: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 184, cornerHeight: 184, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 25, color: color(0x000000, 0.38))
    context.addPath(tile); context.setFillColor(color(0x151B25)); context.fillPath()
    context.restoreGState()
    gradient(context, path: tile, colors: [color(0x354357), color(0x17202D), color(0x10151D)],
             start: CGPoint(x: 195, y: 920), end: CGPoint(x: 850, y: 130))

    // A quiet upper edge gives the tile depth without a glossy, plastic finish.
    context.saveGState()
    context.addPath(tile); context.clip()
    let edge = CGPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820),
                      cornerWidth: 182, cornerHeight: 182, transform: nil)
    context.addPath(edge); context.setStrokeColor(color(0xCBDCF2, 0.16)); context.setLineWidth(3); context.strokePath()
    context.restoreGState()

    let center = CGPoint(x: 512, y: 514)
    let housing = circle(center, 290)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 22, color: color(0x000000, 0.65))
    context.addPath(housing); context.setFillColor(color(0x0B1018)); context.fillPath()
    context.restoreGState()
    gradient(context, path: housing, colors: [color(0x607386), color(0x263443), color(0x111A25)],
             start: CGPoint(x: 320, y: 810), end: CGPoint(x: 740, y: 235))
    context.addPath(circle(center, 278)); context.setStrokeColor(color(0xC9E8FF, 0.14)); context.setLineWidth(2); context.strokePath()
    context.addPath(circle(center, 269)); context.setFillColor(color(0x080D14)); context.fillPath()
    context.addPath(circle(center, 256)); context.setStrokeColor(color(0x3D6079, 0.55)); context.setLineWidth(2); context.strokePath()

    // Six intersecting, curved blades form a color aperture. Their geometry is
    // deliberately broad so the mark remains recognizable at Dock sizes.
    let colors: [(UInt32, UInt32)] = [
        (0xFFD682, 0xEC8B3E), (0xFFAE65, 0xD76543),
        (0x778CF0, 0x4268C8), (0x69C9FA, 0x3284D4),
        (0x79E1E8, 0x32ABBD), (0xB0E9C7, 0x57BEB0)
    ]
    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3 - .pi / 6
        let gap: CGFloat = 0.021
        let path = CGMutablePath()
        path.move(to: point(241, angle + gap))
        path.addArc(center: center, radius: 241, startAngle: angle + gap,
                    endAngle: angle + .pi / 3 - gap, clockwise: false)
        path.addLine(to: point(108, angle + .pi / 3 + 0.47))
        path.addLine(to: point(108, angle + 0.47))
        path.closeSubpath()
        let light = point(268, angle + .pi / 6)
        let dark = point(45, angle + .pi / 6)
        gradient(context, path: path, colors: [color(colors[index].0), color(colors[index].1)],
                 start: light, end: dark)
        context.addPath(path); context.setStrokeColor(color(0xFFFFFF, 0.11)); context.setLineWidth(1.5); context.strokePath()
    }

    // Center glass: dark and calm, with a small cool reflection rather than text.
    let glass = CGMutablePath()
    for index in 0..<6 {
        let p = point(91, CGFloat(index) * .pi / 3 + 0.47 - .pi / 6)
        if index == 0 { glass.move(to: p) } else { glass.addLine(to: p) }
    }
    glass.closeSubpath()
    gradient(context, path: glass, colors: [color(0x1C3B52), color(0x111D2A), color(0x080F18)],
             start: CGPoint(x: 465, y: 603), end: CGPoint(x: 563, y: 430))
    context.addPath(glass); context.setStrokeColor(color(0xB9EFFF, 0.12)); context.setLineWidth(2); context.strokePath()
    let reflection = CGMutablePath()
    reflection.move(to: CGPoint(x: 473, y: 553))
    reflection.addLine(to: CGPoint(x: 512, y: 574))
    reflection.addLine(to: CGPoint(x: 551, y: 553))
    context.addPath(reflection); context.setStrokeColor(color(0x8DCEE7, 0.38)); context.setLineWidth(5)
    context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()

    // Lens alignment dot, offset from the colored mark.
    context.addPath(circle(CGPoint(x: 512, y: 836), 7))
    context.setFillColor(color(0x9CCBDC, 0.8)); context.fillPath()
}

func writePNG(size: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate icon canvas"])
    }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create icon PNG"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AppIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to save icon PNG"])
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "app/assets", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for logicalSize in [16, 32, 128, 256, 512] {
    try writePNG(size: logicalSize, to: iconset.appendingPathComponent("icon_\(logicalSize)x\(logicalSize).png"))
    try writePNG(size: logicalSize * 2, to: iconset.appendingPathComponent("icon_\(logicalSize)x\(logicalSize)@2x.png"))
}
try writePNG(size: 1024, to: output.appendingPathComponent("AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created \(output.appendingPathComponent("AppIcon.icns").path)")
