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
    typealias NSViewType = MTKView
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

struct VertexElement {
    var position: MTLPackedFloat3
    var normal: MTLPackedFloat3
    init(_ position: MTLPackedFloat3, _ normal: MTLPackedFloat3) {
        self.position = position
        self.normal = normal
    }
}

struct ParticleElement {
    var position: MTLPackedFloat3
    var direction: MTLPackedFloat3
    var color: UInt64
}

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
}

class MyScene {
    var cameraPos: simd_float3
    var cameraTarget: simd_float3
    var cameraUp: simd_float3
    var cameraFov: Float
    var cameraNear: Float
    var cameraFar: Float
    init() {
        cameraPos = simd_float3(0, 4, -4)
        cameraTarget = simd_float3(0, 0, 0)
        cameraUp = simd_float3(0, 1, 0)
        cameraFov = 45.0 * Float.pi / 180.0
        cameraNear = 0.01
        cameraFar = 100.0
    }
}

let MaxGpuParticleCount = 8192
let SpawnRate = 64

class MyResource {
    //var pso: MTLRenderPipelineState?
    var psoParticle: MTLRenderPipelineState?
    var psoSpawn: MTLComputePipelineState?
    var psoGenIndirectArgs: MTLComputePipelineState?
    var psoUpdate: MTLComputePipelineState?
    //var vb: MTLBuffer
    //var ib: MTLBuffer
    //var vbPlane: MTLBuffer
    //var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var zTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var cbGpuParticle: [MTLBuffer]
    var particleBuf: [MTLBuffer]
    var indirectArgsComputeBuf: MTLBuffer
    var indirectArgsRenderBuf: MTLBuffer
    var countBuf1: MTLBuffer
    var countBuf2: MTLBuffer
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "particleVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "particleFS") else { fatalError() }
        guard let csSpawn = lib.makeFunction(name: "gpuParticleSpawnCS") else { fatalError() }
        guard let csGenIndirectArgs = lib.makeFunction(name: "gpuParticleGenIndirectArgsCS") else { fatalError() }
        guard let csUpdate = lib.makeFunction(name: "gpuParticleUpdateCS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[0].offset = 0;
        vd.attributes[1].format = .half4
        vd.attributes[1].bufferIndex = 0;
        vd.attributes[1].offset = 24
        vd.layouts[0].stride = MemoryLayout<ParticleElement>.stride
        vd.layouts[0].stepFunction = .perInstance
        psoDesc.vertexDescriptor = vd
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Particle PSO"
        do {
            self.psoParticle = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        do {
            self.psoSpawn = try device.makeComputePipelineState(function: csSpawn)
            self.psoGenIndirectArgs = try device.makeComputePipelineState(function: csGenIndirectArgs)
            self.psoUpdate = try device.makeComputePipelineState(function: csUpdate)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
//        // Create a sphere
//        var vbData = [VertexElement](unsafeUninitializedCapacity: (SPHERE_STACKS + 1) * (SPHERE_SLICES + 1), initializingWith: { buffer, initializedCount in
//            initializedCount = 0
//        })
//        for y in 0...SPHERE_STACKS {
//            for x in 0...SPHERE_SLICES {
//                let v0 = Float(x) / Float(SPHERE_SLICES)
//                let v1 = Float(y) / Float(SPHERE_STACKS)
//                let theta = 2.0 * Float.pi * v0
//                let phi = 2.0 * Float.pi * v1 / 2.0
//                let pos = MTLPackedFloat3Make(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
//                let r = Float(1.0)
//                let norm = MTLPackedFloat3Make(pos.x / r, pos.y / r, pos.z / r)
//                vbData.append(VertexElement(pos, norm))
//            }
//        }
//        self.vb = device.makeBuffer(bytes: vbData, length: MemoryLayout<VertexElement>.size * vbData.count, options: .cpuCacheModeWriteCombined)!
//        var ibData = [QuadIndexList](unsafeUninitializedCapacity: (SPHERE_STACKS * SPHERE_SLICES), initializingWith: { buffer, initializedCount in
//            initializedCount = 0
//        })
//        for y in 0..<SPHERE_STACKS {
//            for x in 0..<SPHERE_SLICES {
//                let b = UInt16(y * (SPHERE_SLICES + 1) + x)
//                let s = UInt16(SPHERE_SLICES + 1)
//                ibData.append(QuadIndexList(b, b + s, b + 1, b + s, b + s + 1, b + 1))
//            }
//        }
//        self.ib = device.makeBuffer(bytes: ibData, length: MemoryLayout<QuadIndexList>.size * ibData.count, options: .cpuCacheModeWriteCombined)!
//
//        // Create a plane
//        let vbPlaneData: [VertexElement] = [
//            VertexElement(MTLPackedFloat3Make(-1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
//            VertexElement(MTLPackedFloat3Make( 1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
//            VertexElement(MTLPackedFloat3Make(-1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
//            VertexElement(MTLPackedFloat3Make( 1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
//        ]
//        self.vbPlane = device.makeBuffer(bytes: vbPlaneData, length: MemoryLayout<VertexElement>.size * vbPlaneData.count, options: .cpuCacheModeWriteCombined)!
//        let ibPlaneData: [QuadIndexList] = [
//            QuadIndexList(0, 1, 2, 2, 1, 3)
//        ]
//        self.ibPlane = device.makeBuffer(bytes: ibPlaneData, length: MemoryLayout<QuadIndexList>.size * ibPlaneData.count, options: .cpuCacheModeWriteCombined)!
        
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        // Create GPU particle buffers
        
        self.cbGpuParticle = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        self.particleBuf = [MTLBuffer](repeating: device.makeBuffer(length: MemoryLayout<ParticleElement>.size * MaxGpuParticleCount, options: .storageModePrivate)!, count: 2)
        
        self.indirectArgsComputeBuf = device.makeBuffer(length: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.size, options: [.storageModePrivate])!
        var defaultArgs = MTLDrawPrimitivesIndirectArguments(vertexCount: 1, instanceCount: 0, vertexStart: 0, baseInstance: 0)
        self.indirectArgsRenderBuf = device.makeBuffer(bytes: &defaultArgs, length: MemoryLayout.size(ofValue: defaultArgs))!
        
        self.countBuf1 = device.makeBuffer(length: 4, options: [.storageModePrivate])!
        self.countBuf2 = device.makeBuffer(length: 4, options: [.storageModePrivate])!
    }
    func available() -> Bool {
        self.psoParticle != nil && self.psoSpawn != nil && self.psoGenIndirectArgs != nil && self.psoUpdate != nil
    }
}

let SPHERE_STACKS: Int = 10
let SPHERE_SLICES: Int = 12

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView2
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    var scene: MyScene
    var resource: MyResource
    init(_ parent: ContentView2) {
        self.parent = parent
        self.device = MTLCreateSystemDefaultDevice()!
        #if !targetEnvironment(simulator)
        if !device.supportsFamily(.metal3) {
            parent.enqueueAlert("Metal3 GPU family needed")
        }
        #endif
        if !device.supportsFamily(.apple7) {
            parent.enqueueAlert("SIMD-scoped reduction needed (Apple7+)")
        }
        self.cmdQueue = self.device.makeCommandQueue()!
        self.resource = MyResource(device: device, alert: { (s: String) -> Void  in
            parent.enqueueAlert(s)
        })
        self.scene = MyScene()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let texDesc = MTLTextureDescriptor()
        texDesc.width = Int(size.width)
        texDesc.height = Int(size.height)
        texDesc.textureType = .type2D
        texDesc.storageMode = .private //.memoryless
        texDesc.pixelFormat = .depth32Float
        texDesc.usage = [.renderTarget]
        self.resource.zTex = self.device.makeTexture(descriptor: texDesc)
    }
    func draw(in view: MTKView) {
        if (!self.resource.available()) { return }
        guard let currentDrawable = view.currentDrawable else { return }
        sema.wait()
        self.frameCount += 1
        let frameIndex = Int(self.frameCount % 2)
        
        let viewMat = MathUtil.lookAt(pos: self.scene.cameraPos, target: self.scene.cameraTarget, up: self.scene.cameraUp)
        let projMat = MathUtil.perspective(fov: self.scene.cameraFov, aspect: Float(view.drawableSize.width / view.drawableSize.height), near: self.scene.cameraFar, far: self.scene.cameraNear)
        
        struct CBScene {
            let viewProj: float4x4
        }
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj)
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        struct CBGpuParticle {
            let seed: UInt32
            let bufferMax: UInt32
            let spawnRate: UInt32
            let speed: Float
        }
        var gpuParticleData = CBGpuParticle(seed: UInt32(frameCount * 48271), bufferMax: UInt32(MaxGpuParticleCount), spawnRate: UInt32(SpawnRate), speed: 0.05)
        self.resource.cbGpuParticle[frameIndex].contents().copyMemory(from: &gpuParticleData, byteCount: MemoryLayout<CBGpuParticle>.size)
    
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        
        let numThreads = MTLSizeMake(64, 1, 1)
        let csEnc = cmdBuf.makeComputeCommandEncoder()!
        csEnc.label = "Particle control pass"
        csEnc.setBuffer(self.resource.particleBuf[Int(frameCount & 1)], offset: 0, index: 0)
        csEnc.setBuffer(self.resource.indirectArgsComputeBuf, offset: 0, index: 1)
        csEnc.setBuffer(self.resource.countBuf1, offset: 0, index: 2)
        csEnc.setBuffer(self.resource.cbGpuParticle[frameIndex], offset: 0, index: 3)
        csEnc.setBuffer(self.resource.particleBuf[Int((frameCount + 1) & 1)], offset: 0, index: 4)
        csEnc.setBuffer(self.resource.countBuf2, offset: 0, index: 5)
        // Spawn
        csEnc.setComputePipelineState(self.resource.psoSpawn!)
        csEnc.dispatchThreadgroups(MTLSizeMake((SpawnRate + 63) / 64, 1, 1), threadsPerThreadgroup: numThreads)
        // IndirectArgs
        csEnc.setComputePipelineState(self.resource.psoGenIndirectArgs!)
        csEnc.dispatchThreadgroups(MTLSizeMake(1, 1, 1), threadsPerThreadgroup: numThreads)
        // Update
        csEnc.setComputePipelineState(self.resource.psoUpdate!)
        csEnc.dispatchThreadgroups(indirectBuffer: self.resource.indirectArgsComputeBuf, indirectBufferOffset: 0, threadsPerThreadgroup: numThreads)
        csEnc.endEncoding()
        
        let bltEnc2 = cmdBuf.makeBlitCommandEncoder()!
        bltEnc2.label = "Counter copy and clear"
        // Copy draw indirect args
        bltEnc2.copy(from: self.resource.countBuf2, sourceOffset: 0, to: self.resource.indirectArgsRenderBuf, destinationOffset: 4, size: 4)
        // Copy count
        bltEnc2.copy(from: self.resource.countBuf2, sourceOffset: 0, to: self.resource.countBuf1, destinationOffset: 0, size: 4)
        bltEnc2.fill(buffer: self.resource.countBuf2, range: 0..<4, value: 0)
        bltEnc2.endEncoding()
        
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.resource.zTex
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.psoParticle!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.particleBuf[1], offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        enc.drawPrimitives(type: .point, indirectBuffer: self.resource.indirectArgsRenderBuf, indirectBufferOffset: 0)
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
