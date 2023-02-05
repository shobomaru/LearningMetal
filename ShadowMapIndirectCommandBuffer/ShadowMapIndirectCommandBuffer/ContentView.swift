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
    static func orthographic(width: Float, height: Float, near: Float, far: Float) -> float4x4 {
        return float4x4.init(columns: (SIMD4(2.0 / width, 0, 0, 0),
                                SIMD4(0, 2.0 / height, 0, 0),
                                SIMD4(0, 0, 1.0 / (far - near), 0),
                                SIMD4(0, 0, -near / (far - near), 1)))
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
    var cameraPos = simd_float3(0, 4, -4)
    var cameraTarget = simd_float3(0, 0, 0)
    var cameraUp = simd_float3(0, 1, 0)
    var cameraFov: Float = 45.0 * Float.pi / 180.0
    var cameraNear: Float = 0.01
    var cameraFar: Float = 100.0
    var lightDir = simd_float3(0, 1, 0)
    var lightShadowPos = simd_float3(0, 5, 0)
    var lightShadowViewSize: Float = 10.0
    var lightShadowNear: Float = 0.01
    var lightShadowFar: Float = 30.0
}

struct SceneMetalArgs {
    var cbScene: UInt64;
    var shadowMap: MTLResourceID;
    var shadowSS: MTLResourceID;
    init(cbScene: UInt64, shadowMap: MTLResourceID, shadowSS: MTLResourceID) {
        self.cbScene = cbScene
        self.shadowMap = shadowMap
        self.shadowSS = shadowSS
    }
}

class MyResource {
    static let ShadowSize: Int = 512
    var pso: MTLRenderPipelineState?
    var psoShadow: MTLRenderPipelineState?
    var psoICB: MTLComputePipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var cbShadow: [MTLBuffer]
    var zTex: MTLTexture?
    var shadowTex: MTLTexture
    var depthState: MTLDepthStencilState
    var shadowSS: MTLSamplerState
    var argScene: [MTLBuffer]
    var icbScene: [MTLIndirectCommandBuffer]
    var icbArgScene: [MTLBuffer]
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        guard let vsShadow = lib.makeFunction(name: "shadowVS") else { fatalError() }
        guard let fsShadow = lib.makeFunction(name: "shadowFS") else { fatalError() }
        guard let csIcb = lib.makeFunction(name: "sceneIndirectCommandBuffer") else { fatalError() }
        var psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[0].offset = 0;
        vd.attributes[1].format = .float3
        vd.attributes[1].bufferIndex = 0;
        vd.attributes[1].offset = MemoryLayout<MTLPackedFloat3>.size
        vd.layouts[0].stride = MemoryLayout<VertexElement>.stride
        psoDesc.vertexDescriptor = vd
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.supportIndirectCommandBuffers = true
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vsShadow
        psoDesc.fragmentFunction = fsShadow
        psoDesc.vertexDescriptor = vd
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.supportIndirectCommandBuffers = true
        psoDesc.label = "Shadow PSO"
        do {
            self.psoShadow = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        do {
            self.psoICB = try device.makeComputePipelineState(function: csIcb)
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
                vbData.append(VertexElement(pos, norm))
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
            VertexElement(MTLPackedFloat3Make(-1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
            VertexElement(MTLPackedFloat3Make( 1.0, -1.0,  1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
            VertexElement(MTLPackedFloat3Make(-1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
            VertexElement(MTLPackedFloat3Make( 1.0, -1.0, -1.0), MTLPackedFloat3Make(0.0, 1.0, 0.0)),
        ]
        self.vbPlane = device.makeBuffer(bytes: vbPlaneData, length: MemoryLayout<VertexElement>.size * vbPlaneData.count, options: .cpuCacheModeWriteCombined)!
        let ibPlaneData: [QuadIndexList] = [
            QuadIndexList(0, 1, 2, 2, 1, 3)
        ]
        self.ibPlane = device.makeBuffer(bytes: ibPlaneData, length: MemoryLayout<QuadIndexList>.size * ibPlaneData.count, options: .cpuCacheModeWriteCombined)!
        
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 4096, options: .cpuCacheModeWriteCombined)!, count: 2)
        self.cbShadow = [MTLBuffer](repeating: device.makeBuffer(length: 4096, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        let texDesc = MTLTextureDescriptor()
        texDesc.width = MyResource.ShadowSize
        texDesc.height = MyResource.ShadowSize
        texDesc.textureType = .type2D
        texDesc.storageMode = .private
        texDesc.pixelFormat = .depth32Float
        texDesc.usage = [.renderTarget, .shaderRead]
        self.shadowTex = device.makeTexture(descriptor: texDesc)!
        
        let ssDesc = MTLSamplerDescriptor()
        ssDesc.minFilter = .linear
        ssDesc.magFilter = .linear
        ssDesc.compareFunction = .lessEqual
        ssDesc.supportArgumentBuffers = true // THIS IS VERY IMPORTANT!!! IF YOU FORGET, WILL GET A GPU FAULT!!!
        self.shadowSS = device.makeSamplerState(descriptor: ssDesc)!
        
        self.argScene = [MTLBuffer](repeating: device.makeBuffer(length: MemoryLayout<SceneMetalArgs>.size, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let icbSceneDesc = MTLIndirectCommandBufferDescriptor()
        icbSceneDesc.commandTypes = .drawIndexed
        icbSceneDesc.inheritBuffers = false
        icbSceneDesc.inheritPipelineState = true // iOS 13.0+ can disable this option
        icbSceneDesc.maxVertexBufferBindCount = 10
        icbSceneDesc.maxFragmentBufferBindCount = 10
        self.icbScene = [MTLIndirectCommandBuffer](repeating: device.makeIndirectCommandBuffer(descriptor: icbSceneDesc, maxCommandCount: 10)!, count: 2)
        
        self.icbArgScene = [MTLBuffer](repeating: device.makeBuffer(length: MemoryLayout<MTLResourceID>.size * 2, options: .cpuCacheModeWriteCombined)!, count: 2)
        // Set arguments beforehand
        for i in 0..<self.icbArgScene.count {
            #if false
            // Metal2
            let ae = csIcb.makeArgumentEncoder(bufferIndex: 0)
            ae.setArgumentBuffer(self.icbArgScene[i], offset: 0) // destination
            ae.setIndirectCommandBuffer(self.icbScene[i], index: 0)
            ae.setRenderPipelineState(self.pso, index: 1)
            #else
            // Metal3
            struct ICBContainer {
                var icb : MTLResourceID
                var pso : MTLResourceID
            }
            var arg = ICBContainer(icb: self.icbScene[i].gpuResourceID, pso: self.pso!.gpuResourceID)
            self.icbArgScene[i].contents().copyMemory(from: withUnsafePointer(to: &arg) { UnsafeRawPointer($0) }, byteCount: MemoryLayout<ICBContainer>.size)
            #endif
        }
    }
    func available() -> Bool {
        self.pso != nil && self.psoShadow != nil && self.psoICB != nil
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
        if device.argumentBuffersSupport == .tier1 {
            parent.enqueueAlert("ArgumentBufferSupport Tier2 needed")
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
        let shadowViewMat = MathUtil.lookAt(pos: self.scene.lightShadowPos, target: self.scene.lightShadowPos - self.scene.lightDir, up: simd_float3(0, 0, 1))
        let shadowProjMat = MathUtil.orthographic(width: self.scene.lightShadowViewSize, height: self.scene.lightShadowViewSize, near: self.scene.lightShadowFar, far: self.scene.lightShadowNear)
        
        struct CBScene {
            let viewProj: float4x4
            let shadowViewProj: float4x4
        };
        let viewProj = viewMat.transpose * projMat.transpose
        let shadowViewProj = shadowViewMat.transpose * shadowProjMat.transpose
        var sceneData = CBScene(viewProj: viewProj, shadowViewProj: shadowViewProj)
        var shadowData = CBScene(viewProj: shadowViewProj, shadowViewProj: float4x4())
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        self.resource.cbShadow[frameIndex].contents().copyMemory(from: &shadowData, byteCount: MemoryLayout<CBScene>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        
        // Encode ICB with GPU
        
        var argScene = SceneMetalArgs(cbScene: self.resource.cbScene[frameIndex].gpuAddress, shadowMap: self.resource.shadowTex.gpuResourceID, shadowSS: self.resource.shadowSS.gpuResourceID)
        self.resource.argScene[frameIndex].contents().copyMemory(from: withUnsafePointer(to: &argScene) { UnsafeRawPointer($0) }, byteCount: MemoryLayout<SceneMetalArgs>.size)
        
        let icb = self.resource.icbScene[frameIndex]
        let icbSize = 2 // TODO: you may want to count actual draw call
        
        // You can reset ICB using CPU
        var blitEnc: MTLBlitCommandEncoder;
        #if true
        icb.reset(0..<icbSize)
        // or GPU
        #else
        blitEnc = cmdBuf.makeBlitCommandEncoder()!
        blitEnc.label = "Clear GpuCommandBuffer"
        blitEnc.resetCommandsInBuffer(icb, range: 0..<icbSize)
        blitEnc.endEncoding()
        #endif
        
        let csEnc = cmdBuf.makeComputeCommandEncoder()!
        csEnc.label = "GpuCommandBuffer"
        csEnc.useResource(icb, usage: .write) // Exists in the argument buffer
        csEnc.setComputePipelineState(self.resource.psoICB!)
        csEnc.setBuffer(self.resource.icbArgScene[frameIndex], offset: 0, index: 0)
        csEnc.setBytes([self.resource.vb.gpuAddress, self.resource.vbPlane.gpuAddress], length: MemoryLayout<UInt64>.size * 2, index: 1)
        csEnc.setBytes([self.resource.ib.gpuAddress, self.resource.ibPlane.gpuAddress], length: MemoryLayout<UInt64>.size * 2, index: 2)
        csEnc.setBytes([UInt32(6 * SPHERE_SLICES * SPHERE_STACKS), UInt32(6)], length: MemoryLayout<UInt32>.size * 2, index: 3)
        csEnc.setBytes([self.resource.argScene[frameIndex].gpuAddress], length: MemoryLayout<UInt64>.size, index: 4)
        csEnc.dispatchThreads(MTLSizeMake(icbSize, 1, 1), threadsPerThreadgroup: MTLSizeMake(1, 1, 1))
        csEnc.endEncoding()
        
        blitEnc = cmdBuf.makeBlitCommandEncoder()!
        blitEnc.label = "Optimize GpuCommand Buffer"
        blitEnc.optimizeIndirectCommandBuffer(icb, range: 0..<icbSize)
        blitEnc.endEncoding()
        
        // Draw
        
        var passDesc = MTLRenderPassDescriptor()
        passDesc.depthAttachment.texture = self.resource.shadowTex
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .store
        var enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Shadow Pass"
        enc.setRenderPipelineState(self.resource.psoShadow!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.cbShadow[frameIndex], offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.setVertexBuffer(self.resource.vbPlane, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ibPlane, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        
        passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.resource.zTex
        enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        // declare using
        // DO NOT FORGET ALL RESOURCE BOUNDS, OR YOU WILL GET INVALID RESOURCES ONLY IN THE METAL GPU DEBUGGER!!!
        enc.useResources([self.resource.cbScene[frameIndex], self.resource.shadowTex, self.resource.argScene[frameIndex]], usage: .read, stages: .vertex)
        //enc.useResources([self.resource.cbScene[frameIndex], self.resource.shadowTex], usage: .read, stages: .fragment) // need this?
        // No bindings here, already done by GPU
        enc.executeCommandsInBuffer(icb, range: 0..<icbSize)
        enc.endEncoding()
        
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self, weak cmdBuf] _ in
            self?.sema.signal()
            if cmdBuf?.status == .error {
                self?.parent.enqueueAlert("The command buffer has an error: \(String(describing: cmdBuf?.status))")
            }
        }
        cmdBuf.commit()
    }
}

