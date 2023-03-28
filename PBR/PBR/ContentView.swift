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

#if os(iOS)
typealias MyViewRepresentable = UIViewRepresentable
#else
typealias MyViewRepresentable = NSViewRepresentable
#endif
struct ContentView2: MyViewRepresentable {
    typealias Coordinator = Metal
    @Binding fileprivate var message: String
    @Binding fileprivate var isShowAlert: Bool
    func makeCoordinator() -> Coordinator {
        Metal(self)
    }
    private func makeView(context: Context) -> MTKView {
        let v = MTKView()
        v.delegate = context.coordinator
        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError() }
        v.device = dev
        v.colorPixelFormat = .rgba8Unorm
        v.drawableSize = v.frame.size
        return v
    }
    func enqueueAlert(_ message: String) {
        Task { @MainActor in
            self.message = message;
            self.isShowAlert = true
        }
    }
    #if os(iOS)
    func makeUIView(context: Context) -> MTKView {
        makeView(context: context)
    }
    func updateUIView(_ uiView: MTKView, context: Context) {
        //
    }
    #else
    func makeNSView(context: Context) -> MTKView {
        makeView(context: context)
    }
    func updateNSView(_ nsView: MTKView, context: Context) {
        //
    }
    #endif
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

// Copy instance, not reference
extension Array {
    @inlinable public init(closure: () -> Element, count: Int) {
        var ary = [Element]()
        for _ in 0..<count {
            ary.append(closure())
        }
        self = ary
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

class MyScene {
    var cameraPos: simd_float3
    var cameraTarget: simd_float3
    var cameraUp: simd_float3
    var cameraFov: Float
    var cameraNear: Float
    var cameraFar: Float
    var sunLightIntensity: simd_float3
    var sunLightDirection: simd_float3
    init() {
        cameraPos = simd_float3(0, 2.5, -5.5)
        cameraTarget = simd_float3(0, 1.5, 0)
        cameraUp = simd_float3(0, 1, 0)
        cameraFov = 48.0 * Float.pi / 180.0
        cameraNear = 0.01
        cameraFar = 100.0
        sunLightIntensity = simd_float3(3, 3, 3)
        sunLightDirection = normalize(simd_float3(-0.1, 0.1, -1.0))
    }
}

let SPHERE_STACKS: Int = 10
let SPHERE_SLICES: Int = 12

class MyResource {
    var pso: MTLRenderPipelineState?
    var psoPost: MTLRenderPipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var cbLight: [MTLBuffer]
    var instanceMatBuf: MTLBuffer
    var depthState: MTLDepthStencilState
    var depthStateIgnore: MTLDepthStencilState
    var sailboatTex: MTLTexture
    var lennaTex: MTLTexture
    var ss: MTLSamplerState
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        guard let vsPost = lib.makeFunction(name: "postVS") else { fatalError() }
        guard let fsPost = lib.makeFunction(name: "postFS") else { fatalError() }
        var psoDesc = MTLRenderPipelineDescriptor()
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
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsPost
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Post PSO"
        do {
            self.psoPost = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
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
        
        // Create a plane
        let vbPlaneData: [VertexElement] = [
            VertexElement(MTLPackedFloat3Make(-1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0), vector_float2(0, 0)),
            VertexElement(MTLPackedFloat3Make( 1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0), vector_float2(1, 0)),
            VertexElement(MTLPackedFloat3Make(-1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0), vector_float2(0, 1)),
            VertexElement(MTLPackedFloat3Make( 1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0), vector_float2(1, 1)),
        ]
        self.vbPlane = device.makeBuffer(bytes: vbPlaneData, length: MemoryLayout<VertexElement>.size * vbPlaneData.count, options: .cpuCacheModeWriteCombined)!
        let ibPlaneData: [QuadIndexList] = [
            QuadIndexList(0, 1, 2, 2, 1, 3)
        ]
        self.ibPlane = device.makeBuffer(bytes: ibPlaneData, length: MemoryLayout<QuadIndexList>.size * ibPlaneData.count, options: .cpuCacheModeWriteCombined)!
        
        self.cbScene = [MTLBuffer](closure: { device.makeBuffer(length: 1024, options: .cpuCacheModeWriteCombined)! }, count: 2)
        self.cbLight = [MTLBuffer](closure: { device.makeBuffer(length: 1024, options: .cpuCacheModeWriteCombined)! }, count: 2)
        
        var instanceMat = [float3x4](repeating: float3x4(), count: 19)
        for i in 0..<18 {
            let tx: Float = Float(i % 6) * 1.1 - 3.3 + 0.65
            let ty: Float = Float(i / 6) * 1.1 + 1.1
            let s: Float = 0.5
            instanceMat[i] = float3x4(columns: (SIMD4(s, 0, 0, tx),
                                                SIMD4(0, s, 0, ty),
                                                SIMD4(0, 0, s, 0)))
        }
        instanceMat[18] = float3x4(columns: (SIMD4(3, 0, 0, 0), SIMD4(0, 3, 0, 2.5), SIMD4(0, 0, 3, 0)))
        self.instanceMatBuf = device.makeBuffer(bytes: instanceMat, length: MemoryLayout<float3x4>.size * instanceMat.count, options: .cpuCacheModeWriteCombined)!
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        dsDesc.depthCompareFunction = .always
        dsDesc.isDepthWriteEnabled = false
        self.depthStateIgnore = device.makeDepthStencilState(descriptor: dsDesc)!
        
        guard let sailboatPath = Bundle.main.url(forResource: "Sailboat", withExtension: "bmp") else { fatalError() }
        guard let sailboatFile = try? FileHandle(forReadingFrom: sailboatPath) else { fatalError() }
        let sailboatData = MyResource.generateMipmap(MyResource.loadBitmap(sailboatFile))
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
        
        guard let lennaPath = Bundle.main.url(forResource: "Lenna", withExtension: "bmp") else { fatalError() }
        guard let lennaFile = try? FileHandle(forReadingFrom: lennaPath) else { fatalError() }
        let lennaData = MyResource.generateMipmap(MyResource.loadBitmap(lennaFile))
        let lennaTexDesc = MTLTextureDescriptor()
        lennaTexDesc.width = Int(sailboatData[0].extent[0])
        lennaTexDesc.height = Int(sailboatData[0].extent[1])
        lennaTexDesc.pixelFormat = .rgba8Unorm
        lennaTexDesc.mipmapLevelCount = sailboatData.count
        lennaTexDesc.usage = .shaderRead
        self.lennaTex = device.makeTexture(descriptor: lennaTexDesc)!
        for i in 0..<lennaData.count {
            self.lennaTex.replace(region: MTLRegionMake2D(0, 0, Int(lennaData[i].extent[0]), Int(lennaData[i].extent[1])), mipmapLevel: i, withBytes: lennaData[i].data, bytesPerRow: Int(4 * lennaData[i].extent[0]))
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
    func available() -> Bool {
        self.pso != nil && self.psoPost != nil
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

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView2
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    var depthTex: MTLTexture?
    var lightAccumTex: MTLTexture?
    var scene: MyScene
    let resource: MyResource
    init(_ parent: ContentView2) {
        self.parent = parent
        self.device = MTLCreateSystemDefaultDevice()!
        #if !targetEnvironment(simulator)
        if !device.supportsFamily(.metal3) {
            parent.enqueueAlert("Metal3 GPU family needed")
        }
        #endif
        self.cmdQueue = self.device.makeCommandQueue()!
        self.scene = MyScene()
        self.resource = MyResource(device: device, alert: { (s: String) -> Void  in
            parent.enqueueAlert(s)
        })
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let texDesc = MTLTextureDescriptor()
        texDesc.width = Int(size.width)
        texDesc.height = Int(size.height)
        texDesc.textureType = .type2D
        texDesc.storageMode = .private //.memoryless
        texDesc.pixelFormat = .depth32Float
        texDesc.usage = [.renderTarget]
        self.depthTex = self.device.makeTexture(descriptor: texDesc)!
        
        texDesc.storageMode = .memoryless
        texDesc.pixelFormat = .rgba16Float
        self.lightAccumTex = self.device.makeTexture(descriptor: texDesc)!
    }
    func draw(in view: MTKView) {
        if !self.resource.available() { return }
        guard let currentDrawable = view.currentDrawable else { return }
        sema.wait()
        self.frameCount += 1
        let frameIndex = Int(self.frameCount % 2)
        
        let viewMat = MathUtil.lookAt(pos: self.scene.cameraPos, target: self.scene.cameraTarget, up: self.scene.cameraUp)
        let projMat = MathUtil.perspective(fov: self.scene.cameraFov, aspect: Float(view.drawableSize.width / view.drawableSize.height), near: self.scene.cameraFar, far: self.scene.cameraNear)
        
        struct CBScene {
            let viewProj: float4x4
            let metallic: packed_float2
            let roughness: packed_float2
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj, metallic: packed_float2(0, 1), roughness: packed_float2(0.05, 0.95))
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        struct CBLight {
            let cameraPosition: simd_float3
            let sunLightIntensity: simd_float3
            let sunLightDirection: simd_float3
        }
        var lightData = CBLight(cameraPosition: self.scene.cameraPos, sunLightIntensity: self.scene.sunLightIntensity, sunLightDirection: self.scene.sunLightDirection)
        self.resource.cbLight[frameIndex].contents().copyMemory(from: &lightData, byteCount: MemoryLayout<CBLight>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[1].texture = self.lightAccumTex
        passDesc.colorAttachments[1].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 0.0/*not rendered flag*/)
        passDesc.colorAttachments[1].loadAction = .clear
        passDesc.colorAttachments[1].storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.depthTex
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.instanceMatBuf, offset: 0, index: 1)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.setFragmentBuffer(self.resource.cbLight[frameIndex], offset: 0, index: 0)
        enc.setFragmentTexture(self.resource.sailboatTex, index: 0)
        enc.setFragmentSamplerState(self.resource.ss, index: 0)
        // Scene
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 18)
        enc.setVertexBuffer(self.resource.vbPlane, offset: 0, index: 0)
        enc.setFragmentTexture(self.resource.lennaTex, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ibPlane, indexBufferOffset: 0, instanceCount: 1, baseVertex: 0, baseInstance: 18)
        // Post
        enc.setDepthStencilState(self.resource.depthStateIgnore)
        enc.setRenderPipelineState(self.resource.psoPost!)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
