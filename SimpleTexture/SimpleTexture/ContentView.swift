import SwiftUI
import MetalKit
import simd

struct ContentView: View {
    @State private var message = "default"
    @State private var isShowAlert = false
    var body: some View {
        VStack {
            ContentView2(message: $message, isShowAlert: $isShowAlert)
                .alert(isPresented: $isShowAlert) { () -> Alert in
                    return Alert(title: Text("Error"), message: Text(message))
                }
        }
    }
}

struct ContentView2: UIViewRepresentable {
    typealias Coordinator = Metal
    @Binding fileprivate var message: String
    @Binding fileprivate var isShowAlert: Bool
    func makeCoordinator() -> Coordinator {
        Metal(self)
    }
    func makeUIView(context: UIViewRepresentableContext<ContentView2>) -> MTKView {
        let v = MTKView()
        v.delegate = context.coordinator
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError() }
        v.device = dev
        v.colorPixelFormat = .rgba8Unorm
        v.drawableSize = v.frame.size
        return v
    }
    func updateUIView(_ uiView: MTKView, context: Context) {
        //
    }
    func enqueueAlert(_ message: String) {
        Task { @MainActor in
            self.message = message;
            self.isShowAlert = true
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct MathUtil {
    static func lookAt(pos: simd_float3, target: simd_float3, up: simd_float3) -> float4x4 {
        let dir = normalize(target - pos)
        let x = normalize(cross(up, dir))
        let y = cross(dir, x)
        let d0 = dot(-pos, x)
        let d1 = dot(-pos, y)
        let d2 = dot(-pos, dir)
        return float4x4.init(columns: (SIMD4(x.x, y.x, dir.x, 0),
                                SIMD4(x.y, y.y, dir.y, 0),
                                SIMD4(x.z, y.z, dir.z, 0),
                                SIMD4(d0, d1, d2, 1)))
    }
    static func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let h = 1 / tan(0.5 * fov)
        let z = far / (far - near)
        return float4x4.init(columns: (SIMD4(h / aspect, 0, 0, 0),
                                SIMD4(0, h, 0, 0),
                                SIMD4(0, 0, z, 1),
                                SIMD4(0, 0, -z * near, 0)))
    }
}

struct VertexElement {
    var position: MTLPackedFloat3
    var normal: MTLPackedFloat3
    var uv: vector_float2
    init(_ position: MTLPackedFloat3, _ normal: MTLPackedFloat3, _ uv: vector_float2) {
        self.position = position
        self.normal = normal
        self.uv = uv
    }
};

struct QuadIndexList {
    var v0: UInt16
    var v1: UInt16
    var v2: UInt16
    var v3: UInt16
    var v4: UInt16
    var v5: UInt16
    init(_ v0: UInt16, _ v1: UInt16, _ v2: UInt16, _ v3: UInt16, _ v4: UInt16, _ v5: UInt16) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
        self.v3 = v3
        self.v4 = v4
        self.v5 = v5
    }
};

struct ImageData {
    var extent: [UInt]
    var data: [UInt8]
};

let SPHERE_STACKS: Int = 10
let SPHERE_SLICES: Int = 12

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView2
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    var pso: MTLRenderPipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var cbScene: [MTLBuffer]
    var depthTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var sailboatTex: MTLTexture
    var ss: MTLSamplerState
    init(_ parent: ContentView2) {
        self.parent = parent
        self.device = MTLCreateSystemDefaultDevice()!
        #if !targetEnvironment(simulator)
        if !device.supportsFamily(.metal3) {
            parent.enqueueAlert("Metal3 GPU family needed")
        }
        #endif
        self.cmdQueue = self.device.makeCommandQueue()!
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].bufferIndex = 0
        vd.attributes[0].offset = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].bufferIndex = 0
        vd.attributes[1].offset = 12
        vd.attributes[2].format = .float2
        vd.attributes[2].bufferIndex = 0
        vd.attributes[2].offset = 24
        vd.layouts[0].stride = MemoryLayout<VertexElement>.stride
        psoDesc.vertexDescriptor = vd
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            parent.enqueueAlert(String(describing: e))
        }
        // Create a sphere
        var vbData = [VertexElement](unsafeUninitializedCapacity: (SPHERE_STACKS + 1) * (SPHERE_SLICES + 1), initializingWith: { buffer, initializedCount in
            initializedCount = 0
        })
        for y in 0...SPHERE_STACKS {
            for x in 0...SPHERE_SLICES {
                let v0 = Float(x) / Float(SPHERE_SLICES)
                let v1 = Float(y) / Float(SPHERE_STACKS)
                let theta = 2.0 * Float.pi * v0
                let phi = 2.0 * Float.pi * v1 / 2.0
                let pos = MTLPackedFloat3Make(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
                let r = Float(1.0)
                let norm = MTLPackedFloat3Make(pos.x / r, pos.y / r, pos.z / r)
                let uv = vector_float2(v0, v1)
                vbData.append(VertexElement(pos, norm, uv))
            }
        }
        self.vb = device.makeBuffer(bytes: vbData, length: MemoryLayout<VertexElement>.size * vbData.count, options: .cpuCacheModeWriteCombined)!
        var ibData = [QuadIndexList](unsafeUninitializedCapacity: (SPHERE_STACKS * SPHERE_SLICES), initializingWith: { buffer, initializedCount in
            initializedCount = 0
        })
        for y in 0..<SPHERE_STACKS {
            for x in 0..<SPHERE_SLICES {
                let b = UInt16(y * (SPHERE_SLICES + 1) + x)
                let s = UInt16(SPHERE_SLICES + 1)
                ibData.append(QuadIndexList(b, b + s, b + 1, b + s, b + s + 1, b + 1))
            }
        }
        self.ib = device.makeBuffer(bytes: ibData, length: MemoryLayout<QuadIndexList>.size * ibData.count, options: .cpuCacheModeWriteCombined)!
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        guard let sailboatPath = Bundle.main.url(forResource: "Sailboat", withExtension: "bmp") else { fatalError() }
        guard let sailboatFile = try? FileHandle(forReadingFrom: sailboatPath) else { fatalError() }
        let sailboatData = Metal.generateMipmap(Metal.loadBitmap(sailboatFile))
        let sailboatTexDesc = MTLTextureDescriptor()
        sailboatTexDesc.width = Int(sailboatData[0].extent[0])
        sailboatTexDesc.height = Int(sailboatData[0].extent[1])
        sailboatTexDesc.pixelFormat = .rgba8Unorm
        sailboatTexDesc.mipmapLevelCount = sailboatData.count
        sailboatTexDesc.usage = .shaderRead
        self.sailboatTex = device.makeTexture(descriptor: sailboatTexDesc)!
        for i in 0..<sailboatData.count {
            self.sailboatTex.replace(region: MTLRegionMake2D(0, 0, Int(sailboatData[i].extent[0]), Int(sailboatData[i].extent[1])), mipmapLevel: i, withBytes: sailboatData[i].data, bytesPerRow: Int(4 * sailboatData[i].extent[0]))
        }
        
        let ssDesc = MTLSamplerDescriptor()
        ssDesc.minFilter = .linear
        ssDesc.magFilter = .linear
        ssDesc.mipFilter = .linear
        ssDesc.sAddressMode = .repeat
        ssDesc.tAddressMode = .repeat
        ssDesc.maxAnisotropy = 4
        self.ss = device.makeSamplerState(descriptor: ssDesc)!
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let texDesc = MTLTextureDescriptor()
        texDesc.width = Int(size.width)
        texDesc.height = Int(size.height)
        texDesc.textureType = .type2D
        texDesc.storageMode = .private //.memoryless
        texDesc.pixelFormat = .depth32Float
        texDesc.usage = [.renderTarget]
        self.depthTex = self.device.makeTexture(descriptor: texDesc)
    }
    func draw(in view: MTKView) {
        if (self.pso == nil) { return }
        guard let currentDrawable = view.currentDrawable else { return }
        sema.wait()
        self.frameCount += 1
        let frameIndex = Int(self.frameCount % 2)
        
        let cameraPos = simd_float3(0, 4, -4)
        let cameraTarget = simd_float3(0, 0, 0)
        let cameraUp = simd_float3(0, 1, 0)
        let cameraFov = 45.0 * Float.pi / 180.0
        let cameraNear: Float = 0.01
        let cameraFar: Float = 100.0
        
        let viewMat = MathUtil.lookAt(pos: cameraPos, target: cameraTarget, up: cameraUp)
        let projMat = MathUtil.perspective(fov: cameraFov, aspect: Float(view.drawableSize.width / view.drawableSize.height), near: cameraFar, far: cameraNear)
        
        struct CBScene {
            let viewProj: float4x4
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj)
        self.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.depthTex
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.depthState)
        enc.setVertexBuffer(self.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.cbScene[frameIndex], offset: 0, index: 1)
        enc.setFragmentTexture(self.sailboatTex, index: 0)
        enc.setFragmentSamplerState(self.ss, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
    static private func loadBitmap(_ fh: FileHandle) -> ImageData {
        struct BitmapInfoHeader {
            var size: UInt32
            var width: Int32
            var height: Int32
            var planes: UInt16
            var bitCount: UInt16
            var compression: UInt32
            var sizeImage: UInt32
            var xPelsPerMeter: Int32
            var yPelsPerMeter: Int32
            var clrUsed: UInt32
            var clrImportant: UInt32
        };
        guard let fileHeader = try? fh.read(upToCount: 14) else { fatalError() }
        if fileHeader[0] != 0x42 || fileHeader[1] != 0x4D {
            fatalError()
        }
        guard let infoHeader = try? fh.read(upToCount: MemoryLayout<BitmapInfoHeader>.size) else { fatalError() }
        let info = infoHeader.withUnsafeBytes { buf in
            buf.load(as: BitmapInfoHeader.self)
        }
        var oneline: [UInt8] = Array(repeating: 0, count: Int(info.width) * 3) // rgb
        var data: [UInt8] = Array(repeating: 0, count: Int(info.width) * Int(info.height) * 4) // rgba
        for y in 0..<Int(info.height) {
            guard let onelineData = try? fh.read(upToCount: Int(info.width) * 3) else { fatalError() }
            _ = oneline.withUnsafeMutableBytes { buf in
                onelineData.copyBytes(to: buf)
            }
            for x in 0..<Int(info.width) {
                let q = (Int(info.height) - 1 - y) * Int(info.width) + x
                data[q * 4] = oneline[x * 3 + 2]
                data[q * 4 + 1] = oneline[x * 3 + 1]
                data[q * 4 + 2] = oneline[x * 3]
                data[q * 4 + 3] = 0xFF
            }
        }
        return ImageData(extent: [UInt(info.width), UInt(info.height), 1], data: data)
    }
    static private func generateMipmap(_ mip0: ImageData) -> [ImageData] {
        var v: [ImageData] = Array()
        v.append(mip0)
        while v.last!.extent[0] != 1 && v.last!.extent[1] != 1 {
            v.append(downsample(v.last!))
        }
        return v
    }
    static private func downsample(_ high: ImageData) -> ImageData {
        let ext: [UInt] = [max(1, high.extent[0] / 2), max(1, high.extent[1] / 2), 1]
        var data: [UInt8] = Array(repeating: 0, count: Int(ext[0]) * Int(ext[1]) * 4)
        for y in 0..<ext[1] {
            for x in 0..<ext[0] {
                let pd = Int(y * ext[0] + x)
                let ps = Int(2 * y * 2 * ext[0] + 2 * x)
                for c in 0..<4 {
                    var d = UInt32(high.data[ps * 4 + c])
                    d += UInt32(high.data[ps * 4 + 1 * 4 + c])
                    d += UInt32(high.data[ps * 4 + Int(high.extent[0]) * 4 + c])
                    d += UInt32(high.data[ps * 4 + Int(high.extent[0]) * 4 + 1 * 4 + c])
                    data[pd * 4 + c] = UInt8((d + 2) / 4)
                }
            }
        }
        return ImageData(extent: ext, data: data)
    }
}
