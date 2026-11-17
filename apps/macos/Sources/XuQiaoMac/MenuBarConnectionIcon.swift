import AppKit

/// 将状态写进模板图的 alpha，避免 MenuBarExtra 忽略 SwiftUI opacity；按钮保持可点击。
enum MenuBarConnectionIcon {
    private static let connectedImage = make(alpha: 1)
    private static let disconnectedImage = make(alpha: 0.4)

    static func image(connected: Bool) -> NSImage {
        connected ? connectedImage : disconnectedImage
    }

    private static func make(alpha: CGFloat) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let symbolBounds = NSSize(width: 22, height: 16)
        guard let symbol = NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "续桥")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)),
              let context = CGContext(data: nil, width: 48, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(size: size)
        }
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // 图形比画布再留一圈空隙，与邻近菜单栏图标保持轻巧比例；点击区域仍由系统管理。
        let scale = min(1, symbolBounds.width / symbol.size.width, symbolBounds.height / symbol.size.height)
        let fitted = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let target = NSRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                            width: fitted.width, height: fitted.height)
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha)
        NSGraphicsContext.restoreGraphicsState()
        guard let pixels = context.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: pixels, size: size)
        image.isTemplate = true
        return image
    }
}
