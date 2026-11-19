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
    /// The frozen layers, in a layer of their own: AppKit owns the view's.
    let content = CALayer()
    private var countsDown = false
    override var isFlipped: Bool { countsDown }

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
        // Laid out as the view counts y, so its layers' places hold.
        let picture = FrozenView(frame: view.bounds)
        picture.countsDown = view.isFlipped
        picture.wantsLayer = true
        let content = picture.content
        content.name = layerName
        content.frame = CGRect(origin: .zero, size: view.bounds.size)
        content.bounds.origin = root.bounds.origin
        content.masksToBounds = true
        content.sublayers = root.sublayers?.compactMap { clone($0, root: root, images: images) }
        picture.layer?.addSublayer(content)
        return picture
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Names a picture's frozen layers.
    static let layerName = "FrozenView"

    /// Out of sight: hidden or clear as it shows, clipping to bounds that
    /// lie outside the root's (what it holds can't show either), or an
    /// earlier picture still sliding away (a picture of it would copy its
    /// copies again, doubling them at each switch).
    private static func isOutOfSight(_ layer: CALayer, root: CALayer) -> Bool {
        let shown = layer.presentation() ?? layer
        return layer.delegate is FrozenView || shown.isHidden || shown.opacity == 0
            || (layer.masksToBounds && !layer.convert(layer.bounds, to: root).intersects(root.bounds))
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

    /// What a clone takes from its layer: where it lies, how it shows.
    private static let layerKeys = [
        "bounds", "anchorPoint", "position", "transform", "sublayerTransform", "zPosition", "opacity", "geometryFlipped",
        "opaque", "backgroundColor", "cornerRadius", "cornerCurve", "maskedCorners", "masksToBounds", "borderWidth",
        "borderColor", "shadowOpacity", "shadowRadius", "shadowOffset", "shadowColor", "shadowPath", "contentsScale",
        "contentsGravity", "contentsRect", "contentsCenter"
    ]
    private static let shapeKeys = [
        "path", "fillColor", "fillRule", "strokeColor", "lineWidth", "lineCap", "lineJoin", "lineDashPattern", "lineDashPhase",
        "strokeStart", "strokeEnd", "miterLimit"
    ]
    private static let gradientKeys = ["colors", "locations", "startPoint", "endPoint", "type"]

    /// `layer` and what it holds in sight, as they show (mid-way through a
    /// glide or an arrival), each sharing its contents. A surface's copy in
    /// `images` takes the surface's place, on the canvas where the surface
    /// isn't opaque: a frost under it isn't copied.
    static func clone(_ layer: CALayer, root: CALayer, images: [ObjectIdentifier: IOSurfaceRef]) -> CALayer? {
        guard !isOutOfSight(layer, root: root) else { return nil }
        let copy: CALayer, keys: [String]
        switch layer {
        case is CAShapeLayer: (copy, keys) = (CAShapeLayer(), layerKeys + shapeKeys)
        case is CAGradientLayer: (copy, keys) = (CAGradientLayer(), layerKeys + gradientKeys)
        default: (copy, keys) = (CALayer(), layerKeys)
        }
        let shown = layer.presentation() ?? layer
        for key in keys { copy.setValue(shown.value(forKey: key), forKey: key) }
        copy.contents = layer.contents
        if let image = images[ObjectIdentifier(layer)] {
            copy.contents = image
            if !layer.isOpaque { copy.backgroundColor = Theme.Color.canvas.cgColor }
        }
        if let mask = layer.mask { copy.mask = clone(mask, root: mask, images: images) }
        copy.sublayers = layer.sublayers?.compactMap { clone($0, root: root, images: images) }
        return copy
    }
}

/// Copies of IOSurfaces, taken now: on the GPU in one pass (about 3 ms for
/// ten terminals), else on the CPU. Ghostty doesn't lock the surface it
/// shows, so a copy may hold a frame it was still drawing.
@MainActor
enum SurfaceCopies {
    /// How long the main thread waits for the GPU's copies before making
    /// them itself.
    static let gpuWait: DispatchTimeInterval = .milliseconds(30)

    private static let gpu: (device: MTLDevice, queue: MTLCommandQueue)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return (device, queue)
    }()

    /// In their order; nil where one couldn't be made.
    static func copies(of surfaces: [IOSurfaceRef], waitingAtMost wait: DispatchTimeInterval = gpuWait) -> [IOSurfaceRef?] {
        guard !surfaces.isEmpty else { return [] }
        if let gpu, let copies = gpuCopies(of: surfaces, on: gpu, waitingAtMost: wait) { return copies }
        return surfaces.map { source in blank(like: source).flatMap { cpuCopy(source, into: $0) } }
    }

    /// nil past `wait` or on a failure: the GPU's copies, if they come,
    /// land in blanks no one reads.
    private static func gpuCopies(
        of surfaces: [IOSurfaceRef], on gpu: (device: MTLDevice, queue: MTLCommandQueue), waitingAtMost wait: DispatchTimeInterval
    ) -> [IOSurfaceRef?]? {
        guard let buffer = gpu.queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        let blanks = surfaces.map(blank(like:))
        var copied = Array(repeating: false, count: surfaces.count)
        for (index, (source, copy)) in zip(surfaces, blanks).enumerated() {
            guard let copy, let from = texture(source, on: gpu.device), let to = texture(copy, on: gpu.device) else { continue }
            blit.copy(from: from, to: to)
            copied[index] = true
        }
        blit.endEncoding()
        let done = DispatchSemaphore(value: 0)
        buffer.addCompletedHandler { _ in done.signal() }
        buffer.commit()
        guard done.wait(timeout: .now() + wait) == .success, buffer.status == .completed else { return nil }
        return zip(surfaces, zip(blanks, copied)).map { source, made in
            made.1 ? made.0 : made.0.flatMap { cpuCopy(source, into: $0) }
        }
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
