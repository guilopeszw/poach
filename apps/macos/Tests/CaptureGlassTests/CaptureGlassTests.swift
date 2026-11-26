import Foundation
import Metal

// Run the app's actual Metal source against a synthetic grayscale stripe texture. No display
// access is needed: this checks transparency, real refraction and RGB dispersion on the GPU.
let file = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let shaderSource = file.components(separatedBy: "static let source = \"\"\"")[1].components(separatedBy: "\"\"\"")[0]
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("Skipped: Metal device unavailable.")
    exit(0)
}
let library = try device.makeLibrary(source: shaderSource, options: nil)
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = library.makeFunction(name: "glassVertex")
pipelineDescriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
let width = 256, height = 192
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
textureDescriptor.storageMode = .shared
textureDescriptor.usage = [.renderTarget, .shaderRead]
let input = device.makeTexture(descriptor: textureDescriptor)!
let output = device.makeTexture(descriptor: textureDescriptor)!
var stripes = [UInt8](repeating: 255, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let value: UInt8 = (x / 6 + y / 6).isMultiple(of: 2) ? 24 : 225
        for channel in 0..<3 { stripes[(y * width + x) * 4 + channel] = value }
    }
}
input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: stripes, bytesPerRow: width * 4)
let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = output
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store
pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
func render(pill: SIMD4<Float>, connection: Float) -> [UInt8] {
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    var uniforms = [SIMD4<Float>(256,192,0,0), SIMD4<Float>(128,72,80,48),
                    pill, SIMD4<Float>(24,connection,1,1)]
    encoder.setRenderPipelineState(pipeline)
    uniforms.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
    encoder.setFragmentTexture(input, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    precondition(command.status == .completed, "GPU command failed: \(String(describing: command.error))")
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    output.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
    return pixels
}
var pixels = render(pill: SIMD4<Float>(128,152,44,16), connection: 0)
func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
precondition(alpha(128,72) == 0, "The selection centre must remain untouched")
precondition(alpha(5,5) == 0, "Pixels outside the liquid must remain transparent")
precondition(alpha(128,152) == 255, "The detached pill must render")
precondition(alpha(49,72) > 200, "The selection's optical edge must render")
// Sample a straight edge over dark content: opacity must already fade close to the rim,
// then ease gradually into a completely untouched centre, without an opaque inner ledge.
precondition(alpha(56,72) < 250 && alpha(56,72) > alpha(64,72), "The rim must fade before its inner edge")
precondition(alpha(64,72) > 40 && alpha(64,72) < 150, "The middle of the transition must remain translucent")
precondition(alpha(72,72) < 30 && alpha(80,72) == 0, "The optical band must settle smoothly into the clear centre")
var chromaticPixels = 0
for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i+3] > 200 {
    let channels = pixels[i..<(i+3)].map(Int.init)
    if channels.max()! - channels.min()! > 25 { chromaticPixels += 1 }
}
precondition(chromaticPixels > 50, "Separate RGB ray samples must produce visible dispersion")
pixels = render(pill: SIMD4<Float>(128,126,16,16), connection: 30)
precondition(alpha(150,123) > 200, "A liquid neck must join the nearby shapes")
pixels = render(pill: SIMD4<Float>(128,126,16,16), connection: 0)
precondition(alpha(150,123) == 0, "The neck must pinch off when the connection ends")
print("Metal glass passed: connected and detached neck, clear centre, refracted perimeter, detached pill and \(chromaticPixels) chromatic pixels.")
