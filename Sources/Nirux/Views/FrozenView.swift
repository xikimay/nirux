import AppKit
import IOSurface
import Metal
import MetalPerformanceShaders

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

    /// `view` as it shows now, its bounds' size at `scale` (the content's
    /// transform; surfaces copied that small); nil while it has no layer or
    /// no size.
    static func freeze(_ view: NSView, scale: CGFloat = 1) -> FrozenView? {
        guard let root = view.layer, !view.bounds.isEmpty else { return nil }
        var surfaces: [(layer: CALayer, surface: IOSurfaceRef)] = []
        collectSurfaces(in: root, root: root, into: &surfaces)
        let copies = SurfaceCopies.copies(of: surfaces.map(\.surface), scale: scale)
        var images: [ObjectIdentifier: SurfaceCopies.Copy] = [:]
        for (found, copy) in zip(surfaces, copies) {
            if let copy { images[ObjectIdentifier(found.layer)] = copy }
        }
        // Laid out as the view counts y, so its layers' places hold.
        let picture = FrozenView(frame: NSRect(x: 0, y: 0, width: view.bounds.width * scale, height: view.bounds.height * scale))
        picture.countsDown = view.isFlipped
        picture.wantsLayer = true
        let content = picture.content
        content.name = layerName
        content.bounds = root.bounds
        content.position = CGPoint(x: picture.bounds.midX, y: picture.bounds.midY)
        content.transform = CATransform3DMakeScale(scale, scale, 1)
        content.masksToBounds = true
        content.sublayers = root.sublayers?.compactMap { clone($0, root: root, images: images) }
        picture.layer?.addSublayer(content)
        return picture
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shown in `rect`, its content scaled to fit: a picture frozen at its
    /// size shown smaller (depth study P5's zoom).
    func show(in rect: NSRect) {
        frame = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = rect.width / max(content.bounds.width, 1)
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        content.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// Names a picture's frozen layers.
    static let layerName = "FrozenView"

    /// Out of sight: hidden or clear as it shows, clipping to bounds that
    /// lie outside the root's (what it holds can't show either), or an
    /// earlier picture still sliding away (a picture of it would copy its
    /// copies again, doubling them at each switch).
    private static func isOutOfSight(_ layer: CALayer, root: CALayer) -> Bool {
        let shown = shown(layer)
        return layer.delegate is FrozenView || shown.isHidden || shown.opacity == 0
            || (layer.masksToBounds && !layer.convert(layer.bounds, to: root).intersects(root.bounds))
    }

    private static func collectSurfaces(in layer: CALayer, root: CALayer, into surfaces: inout [(layer: CALayer, surface: IOSurfaceRef)]) {
        for sublayer in layer.sublayers ?? [] where !isOutOfSight(sublayer, root: root) {
            if let surface = surface(of: sublayer) { surfaces.append((sublayer, surface)) }
            collectSurfaces(in: sublayer, root: root, into: &surfaces)
        }
    }

    /// What `layer` shows: its presentation while an animation runs on it
    /// (a glide, an arrival), else its model, which holds a change made in
    /// this turn that the presentation doesn't show yet.
    private static func shown(_ layer: CALayer) -> CALayer {
        (layer.animationKeys()?.isEmpty == false ? layer.presentation() : nil) ?? layer
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
    /// glide or an arrival, else as last set), each sharing its contents. A
    /// surface's copy in `images` takes the surface's place, its pixels at
    /// its own scale, on the canvas where the surface isn't opaque: a frost
    /// under it isn't copied.
    static func clone(_ layer: CALayer, root: CALayer, images: [ObjectIdentifier: SurfaceCopies.Copy]) -> CALayer? {
        guard !isOutOfSight(layer, root: root) else { return nil }
        let copy: CALayer, keys: [String]
        switch layer {
        case is CAShapeLayer: (copy, keys) = (CAShapeLayer(), layerKeys + shapeKeys)
        case is CAGradientLayer: (copy, keys) = (CAGradientLayer(), layerKeys + gradientKeys)
        default: (copy, keys) = (CALayer(), layerKeys)
        }
        let shown = shown(layer)
        for key in keys { copy.setValue(shown.value(forKey: key), forKey: key) }
        copy.contents = layer.contents
        if let image = images[ObjectIdentifier(layer)] {
            copy.contents = image.surface
            copy.contentsScale = shown.contentsScale * image.scale
            if !layer.isOpaque { copy.backgroundColor = Theme.Color.canvas.cgColor }
        }
        if let mask = layer.mask { copy.mask = clone(mask, root: mask, images: images) }
        copy.sublayers = layer.sublayers?.compactMap { clone($0, root: root, images: images) }
        return copy
    }
}

/// Copies of IOSurfaces, taken now: on the GPU in one pass (about 3 ms for
/// ten terminals), smaller there if asked, else on the CPU at their size.
/// Ghostty doesn't lock the surface it shows, so a copy may hold a frame it
/// was still drawing.
@MainActor
enum SurfaceCopies {
    /// A copy, and its size against the surface's.
    typealias Copy = (surface: IOSurfaceRef, scale: CGFloat)

    /// How long the main thread waits for the GPU's copies before making
    /// them itself.
    static let gpuWait: DispatchTimeInterval = .milliseconds(30)

    private static let gpu: (device: MTLDevice, queue: MTLCommandQueue)? = {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        return (device, queue)
    }()

    /// In their order, at `scale` where the GPU makes them; nil where one
    /// couldn't be made.
    static func copies(of surfaces: [IOSurfaceRef], scale: CGFloat = 1, waitingAtMost wait: DispatchTimeInterval = gpuWait) -> [Copy?] {
        guard !surfaces.isEmpty else { return [] }
        if let gpu, let copies = gpuCopies(of: surfaces, scale: scale, on: gpu, waitingAtMost: wait) { return copies }
        return surfaces.map { source in blank(like: source).flatMap { cpuCopy(source, into: $0) }.map { ($0, 1) } }
    }

    /// nil past `wait` or on a failure: the GPU's copies, if they come,
    /// land in blanks no one reads.
    private static func gpuCopies(
        of surfaces: [IOSurfaceRef], scale: CGFloat, on gpu: (device: MTLDevice, queue: MTLCommandQueue), waitingAtMost wait: DispatchTimeInterval
    ) -> [Copy?]? {
        let shrinks = scale < 1
        guard !shrinks || MPSSupportsMTLDevice(gpu.device), let buffer = gpu.queue.makeCommandBuffer() else { return nil }
        let blanks = surfaces.map { blank(like: $0, scale: shrinks ? scale : 1) }
        let pairs = zip(surfaces, blanks).map { source, copy in
            copy.flatMap { copy in texture(source, on: gpu.device).flatMap { from in texture(copy, on: gpu.device).map { (from, $0) } } }
        }
        if shrinks {
            let shrink = MPSImageBilinearScale(device: gpu.device)
            for case let (from, to)? in pairs { shrink.encode(commandBuffer: buffer, sourceTexture: from, destinationTexture: to) }
        } else {
            guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
            for case let (from, to)? in pairs { blit.copy(from: from, to: to) }
            blit.endEncoding()
        }
        let done = DispatchSemaphore(value: 0)
        buffer.addCompletedHandler { _ in done.signal() }
        buffer.commit()
        guard done.wait(timeout: .now() + wait) == .success, buffer.status == .completed else { return nil }
        return zip(surfaces, zip(blanks, pairs)).map { source, made in
            if let copy = made.0, made.1 != nil { return (copy, shrinks ? scale : 1) }
            return blank(like: source).flatMap { cpuCopy(source, into: $0) }.map { ($0, 1) }
        }
    }

    /// The same format and colour space, the size at `scale` (its rows
    /// too at 1).
    static func blank(like source: IOSurfaceRef, scale: CGFloat = 1) -> IOSurfaceRef? {
        var properties: [CFString: Any] = [
            kIOSurfaceWidth: max(1, Int((CGFloat(IOSurfaceGetWidth(source)) * scale).rounded())),
            kIOSurfaceHeight: max(1, Int((CGFloat(IOSurfaceGetHeight(source)) * scale).rounded())),
            kIOSurfaceBytesPerElement: IOSurfaceGetBytesPerElement(source), kIOSurfacePixelFormat: IOSurfaceGetPixelFormat(source)
        ]
        if scale == 1 { properties[kIOSurfaceBytesPerRow] = IOSurfaceGetBytesPerRow(source) }
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
        descriptor.usage = [.shaderRead, .shaderWrite]
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
