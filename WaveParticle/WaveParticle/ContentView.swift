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
    init(_ position: MTLPackedFloat3, _ normal: MTLPackedFloat3) {
        self.position = position
        self.normal = normal
    }
}

struct ParticleElement {
    var position: simd_packed_float2
    var direction: simd_packed_float2
    var birthPosition: simd_packed_float2
    var time: Float
    var amplitude: Float16
    var division: UInt16
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
        cameraTarget = simd_float3(0, -0.6, 0)
        cameraUp = simd_float3(0, 1, 0)
        cameraFov = 45.0 * Float.pi / 180.0
        cameraNear = 0.01
        cameraFar = 100.0
    }
}

let MaxWaveParticleCount = 8192
let BirthDuration = 72
let BirthCountPerInstance = 12
let StepSpeed: Float = 0.006
let ParticleSize: Float = 0.13
let NumQuads = 80

class MyResource {
    //var pso: MTLRenderPipelineState?
    var psoBirth: MTLComputePipelineState?
    var psoGenIndirectArgs: MTLComputePipelineState?
    var psoUpdate: MTLComputePipelineState?
    //var psoMerge: MTLComputePipelineState?
    var psoHeight: MTLRenderPipelineState?
    var psoNormal: MTLRenderPipelineState?
    var psoDraw: MTLRenderPipelineState?
    //var vb: MTLBuffer
    //var ib: MTLBuffer
    //var vbPlane: MTLBuffer
    //var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var zTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var cbParticle: [MTLBuffer]
    var particleBuf: [MTLBuffer]
    var countBuf: [MTLBuffer]
    var indirectArgsCSBuf: MTLBuffer
    var indirectArgsHeightBuf: MTLBuffer
    var heightMap: MTLTexture
    var ibDraw: MTLBuffer
    var normalMap: MTLTexture
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vsDraw = lib.makeFunction(name: "drawVS") else { fatalError() }
        guard let fsDraw = lib.makeFunction(name: "drawFS") else { fatalError() }
        guard let vsHeight = lib.makeFunction(name: "heightVS") else { fatalError() }
        guard let fsHeight = lib.makeFunction(name: "heightFS") else { fatalError() }
        guard let vsNormal = lib.makeFunction(name: "normalVS") else { fatalError() }
        guard let fsNormal = lib.makeFunction(name: "normalFS") else { fatalError() }
        guard let csBirth = lib.makeFunction(name: "birthCS") else { fatalError() }
        guard let csGenIndirectArgs = lib.makeFunction(name: "genIndirectArgsCS") else { fatalError() }
        guard let csUpdate = lib.makeFunction(name: "updateCS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsDraw
        psoDesc.fragmentFunction = fsDraw
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
        psoDesc.label = "Draw PSO"
        do {
            self.psoDraw = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc.vertexFunction = vsHeight
        psoDesc.fragmentFunction = fsHeight
        psoDesc.vertexDescriptor = nil
        psoDesc.colorAttachments[0].pixelFormat = .r16Float
        psoDesc.colorAttachments[0].isBlendingEnabled = true
        psoDesc.colorAttachments[0].rgbBlendOperation = .add
        psoDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        psoDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        psoDesc.colorAttachments[0].alphaBlendOperation = .add
        psoDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        psoDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        psoDesc.depthAttachmentPixelFormat = .invalid
        psoDesc.label = "Height PSO"
        do {
            self.psoHeight = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc.vertexFunction = vsNormal
        psoDesc.fragmentFunction = fsNormal
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Snorm
        psoDesc.colorAttachments[0].isBlendingEnabled = false
        psoDesc.label = "Normal PSO"
        do {
            self.psoNormal = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        do {
            self.psoBirth = try device.makeComputePipelineState(function: csBirth)
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
        
        self.cbScene = [MTLBuffer](closure: { device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)! }, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        // Create GPU particle buffers
        
        self.cbParticle = [MTLBuffer](closure: { device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)! }, count: 2)
        for i in 0..<2 {
            self.cbParticle[i].label = "CBParticle \(i)"
        }
        self.particleBuf = [MTLBuffer](closure: { device.makeBuffer(length: MemoryLayout<ParticleElement>.size * MaxWaveParticleCount, options: .storageModePrivate)! }, count: 2)
        for i in 0..<2 {
            self.particleBuf[i].label = "ParticleBuf \(i)"
        }
        self.countBuf = [MTLBuffer](closure: { device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModePrivate)! }, count:2)
        for i in 0..<2 {
            self.countBuf[i].label = "CountBuf \(i)"
        }
        self.indirectArgsCSBuf = device.makeBuffer(length: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.size, options: .storageModePrivate)!
        self.indirectArgsCSBuf.label = "IndirectArgsCSBuf"
        var indirectArgs = MTLDrawPrimitivesIndirectArguments(vertexCount: 4, instanceCount: 0, vertexStart: 0, baseInstance: 0)
        self.indirectArgsHeightBuf = device.makeBuffer(bytes: &indirectArgs, length: MemoryLayout<MTLDrawPrimitivesIndirectArguments>.size, options: .cpuCacheModeWriteCombined)!
        self.indirectArgsHeightBuf.label = "IndirectArgsHeightBuf"
        
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 256, height: 256, mipmapped: false)
        texDesc.usage = [.shaderRead, .renderTarget]
        texDesc.storageMode = .private
        self.heightMap = device.makeTexture(descriptor: texDesc)!
        
        var ibDrawData = [UInt16]()
        for b in 0..<NumQuads {
            for a in 0..<NumQuads {
                let s: UInt16 = UInt16((NumQuads + 1) * b + a)
                let t: UInt16 = UInt16((NumQuads + 1) * (b + 1) + a)
                ibDrawData.append(s)
                ibDrawData.append(t)
                ibDrawData.append(s + 1)
                ibDrawData.append(t)
                ibDrawData.append(t + 1)
                ibDrawData.append(s + 1)
            }
        }
        self.ibDraw = device.makeBuffer(bytes: ibDrawData, length: MemoryLayout<UInt16>.size * 6 * NumQuads * NumQuads)!
        
        texDesc.pixelFormat = .rgba8Snorm
        self.normalMap = device.makeTexture(descriptor: texDesc)!
        
        // TODO:
        let queue = device.makeCommandQueue()!
        queue.label = "First clear"
        let cmdBuf = queue.makeCommandBuffer()!
        let enc = cmdBuf.makeBlitCommandEncoder()!
        enc.fill(buffer: self.countBuf[0], range: 0..<4, value: 0)
        enc.fill(buffer: self.countBuf[1], range: 0..<4, value: 0)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }
    func available() -> Bool {
        self.psoBirth != nil && self.psoGenIndirectArgs != nil && self.psoUpdate != nil && self.psoHeight != nil && self.psoDraw != nil
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
        
        struct CBParticleSim {
            let birthPosition: simd_packed_float2
            let step: Float
            let maxParticles: UInt32
        }
        var birthPos = simd_packed_float2(0, 0)
        birthPos.x = 0.25 * sin(2.0 * Float.pi * Float(frameCount) / 123.4)
        birthPos.y = 0.25 * sin(2.0 * Float.pi * Float(frameCount) / 123.4)
        var particleData = CBParticleSim(birthPosition: birthPos, step: StepSpeed, maxParticles: UInt32(MaxWaveParticleCount))
        self.resource.cbParticle[frameIndex].contents().copyMemory(from: &particleData, byteCount: MemoryLayout<CBParticleSim>.size)
    
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        
        let numThreads = MTLSizeMake(64, 1, 1)
        let csEnc = cmdBuf.makeComputeCommandEncoder()!
        csEnc.label = "Particle control pass"
        csEnc.setBuffer(self.resource.particleBuf[Int(frameCount & 1)], offset: 0, index: 0)
        csEnc.setBuffer(self.resource.countBuf[0], offset: 0, index: 1)
        csEnc.setBuffer(self.resource.cbParticle[frameIndex], offset: 0, index: 2)
        csEnc.setBuffer(self.resource.particleBuf[Int(frameCount + 1) & 1], offset: 0, index: 3)
        csEnc.setBuffer(self.resource.countBuf[1], offset: 0, index: 4)
        csEnc.setBuffer(self.resource.indirectArgsCSBuf, offset: 0, index: 5)
        // Birth
        if (frameCount % UInt64(BirthDuration) == 0) {
            csEnc.setComputePipelineState(self.resource.psoBirth!)
            csEnc.dispatchThreadgroups(MTLSizeMake((BirthCountPerInstance + 63) / 64, 1, 1), threadsPerThreadgroup: numThreads)
        }
        // IndirectArgs
        csEnc.setComputePipelineState(self.resource.psoGenIndirectArgs!)
        csEnc.dispatchThreadgroups(MTLSizeMake(1, 1, 1), threadsPerThreadgroup: numThreads)
        // Update
        csEnc.setComputePipelineState(self.resource.psoUpdate!)
        csEnc.dispatchThreadgroups(indirectBuffer: self.resource.indirectArgsCSBuf, indirectBufferOffset: 0, threadsPerThreadgroup: numThreads)
        csEnc.endEncoding()
        
        let bltEnc2 = cmdBuf.makeBlitCommandEncoder()!
        bltEnc2.label = "Counter copy"
        // Copy draw indirect args
        bltEnc2.copy(from: self.resource.countBuf[1], sourceOffset: 0, to: self.resource.indirectArgsHeightBuf, destinationOffset: 4, size: 4)
        // Copy count
        bltEnc2.copy(from: self.resource.countBuf[1], sourceOffset: 0, to: self.resource.countBuf[0], destinationOffset: 0, size: 4)
        bltEnc2.endEncoding()
        
        let passDescHeight = MTLRenderPassDescriptor()
        passDescHeight.colorAttachments[0].texture = self.resource.heightMap
        passDescHeight.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDescHeight.colorAttachments[0].loadAction = .clear
        passDescHeight.colorAttachments[0].storeAction = .store
        let enc2 = cmdBuf.makeRenderCommandEncoder(descriptor: passDescHeight)!
        enc2.label = "Height Pass"
        enc2.setRenderPipelineState(self.resource.psoHeight!)
        enc2.setCullMode(.back)
        enc2.setVertexBuffer(self.resource.particleBuf[Int(frameCount + 1) & 1], offset: 0, index: 0)
        enc2.setVertexBytes([ParticleSize], length: 4, index: 1)
        enc2.setVertexBuffer(self.resource.cbParticle[frameIndex], offset: 0, index: 2)
        enc2.drawPrimitives(type: .triangleStrip, indirectBuffer: self.resource.indirectArgsHeightBuf, indirectBufferOffset: 0)
        enc2.endEncoding()
        
        let passDescNormal = MTLRenderPassDescriptor()
        passDescNormal.colorAttachments[0].texture = self.resource.normalMap
        passDescNormal.colorAttachments[0].loadAction = .dontCare
        passDescNormal.colorAttachments[0].storeAction = .store
        let encN = cmdBuf.makeRenderCommandEncoder(descriptor: passDescNormal)!
        encN.label = "Normal Pass"
        encN.setRenderPipelineState(self.resource.psoNormal!)
        encN.setCullMode(.back)
        encN.setFragmentTexture(self.resource.heightMap, index: 0)
        encN.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 3)
        encN.endEncoding()
        
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
        enc.setRenderPipelineState(self.resource.psoDraw!)
        enc.setCullMode(.back)
        //enc.setTriangleFillMode(.lines)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBytes([simd_float4(-2.4, -0.5, -2.4, 0), simd_float4(2.4, -0.5, 2.4, 0)], length: 32, index: 0)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        enc.setVertexTexture(self.resource.heightMap, index: 0)
        enc.setFragmentTexture(self.resource.normalMap, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * NumQuads * NumQuads, indexType: .uint16, indexBuffer: self.resource.ibDraw, indexBufferOffset: 0)
        enc.endEncoding()
        
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
