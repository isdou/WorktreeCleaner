#!/usr/bin/env swift
import AppKit
import Foundation

// 生成 1024x1024 极简纯黑底银白双层立体 WorktreeCleaner AppIcon
// 风格：深炭黑渐变 Squircle 底座 + 纯白主干与暗银灰分叉的立体前后叠压
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output_png_path>\n", stderr)
    exit(1)
}
let outPath = CommandLine.arguments[1]
let px: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(px),
    pixelsHigh: Int(px),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let fullRect = NSRect(x: 0, y: 0, width: px, height: px)
let inset: CGFloat = 100
let cardRect = fullRect.insetBy(dx: inset, dy: inset)
let corner: CGFloat = 186

// MARK: - 1. 深炭黑 -> 纯黑渐变底座
let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: corner, yRadius: corner)

cg.saveGState()
let outerShadow = NSShadow()
outerShadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
outerShadow.shadowOffset = NSSize(width: 0, height: -14)
outerShadow.shadowBlurRadius = 28
outerShadow.set()
NSColor.black.setFill()
cardPath.fill()
cg.restoreGState()

cg.saveGState()
cardPath.addClip()

let bgGrad = NSGradient(colorsAndLocations:
    (NSColor(calibratedWhite: 0.175, alpha: 1.0), 0.0),
    (NSColor(calibratedWhite: 0.090, alpha: 1.0), 0.48),
    (NSColor(calibratedWhite: 0.028, alpha: 1.0), 1.0)
)!
bgGrad.draw(in: cardRect, angle: -90)

// 顶部柔和微光漫反射
let topLight = NSGradient(
    starting: NSColor.white.withAlphaComponent(0.08),
    ending: NSColor.white.withAlphaComponent(0.0)
)!
topLight.draw(
    fromCenter: NSPoint(x: px * 0.5, y: cardRect.maxY + 40),
    radius: 20,
    toCenter: NSPoint(x: px * 0.5, y: cardRect.maxY - 120),
    radius: 520,
    options: []
)
cg.restoreGState()

// 细腻玻璃内边缘高光
cg.saveGState()
cardPath.addClip()
let rimPath = NSBezierPath(roundedRect: cardRect.insetBy(dx: 2, dy: 2), xRadius: corner - 2, yRadius: corner - 2)
NSColor.white.withAlphaComponent(0.14).setStroke()
rimPath.lineWidth = 4
rimPath.stroke()
cg.restoreGState()

// MARK: - 2. 通用立体渐变形状绘制工具
func fillShadedPath(
    _ cgPath: CGPath,
    topColor: NSColor,
    bottomColor: NSColor,
    rimAlpha: CGFloat,
    castShadow: Bool
) {
    if castShadow {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.82).cgColor)
        cg.addPath(cgPath)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    cg.saveGState()
    cg.addPath(cgPath)
    cg.clip()

    let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
    let bbox = cgPath.boundingBox
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: bbox.midX, y: bbox.maxY),
        end: CGPoint(x: bbox.midX, y: bbox.minY),
        options: []
    )
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(cgPath)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(rimAlpha).cgColor)
    cg.setLineWidth(2.5)
    cg.strokePath()
    cg.restoreGState()
}

// MARK: - 3. 原创立体双层 Git Worktree 几何徽章
let strokeW: CGFloat = 86

// 后层 A：暗银灰分叉 S 曲线
let branchRaw = CGMutablePath()
branchRaw.move(to: CGPoint(x: 374, y: 360))
branchRaw.addCurve(
    to: CGPoint(x: 650, y: 632),
    control1: CGPoint(x: 374, y: 530),
    control2: CGPoint(x: 650, y: 458)
)
let branchShape = branchRaw.copy(strokingWithWidth: strokeW, lineCap: .round, lineJoin: .round, miterLimit: 4)
fillShadedPath(
    branchShape,
    topColor: NSColor(calibratedWhite: 0.48, alpha: 1.0),
    bottomColor: NSColor(calibratedWhite: 0.22, alpha: 1.0),
    rimAlpha: 0.18,
    castShadow: false
)

// 前层 B：左侧垂直主干
let trunkRaw = CGMutablePath()
trunkRaw.move(to: CGPoint(x: 374, y: 320))
trunkRaw.addLine(to: CGPoint(x: 374, y: 704))
let trunkShape = trunkRaw.copy(strokingWithWidth: strokeW, lineCap: .round, lineJoin: .round, miterLimit: 4)
fillShadedPath(
    trunkShape,
    topColor: NSColor(calibratedWhite: 1.0, alpha: 1.0),
    bottomColor: NSColor(calibratedWhite: 0.78, alpha: 1.0),
    rimAlpha: 0.38,
    castShadow: true
)

// 前层 C：右上角分支节点
let nodeR: CGFloat = 68
let nodeCenter = CGPoint(x: 650, y: 650)
let nodeShape = CGPath(
    ellipseIn: CGRect(x: nodeCenter.x - nodeR, y: nodeCenter.y - nodeR, width: nodeR * 2, height: nodeR * 2),
    transform: nil
)
fillShadedPath(
    nodeShape,
    topColor: NSColor(calibratedWhite: 1.0, alpha: 1.0),
    bottomColor: NSColor(calibratedWhite: 0.80, alpha: 1.0),
    rimAlpha: 0.40,
    castShadow: true
)

// 节点内部极简暗色圆孔
let holeR: CGFloat = 24
let holeShape = CGPath(
    ellipseIn: CGRect(x: nodeCenter.x - holeR, y: nodeCenter.y - holeR, width: holeR * 2, height: holeR * 2),
    transform: nil
)
cg.saveGState()
cg.addPath(holeShape)
cg.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
cg.fillPath()
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outPath))
