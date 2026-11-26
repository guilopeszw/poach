import AppKit
import CoreVideo
@preconcurrency import MetalKit
import SwiftUI

private struct CaptureGlassBackdropKey: EnvironmentKey {
    static let defaultValue: CaptureGlassBackdrop? = nil
}

extension EnvironmentValues {
    var captureGlassBackdrop: CaptureGlassBackdrop? {
        get { self[CaptureGlassBackdropKey.self] }
        set { self[CaptureGlassBackdropKey.self] = newValue }
    }
}

/// Native Metal equivalent of the HTML demo: convex refraction, separate RGB ray samples,
/// Fresnel highlights and a smooth distance-field union for the neck of the departing drop.
/// The selection's interior is transparent; pixels are drawn only at its rim and on the pill.
struct CaptureLiquidGlass: View {
    let backdrop: CaptureGlassBackdrop
    let area: CGRect?
    var pill: CGRect? = nil
    var connection: CGFloat = 0
    static var isSupported: Bool { CaptureGlassGPU.pipeline != nil }

    var body: some View {
        GeometryReader { geometry in
            CaptureLiquidGlassView(backdrop: backdrop, area: area, pill: pill, connection: connection)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct CaptureLiquidGlassView: NSViewRepresentable {
    let backdrop: CaptureGlassBackdrop
    let area: CGRect?
    let pill: CGRect?
    let connection: CGFloat
    func makeCoordinator() -> CaptureLiquidGlassRenderer { CaptureLiquidGlassRenderer(frames: backdrop.frames) }

    func makeNSView(context: Context) -> MTKView {
        let view = CaptureGlassMetalView(frame: .zero, device: CaptureGlassGPU.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.area = area
        context.coordinator.pill = pill
        context.coordinator.connection = connection

    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: MTKView, coordinator: CaptureLiquidGlassRenderer) {
        view.isPaused = true
        view.delegate = nil
    }
}

private final class CaptureGlassMetalView: MTKView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private enum CaptureGlassGPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Poach glass pipeline: %@", error.localizedDescription)
            return nil
        }
    }()

    // Compiled in memory, so SwiftPM and the packaged app need no external shader resource.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 viewport; float4 area; float4 pill; float4 options; };
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex glassVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
    }
    float roundedBox(float2 p, float4 box, float r) {
        float2 q = abs(p - box.xy) - box.zw + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    float merge(float a, float b, float k) {
        k = max(k, 0.001);
        float h = max(k - abs(a-b), 0.0) / k;
        return min(a,b) - h*h*k*0.25;
    }
    float distanceAt(float2 p, constant Uniforms &u) {
        float a = u.options.z > 0.5 ? roundedBox(p,u.area,u.options.x) : 1e5;
        float b = u.options.w > 0.5 ? roundedBox(p,u.pill,u.pill.w) : 1e5;
        return merge(a,b,u.options.y);
    }
    float3 background(float2 p, texture2d<float> image, constant Uniforms &u) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 color = image.sample(s,p/u.viewport.xy).rgb;
        if(u.options.z > 0.5) {
            float outside = smoothstep(-0.5,0.5,roundedBox(p,u.area,u.options.x));
            color *= 1.0 - outside*0.48;
        }
        return color;
    }
    fragment float4 glassFragment(Vertex v [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> image [[texture(0)]]) {
        float2 p = v.uv*u.viewport.xy;
        float a = u.options.z > 0.5 ? roundedBox(p,u.area,u.options.x) : 1e5;
        float b = u.options.w > 0.5 ? roundedBox(p,u.pill,u.pill.w) : 1e5;
        float d = merge(a,b,u.options.y);
        float shape = 1.0-smoothstep(-0.65,0.65,d);
        float band = min(28.0,min(u.area.z,u.area.w)*0.65);
        float edgeProgress = clamp(max(-a,0.0)/max(band,0.001),0.0,1.0);
        float rimMask = 1.0-edgeProgress*edgeProgress*edgeProgress*
            (edgeProgress*(edgeProgress*6.0-15.0)+10.0);
        float pillMask = 1.0-smoothstep(-1.0,1.0,b);
        float alpha = shape*max(u.options.z > 0.5 ? rimMask : 0.0,pillMask);
        if(alpha < 0.001) return float4(0);
        float2 grad = float2(distanceAt(p+float2(0.5,0),u)-distanceAt(p-float2(0.5,0),u),
                             distanceAt(p+float2(0,0.5),u)-distanceAt(p-float2(0,0.5),u));
        float2 n = grad/max(length(grad),0.0001);
        float pillInfluence = smoothstep(-4.0,4.0,a-b);
        float strength = mix(0.65,1.0,pillInfluence);
        float thickness = mix(max(u.options.x,16.0),max(u.pill.w,1.0),pillInfluence);
        float side = clamp(1.0-max(-d,0.0)/thickness,0.0,1.0);
        float z = sqrt(max(0.0,1.0-side*side));
        float2 offset = -n*(1.0-z)*thickness*1.9*strength;
        float2 split = n*(1.0-z)*thickness*0.22*strength;
        float2 ray = p+offset;
        float3 color = float3(background(ray+split,image,u).r,background(ray,image,u).g,
                              background(ray-split,image,u).b);
        float fresnel = pow(side,5.0);
        float light = dot(n,normalize(float2(-0.6,-0.8)));
        float highlight = exp(-abs(d+0.9)*1.5)*(0.30+0.45*abs(light))*mix(0.45,1.0,pillInfluence);
        color = mix(color,float3(0.90,0.94,1.0),(0.025+fresnel*0.09)*strength);
        color += float3(0.87,0.93,1.0)*exp(-max(-d,0.0)/5.5)*(0.09+0.16*max(light,0.0))*strength;
        color += highlight;
        return float4(color,alpha);
    }
    """
}

/// Holds the IOSurface-backed frame until the GPU has finished reading it.
private final class CaptureGlassGPUFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let image: CVMetalTexture
    init(buffer: CVPixelBuffer, image: CVMetalTexture) { self.buffer = buffer; self.image = image }
}

@MainActor
final class CaptureLiquidGlassRenderer: NSObject, MTKViewDelegate {
    let frames: CaptureGlassFrames
    var area: CGRect?
    var pill: CGRect?
    var connection: CGFloat = 0
    private var textureCache: CVMetalTextureCache?
    private var fixtureTexture: MTLTexture?
    private let inFlight = DispatchSemaphore(value: 3)

    init(frames: CaptureGlassFrames) {
        self.frames = frames
        super.init()
        if let device = CaptureGlassGPU.device { CVMetalTextureCacheCreate(nil,nil,device,nil,&textureCache) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0, let pipeline = CaptureGlassGPU.pipeline,
              let queue = CaptureGlassGPU.queue, inFlight.wait(timeout: .now()) == .success else { return }
        let (buffer,fixture) = frames.latest()
        var retainedFrame: CaptureGlassGPUFrame?
        var texture: MTLTexture?
        if let buffer, let cache = textureCache {
            var image: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,.bgra8Unorm,
                CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&image)
            if let image {
                retainedFrame = CaptureGlassGPUFrame(buffer: buffer, image: image)
                texture = CVMetalTextureGetTexture(image)
            }
        } else if let fixture {
            if fixtureTexture == nil { fixtureTexture = makeTexture(from: fixture) }
            texture = fixtureTexture
        }
        guard let texture, let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            inFlight.signal()
            return
        }
        func box(_ rect: CGRect?) -> SIMD4<Float> {
            guard let rect else { return .zero }
            return SIMD4(Float(rect.midX),Float(rect.midY),Float(rect.width/2),Float(rect.height/2))
        }
        let radius = area.map(CapturePillLayout.areaCornerRadius(for:)) ?? 0
        var uniforms = [SIMD4<Float>(Float(view.bounds.width),Float(view.bounds.height),0,0),
            box(area),box(pill),SIMD4<Float>(Float(radius),Float(connection),area == nil ? 0 : 1,pill == nil ? 0 : 1)]
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!,length:$0.count,index:0) }
        encoder.setFragmentTexture(texture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        let frame = retainedFrame
        command.addCompletedHandler { _ in
            withExtendedLifetime(frame) {}
            semaphore.signal()
        }
        command.commit()
    }
    private func makeTexture(from image: CGImage) -> MTLTexture? {
        guard let device = CaptureGlassGPU.device else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { data in
            guard let bitmap = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: data.baseAddress!, bytesPerRow: width*4)
            return texture
        }
    }

}
