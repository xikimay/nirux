import AppKit
import IOSurface
import Metal

/// What a view shows, frozen in a few milliseconds for a transition (depth
/// study P4): a clone of its layers, each sharing its contents, minus what
/// is hidden or clipped out of sight. A layer showing an IOSurface (a
/// terminal: Ghostty draws its next frame over the one it shows) shows a
/// copy instead. Drawing the view again (`cacheDisplay`) took about 90 ms
/// in a large window and left the terminals blank. Takes no click.
final class FrozenView: NSView {
    /// `view` as it shows now, the size of its bounds; nil while it has no
    /// layer or no size.
    static func freeze(_ view: NSView) -> FrozenView? {
        guard let root = view.layer, !view.bounds.isEmpty else { return nil }
        var surfaces: [(layer: CALayer, surface: IOSurfaceRef)] = []
        collectSurfaces(in: root, root: root, into: &surfaces)
        let copies = SurfaceCopies.copies(of: surfaces.map(\.surface))
        var images: [ObjectIdentifier: IOSurfaceRef] = [:]
        for (found, copy) in zip(surfaces, copies) {
            if let copy { images[ObjectIdentifier(found.layer)] = copy }
        }
        let frozen = CALayer()
        frozen.bounds = root.bounds
        frozen.masksToBounds = true
        frozen.isGeometryFlipped = root.isGeometryFlipped
        frozen.sublayers = root.sublayers?.compactMap { clone($0, root: root, images: images) }
        let host = FrozenView(frame: view.bounds)
        host.layer = frozen
        host.wantsLayer = true
        return host
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Out of sight: hidden, or clipping to bounds that lie outside the
    /// root's (what it holds can't show either).
    private static func isOutOfSight(_ layer: CALayer, root: CALayer) -> Bool {
        layer.isHidden || (layer.masksToBounds && !layer.convert(layer.bounds, to: root).intersects(root.bounds))
    }

    private static func collectSurfaces(in layer: CALayer, root: CALayer, into surfaces: inout [(layer: CALayer, surface: IOSurfaceRef)]) {
        for sublayer in layer.sublayers ?? [] where !isOutOfSight(sublayer, root: root) {
            if let surface = surface(of: sublayer) { surfaces.append((sublayer, surface)) }
            collectSurfaces(in: sublayer, root: root, into: &surfaces)
        }
    }

    static func surface(of layer: CALayer) -> IOSurfaceRef? {
        guard let contents = layer.contents, CFGetTypeID(contents as AnyObject) == IOSurfaceGetTypeID() else { return nil }
        return unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
    }

    /// `layer` and what it holds in sight, each sharing its contents, a
    /// surface's copy in `images` in place of the surface.
    static func clone(_ layer: CALayer, root: CALayer, images: [ObjectIdentifier: IOSurfaceRef]) -> CALayer? {
        guard !isOutOfSight(layer, root: root) else { return nil }
        let copy: CALayer
        if let shape = layer as? CAShapeLayer {
            let made = CAShapeLayer()
            made.path = shape.path
            made.fillColor = shape.fillColor
            made.fillRule = shape.fillRule
            made.strokeColor = shape.strokeColor
            made.lineWidth = shape.lineWidth
            copy = made
        } else if let gradient = layer as? CAGradientLayer {
            let made = CAGradientLayer()
            made.colors = gradient.colors
            made.locations = gradient.locations
            made.startPoint = gradient.startPoint
            made.endPoint = gradient.endPoint
            made.type = gradient.type
            copy = made
        } else {
            copy = CALayer()
        }
        copy.bounds = layer.bounds
        copy.anchorPoint = layer.anchorPoint
        copy.position = layer.position
        copy.transform = layer.transform
        copy.sublayerTransform = layer.sublayerTransform
        copy.zPosition = layer.zPosition
        copy.opacity = layer.opacity
        copy.isGeometryFlipped = layer.isGeometryFlipped
        copy.isOpaque = layer.isOpaque
        copy.backgroundColor = layer.backgroundColor
        copy.cornerRadius = layer.cornerRadius
        copy.cornerCurve = layer.cornerCurve
        copy.maskedCorners = layer.maskedCorners
        copy.masksToBounds = layer.masksToBounds
        copy.borderWidth = layer.borderWidth
        copy.borderColor = layer.borderColor
        copy.shadowOpacity = layer.shadowOpacity
        copy.shadowRadius = layer.shadowRadius
        copy.shadowOffset = layer.shadowOffset
        copy.shadowColor = layer.shadowColor
        copy.shadowPath = layer.shadowPath
        copy.contents = images[ObjectIdentifier(layer)] ?? layer.contents
        copy.contentsScale = layer.contentsScale
        copy.contentsGravity = layer.contentsGravity
        copy.contentsRect = layer.contentsRect
        copy.contentsCenter = layer.contentsCenter
        if let mask = layer.mask { copy.mask = clone(mask, root: mask, images: images) }
        copy.sublayers = layer.sublayers?.compactMap { clone($0, root: root, images: images) }
        return copy
    }
}

/// Copies of IOSurfaces, taken now and waited for: on the GPU in one pass
/// (about 3 ms for ten terminals), else on the CPU.
@MainActor
enum SurfaceCopies {
    private static let gpu: (device: MTLDevice, queue: MTLCommandQueue)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return (device, queue)
    }()

    /// In their order; nil where one couldn't be made.
    static func copies(of surfaces: [IOSurfaceRef]) -> [IOSurfaceRef?] {
        guard !surfaces.isEmpty else { return [] }
        let blanks = surfaces.map(blank(like:))
        if let gpu, let buffer = gpu.queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            var copied = Array(repeating: false, count: surfaces.count)
            for (index, (source, copy)) in zip(surfaces, blanks).enumerated() {
                guard let copy, let from = texture(source, on: gpu.device), let to = texture(copy, on: gpu.device) else { continue }
                blit.copy(from: from, to: to)
                copied[index] = true
            }
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            return zip(surfaces, zip(blanks, copied)).map { source, made in
                made.1 ? made.0 : made.0.flatMap { cpuCopy(source, into: $0) }
            }
        }
        return zip(surfaces, blanks).map { source, copy in copy.flatMap { cpuCopy(source, into: $0) } }
    }

    /// The same size, format, rows and colour space.
    static func blank(like source: IOSurfaceRef) -> IOSurfaceRef? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: IOSurfaceGetWidth(source), kIOSurfaceHeight: IOSurfaceGetHeight(source),
            kIOSurfaceBytesPerElement: IOSurfaceGetBytesPerElement(source), kIOSurfaceBytesPerRow: IOSurfaceGetBytesPerRow(source),
            kIOSurfacePixelFormat: IOSurfaceGetPixelFormat(source)
        ]
        guard let copy = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        if let space = IOSurfaceCopyValue(source, kIOSurfaceColorSpace) { IOSurfaceSetValue(copy, kIOSurfaceColorSpace, space) }
        return copy
    }

    private static func texture(_ surface: IOSurfaceRef, on device: MTLDevice) -> MTLTexture? {
        guard let format = pixelFormat(IOSurfaceGetPixelFormat(surface)) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), mipmapped: false
        )
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    /// The formats a blit copies as they are: Ghostty's is BGRA.
    private static func pixelFormat(_ code: OSType) -> MTLPixelFormat? {
        switch code {
        case 0x4247_5241: .bgra8Unorm // 'BGRA'
        case 0x5247_4241: .rgba8Unorm // 'RGBA'
        case 0x6C31_3072: .bgr10a2Unorm // 'l10r'
        case 0x5247_6841: .rgba16Float // 'RGhA'
        default: nil
        }
    }

    static func cpuCopy(_ source: IOSurfaceRef, into copy: IOSurfaceRef) -> IOSurfaceRef? {
        guard IOSurfaceLock(source, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(source, .readOnly, nil) }
        guard IOSurfaceLock(copy, [], nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(copy, [], nil) }
        memcpy(IOSurfaceGetBaseAddress(copy), IOSurfaceGetBaseAddress(source), min(IOSurfaceGetAllocSize(source), IOSurfaceGetAllocSize(copy)))
        return copy
    }
}
