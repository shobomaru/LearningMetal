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
    var psoBackground: MTLRenderPipelineState?
    var psoTransmittanceLut: MTLRenderPipelineState?
    var psoSingleScatteringTex: MTLRenderPipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var depthState: MTLDepthStencilState
    var depthStateIgnore: MTLDepthStencilState
    var transmittanceLutTex: MTLTexture
    var singleScatteringRayleighTex: MTLTexture
    var singleScatteringMieTex: MTLTexture
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vsLut3D = lib.makeFunction(name: "lut3DVS") else { fatalError() }
        guard let vsBackground = lib.makeFunction(name: "backgroundVS") else { fatalError() }
        guard let fsBackground = lib.makeFunction(name: "backgroundFS") else { fatalError() }
        guard let fsTransmittanceLut = lib.makeFunction(name: "transmittanceLutFS") else { fatalError() }
        guard let fsSingleScatteringTex = lib.makeFunction(name: "singleScatteringTexFS") else { fatalError() }
        var psoDesc = MTLRenderPipelineDescriptor()
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsBackground
        psoDesc.fragmentFunction = fsBackground
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        //psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Background PSO"
        do {
            self.psoBackground = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsBackground
        psoDesc.fragmentFunction = fsTransmittanceLut
        psoDesc.colorAttachments[0].pixelFormat = .rgba16Float
        psoDesc.label = "TransmittanceLut PSO"
        do {
            self.psoTransmittanceLut = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsLut3D
        psoDesc.fragmentFunction = fsSingleScatteringTex
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.colorAttachments[0].pixelFormat = .rgba16Float
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.label = "SingleScattering PSO"
        do {
            self.psoSingleScatteringTex = try device.makeRenderPipelineState(descriptor: psoDesc)
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
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        dsDesc.depthCompareFunction = .always
        dsDesc.isDepthWriteEnabled = false
        self.depthStateIgnore = device.makeDepthStencilState(descriptor: dsDesc)!
        
        var texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 64, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        self.transmittanceLutTex = device.makeTexture(descriptor: texDesc)!
        
        texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 128, mipmapped: false)
        texDesc.textureType = .type3D
        texDesc.depth = 32
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        self.singleScatteringRayleighTex = device.makeTexture(descriptor: texDesc)!
        self.singleScatteringMieTex = device.makeTexture(descriptor: texDesc)!
    }
    func available() -> Bool {
        self.psoBackground != nil && self.psoTransmittanceLut != nil && self.psoSingleScatteringTex != nil
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
            let cameraPos: simd_float3
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj, cameraPos: self.scene.cameraPos)
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        
        var passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].texture = self.resource.transmittanceLutTex
        var enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "TransmittanceLut Pass"
        enc.setRenderPipelineState(self.resource.psoTransmittanceLut!)
        enc.setFragmentBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        
        passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].texture = self.resource.singleScatteringRayleighTex
        passDesc.colorAttachments[1].loadAction = .dontCare
        passDesc.colorAttachments[1].storeAction = .store
        passDesc.colorAttachments[1].texture = self.resource.singleScatteringMieTex
        passDesc.renderTargetArrayLength = self.resource.singleScatteringRayleighTex.depth
        enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "SingleScattering Pass"
        enc.setRenderPipelineState(self.resource.psoSingleScatteringTex!)
        var depthSlice = [UInt32(self.resource.singleScatteringRayleighTex.depth)]
        enc.setVertexBytes(&depthSlice, length: 4, index: 0)
        enc.setFragmentTexture(self.resource.transmittanceLutTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: self.resource.singleScatteringRayleighTex.depth)
        enc.endEncoding()
        
        passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        //passDesc.colorAttachments[1].texture = self.lightAccumTex
        //passDesc.colorAttachments[1].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        //passDesc.colorAttachments[1].loadAction = .clear
        //passDesc.colorAttachments[1].storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.depthTex
        enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.psoBackground!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthStateIgnore)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.setFragmentBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.setFragmentTexture(self.resource.transmittanceLutTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
