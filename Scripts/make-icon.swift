#!/usr/bin/env swift
// Draws Orbit's app icon with CoreGraphics and builds Orbit/Resources/AppIcon.icns.
//
// Usage: swift Scripts/make-icon.swift [--output <AppIcon.icns>] [--preview <dir>]
//   --preview also writes the PNGs of every size to <dir> for inspection.
//
// The artwork follows the macOS icon grid: an 824 × 824 continuous-corner
// body on a 1024 × 1024 canvas with a soft drop shadow. Small sizes drop the
// fine details and use a thicker ring so the motif stays readable.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4
let planetCenter = CGPoint(x: 512, y: 500)
let planetRadius: CGFloat = 205
let ringRadii = CGSize(width: 352, height: 104)
let ringTilt: CGFloat = -0.30 // radians, rising to the right
let satelliteAngle: CGFloat = -0.17 * .pi // on the front half, right of the planet

/// A rounded rectangle with continuous (smooth) corners, like the macOS icon shape.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    func topLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.maxY - y * r) }
    func topRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r) }
    func bottomRight(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.maxX - x * r, y: rect.minY + y * r) }
    func bottomLeft(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * r, y: rect.minY + y * r) }

    path.move(to: topLeft(1.52866483, 0))
    path.addLine(to: topRight(1.52866471, 0))
    path.addCurve(to: topRight(0.66993427, 0.06549600), control1: topRight(1.08849323, 0), control2: topRight(0.86840689, 0))
    path.addLine(to: topRight(0.63149399, 0.07491100))
    path.addCurve(to: topRight(0.07491176, 0.63149399), control1: topRight(0.37282392, 0.16905899), control2: topRight(0.16906013, 0.37282401))
    path.addCurve(to: topRight(0, 1.52866483), control1: topRight(0, 0.86840701), control2: topRight(0, 1.08849299))
    path.addLine(to: bottomRight(0, 1.52866471))
    path.addCurve(to: bottomRight(0.06549569, 0.66993493), control1: bottomRight(0, 1.08849323), control2: bottomRight(0, 0.86840689))
    path.addLine(to: bottomRight(0.07491111, 0.63149399))
    path.addCurve(to: bottomRight(0.63149399, 0.07491111), control1: bottomRight(0.16905883, 0.37282392), control2: bottomRight(0.37282392, 0.16905883))
    path.addCurve(to: bottomRight(1.52866471, 0), control1: bottomRight(0.86840689, 0), control2: bottomRight(1.08849323, 0))
    path.addLine(to: bottomLeft(1.52866483, 0))
    path.addCurve(to: bottomLeft(0.66993397, 0.06549569), control1: bottomLeft(1.08849299, 0), control2: bottomLeft(0.86840701, 0))
    path.addLine(to: bottomLeft(0.63149399, 0.07491111))
    path.addCurve(to: bottomLeft(0.07491100, 0.63149399), control1: bottomLeft(0.37282401, 0.16905883), control2: bottomLeft(0.16906001, 0.37282392))
    path.addCurve(to: bottomLeft(0, 1.52866471), control1: bottomLeft(0, 0.86840689), control2: bottomLeft(0, 1.08849323))
    path.addLine(to: topLeft(0, 1.52866483))
    path.addCurve(to: topLeft(0.06549600, 0.66993397), control1: topLeft(0, 1.08849299), control2: topLeft(0, 0.86840701))
    path.addLine(to: topLeft(0.07491100, 0.63149399))
    path.addCurve(to: topLeft(0.63149399, 0.07491100), control1: topLeft(0.16906001, 0.37282401), control2: topLeft(0.37282401, 0.16906001))
    path.addCurve(to: topLeft(1.52866483, 0), control1: topLeft(0.86840701, 0), control2: topLeft(1.08849299, 0))
    path.closeSubpath()
    return path
}

/// A point on the tilted orbit ellipse (angle 0 = right, positive = counterclockwise).
func ringPoint(_ angle: CGFloat) -> CGPoint {
    let x = ringRadii.width * cos(angle)
    let y = ringRadii.height * sin(angle)
    return CGPoint(x: planetCenter.x + x * cos(ringTilt) - y * sin(ringTilt),
                   y: planetCenter.y + x * sin(ringTilt) + y * cos(ringTilt))
}

/// The whole orbit ellipse.
func orbitPath() -> CGPath {
    var transform = CGAffineTransform(translationX: planetCenter.x, y: planetCenter.y).rotated(by: ringTilt)
    return CGPath(ellipseIn: CGRect(x: -ringRadii.width, y: -ringRadii.height,
                                    width: ringRadii.width * 2, height: ringRadii.height * 2), transform: &transform)
}

/// The half-plane in front of the planet (below the orbit's major axis).
func frontHalfPlane() -> CGPath {
    var transform = CGAffineTransform(translationX: planetCenter.x, y: planetCenter.y).rotated(by: ringTilt)
    return CGPath(rect: CGRect(x: -2000, y: -2000, width: 4000, height: 2000), transform: &transform)
}

// MARK: - Colors

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// MARK: - Drawing

struct Detail {
    var size: Int
    var isSmall: Bool { size <= 32 }
    var showsStars: Bool { size >= 128 }
    var ringWidth: CGFloat { size <= 16 ? 78 : size <= 32 ? 60 : size <= 64 ? 42 : size <= 128 ? 32 : 26 }
    var satelliteRadius: CGFloat { size <= 32 ? 64 : size <= 64 ? 50 : 40 }
}

func drawIcon(in context: CGContext, detail: Detail) {
    let shape = continuousRoundedRect(body, radius: cornerRadius)

    // Drop shadow of the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.32))
    context.addPath(shape)
    context.setFillColor(color(0x1E1B4B))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Deep-space background: violet top left to night blue bottom right.
    context.drawLinearGradient(gradient([
        (0, color(0x6C5CE7)), (0.45, color(0x3B2F9E)), (1, color(0x0F1640)),
    ]), start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Soft nebula glow behind the planet.
    context.drawRadialGradient(gradient([(0, color(0x9F8CFF, 0.55)), (1, color(0x9F8CFF, 0))]),
                               startCenter: CGPoint(x: planetCenter.x - 40, y: planetCenter.y + 60), startRadius: 0,
                               endCenter: CGPoint(x: planetCenter.x - 40, y: planetCenter.y + 60), endRadius: 470, options: [])

    if detail.showsStars {
        drawStars(in: context)
    }

    // Orbit behind the planet.
    strokeRing(front: false, in: context, detail: detail)

    // Warm atmosphere around the planet.
    context.drawRadialGradient(gradient([(0, color(0xFFC98A, 0.38)), (1, color(0xFFC98A, 0))]),
                               startCenter: planetCenter, startRadius: planetRadius * 0.96,
                               endCenter: planetCenter, endRadius: planetRadius * 1.22, options: [])

    // Planet with a soft shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x05061A, 0.55))
    context.addEllipse(in: CGRect(x: planetCenter.x - planetRadius, y: planetCenter.y - planetRadius,
                                  width: planetRadius * 2, height: planetRadius * 2))
    context.setFillColor(color(0xF97316))
    context.fillPath()
    context.restoreGState()
    drawPlanet(in: context, detail: detail)

    // Orbit in front of the planet, then the satellite on it.
    strokeRing(front: true, in: context, detail: detail)
    drawSatellite(in: context, detail: detail)

    // Glass highlight across the top.
    context.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.20)), (1, color(0xFFFFFF, 0))]),
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 40), options: [])
    context.restoreGState()

    // Hairline edge.
    context.saveGState()
    context.addPath(shape)
    context.setStrokeColor(color(0xFFFFFF, detail.isSmall ? 0.10 : 0.16))
    context.setLineWidth(detail.isSmall ? 6 : 3)
    context.clip()
    context.addPath(shape)
    context.strokePath()
    context.restoreGState()
}

func drawStars(in context: CGContext) {
    // Deterministic pseudo-random stars, kept away from the planet and ring.
    var seed: UInt64 = 0x0B17_2026
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
    }
    var placed = 0
    while placed < 34 {
        let point = CGPoint(x: body.minX + 40 + random() * (body.width - 80), y: body.minY + 40 + random() * (body.height - 80))
        let radius = 2.2 + random() * 3.6
        let alpha = 0.35 + random() * 0.55
        let dx = point.x - planetCenter.x
        let dy = point.y - planetCenter.y
        guard (dx * dx) / pow(ringRadii.width + 70, 2) + (dy * dy) / pow(planetRadius + 90, 2) > 1 else { continue }
        placed += 1
        context.setFillColor(color(0xFFFFFF, alpha))
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        if radius > 5.2 {
            // A few brighter stars get a small sparkle.
            context.setStrokeColor(color(0xFFFFFF, alpha * 0.6))
            context.setLineWidth(1.6)
            context.strokeLineSegments(between: [
                CGPoint(x: point.x - radius * 2.6, y: point.y), CGPoint(x: point.x + radius * 2.6, y: point.y),
                CGPoint(x: point.x, y: point.y - radius * 2.6), CGPoint(x: point.x, y: point.y + radius * 2.6),
            ])
        }
    }
}

func drawPlanet(in context: CGContext, detail: Detail) {
    let disk = CGRect(x: planetCenter.x - planetRadius, y: planetCenter.y - planetRadius,
                      width: planetRadius * 2, height: planetRadius * 2)
    context.saveGState()
    context.addEllipse(in: disk)
    context.clip()

    // Warm sphere lit from the upper left.
    let light = CGPoint(x: planetCenter.x - planetRadius * 0.38, y: planetCenter.y + planetRadius * 0.42)
    context.drawRadialGradient(gradient([
        (0, color(0xFFE8B0)), (0.28, color(0xFFB85C)), (0.62, color(0xF4743B)), (1, color(0xB63A1B)),
    ]), startCenter: light, startRadius: 0, endCenter: planetCenter, endRadius: planetRadius * 1.08, options: [.drawsAfterEndLocation])

    if !detail.isSmall {
        // Gentle cloud bands, tilted with the orbit.
        context.saveGState()
        context.translateBy(x: planetCenter.x, y: planetCenter.y)
        context.rotate(by: ringTilt)
        for (offset, height, alpha) in [(-120.0, 34.0, 0.16), (-40.0, 22.0, 0.12), (70.0, 30.0, 0.10), (140.0, 18.0, 0.08)] {
            context.setFillColor(color(0x7C2D12, alpha))
            context.fillEllipse(in: CGRect(x: -planetRadius * 1.3, y: offset - height / 2, width: planetRadius * 2.6, height: height))
        }
        context.restoreGState()
    }

    // Night side shading toward the lower right.
    context.drawRadialGradient(gradient([(0, color(0x1A0A3A, 0)), (0.62, color(0x1A0A3A, 0)), (1, color(0x1A0A3A, 0.55))]),
                               startCenter: light, startRadius: 0,
                               endCenter: CGPoint(x: light.x + 30, y: light.y - 30), endRadius: planetRadius * 1.75, options: [])
    context.restoreGState()
}

/// Draws the orbit. The back pass draws the whole ring (the planet then covers
/// its middle); the front pass redraws the near half on top of the planet. Both
/// use the same gradient (dimmer behind, bright in front), so they join seamlessly.
func strokeRing(front: Bool, in context: CGContext, detail: Detail) {
    context.saveGState()
    if front {
        context.addPath(frontHalfPlane())
        context.clip()
    }
    context.addPath(orbitPath())
    context.setLineWidth(detail.ringWidth)
    context.replacePathWithStrokedPath()
    let ring = context.path
    if front, let ring {
        // Cast a soft shadow onto the planet (only there) below the ring.
        context.beginPath()
        context.saveGState()
        context.addEllipse(in: CGRect(x: planetCenter.x - planetRadius, y: planetCenter.y - planetRadius,
                                      width: planetRadius * 2, height: planetRadius * 2))
        context.clip()
        context.addPath(ring)
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 18, color: color(0x1B0B3F, 0.45))
        context.setFillColor(color(0xE0E7FF))
        context.fillPath()
        context.restoreGState()
        context.addPath(ring)
    }
    context.clip()
    context.drawLinearGradient(gradient([
        (0, color(0x8B95F0, 0.70)), (0.42, color(0xC7D0FF, 0.92)), (0.7, color(0xF4F6FF)), (1, color(0xFFFFFF)),
    ]), start: ringPoint(.pi / 2), end: ringPoint(-.pi / 2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawSatellite(in context: CGContext, detail: Detail) {
    let center = ringPoint(satelliteAngle)
    let radius = detail.satelliteRadius
    // Glow.
    context.drawRadialGradient(gradient([(0, color(0x7DD3FC, 0.45)), (1, color(0x7DD3FC, 0))]),
                               startCenter: center, startRadius: radius * 0.9, endCenter: center, endRadius: radius * 2.0, options: [])
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: color(0x0B1033, 0.5))
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.setFillColor(color(0x38BDF8))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.clip()
    let light = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4)
    context.drawRadialGradient(gradient([(0, color(0xFFFFFF)), (0.35, color(0xBAE6FD)), (1, color(0x0284C7))]),
                               startCenter: light, startRadius: 0, endCenter: center, endRadius: radius * 1.1,
                               options: [.drawsAfterEndLocation])
    context.restoreGState()
}

// MARK: - Output

func render(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context, detail: Detail(size: size))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
var output = scriptDirectory.appendingPathComponent("../Orbit/Resources/AppIcon.icns").standardizedFileURL
var previewDirectory: URL?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--output":
        guard let value = arguments.popFirst() else { fatalError("--output needs a path") }
        output = URL(fileURLWithPath: value)
    case "--preview":
        guard let value = arguments.popFirst() else { fatalError("--preview needs a directory") }
        previewDirectory = URL(fileURLWithPath: value, isDirectory: true)
    default:
        FileHandle.standardError.write(Data("usage: swift Scripts/make-icon.swift [--output <AppIcon.icns>] [--preview <dir>]\n".utf8))
        exit(64)
    }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

var rendered: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = rendered[pixels] ?? render(size: pixels)
        rendered[pixels] = image
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(image, to: iconset.appendingPathComponent(name))
    }
}
if let previewDirectory {
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    for (pixels, image) in rendered {
        try writePNG(image, to: previewDirectory.appendingPathComponent("AppIcon-\(pixels).png"))
    }
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
    exit(1)
}
print("✓ \(output.path)")
