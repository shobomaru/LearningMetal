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

class MyResource {
    var pso: MTLRenderPipelineState?
    var psoSWRaster: MTLComputePipelineState?
    //var psoSWResolve: MTLRenderPipelineState?
    var psoCopyDepth: MTLRenderPipelineState?
    var psoVerify : MTLRenderPipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var cbScene: [MTLBuffer]
    var zTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var depthStateDisable : MTLDepthStencilState
    var depthStateEqual : MTLDepthStencilState
    var rasterTex: MTLTexture?
    var fence: MTLFence
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
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
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
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
        
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        var dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        // Sofware Rasterizer
        
        /*guard let vsResolve = lib.makeFunction(name: "resolveVS") else { fatalError() }
        guard let fsResolve = lib.makeFunction(name: "resolveFS") else { fatalError() }
        psoDesc.vertexFunction = vsResolve
        psoDesc.fragmentFunction = fsResolve
        psoDesc.depthAttachmentPixelFormat = .invalid
        psoDesc.label = "Resolve PSO"
        do {
            self.psoSWResolve = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }*/
        
        guard let cs = lib.makeFunction(name: "softwareRaster") else { fatalError() }
        let psoDescCS = MTLComputePipelineDescriptor()
        psoDescCS.computeFunction = cs
        psoDescCS.label = "SoftwareRaster CS"
        do {
            self.psoSWRaster = try device.makeComputePipelineState(descriptor: psoDescCS, options: MTLPipelineOption(rawValue: 0), reflection: nil)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        
        dsDesc = MTLDepthStencilDescriptor()
        self.depthStateDisable = device.makeDepthStencilState(descriptor: dsDesc)!
        
        self.fence = device.makeFence()!
        
        // Visualization for SW raster
        
        guard let fsVerify = lib.makeFunction(name: "verifyFS") else { fatalError() }
        psoDesc.fragmentFunction = fsVerify
        psoDesc.label = "Verify PSO"
        do {
            self.psoVerify = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        guard let vsFullscreen = lib.makeFunction(name: "fullscreenVS") else { fatalError() }
        guard let fsCopyDepth = lib.makeFunction(name: "copyDepthFS") else { fatalError() }
        psoDesc.vertexFunction = vsFullscreen
        psoDesc.fragmentFunction = fsCopyDepth
        psoDesc.vertexDescriptor = MTLVertexDescriptor() // reset veretex descriptor
        psoDesc.label = "CopyDepth PSO"
        do {
            self.psoCopyDepth = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        
        dsDesc.depthCompareFunction = .always
        dsDesc.isDepthWriteEnabled = true
        self.depthStateEqual = device.makeDepthStencilState(descriptor: dsDesc)!
    }
    func available() -> Bool {
        self.pso != nil
    }
}

//let SPHERE_STACKS: Int = 40
//let SPHERE_SLICES: Int = 96
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
        self.cmdQueue = self.device.makeCommandQueue()!
        self.resource = MyResource(device: device, alert: { (s: String) -> Void  in
            parent.enqueueAlert(s)
        })
        self.scene = MyScene()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        var texDesc = MTLTextureDescriptor()
        texDesc.width = Int(size.width)
        texDesc.height = Int(size.height)
        texDesc.textureType = .type2D
        texDesc.storageMode = .private //.memoryless
        texDesc.pixelFormat = .depth32Float
        texDesc.usage = [.renderTarget]
        self.resource.zTex = self.device.makeTexture(descriptor: texDesc)
        
        // Apple M1 / A15 does not support RG32 atomic texture
        texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: Int(size.width), height: Int(size.height), mipmapped: false)
        texDesc.usage = [.shaderRead, .shaderWrite, .shaderAtomic, .renderTarget]
        self.resource.rasterTex = self.device.makeTexture(descriptor: texDesc)!
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
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj)
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.resource.zTex
        /*
        // HW raster
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        //enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        */
        
        // SW raster
        let csEnc = cmdBuf.makeComputeCommandEncoder(dispatchType: .serial)!
        csEnc.setBuffer(self.resource.vb, offset: 0, index: 0)
        csEnc.setBuffer(self.resource.ib, offset: 0, index: 1)
        csEnc.setBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        csEnc.setTexture(self.resource.rasterTex!, index: 0)
        csEnc.setComputePipelineState(self.resource.psoSWRaster!)
        csEnc.dispatchThreads(MTLSizeMake(6 * SPHERE_SLICES * SPHERE_STACKS / 3, 1, 1), threadsPerThreadgroup: MTLSizeMake(32, 1, 1))
        //csEnc.dispatchThreads(MTLSizeMake(2, 1, 1), threadsPerThreadgroup: MTLSizeMake(32, 1, 1))
        csEnc.updateFence(self.resource.fence)
        csEnc.endEncoding()
        // Copy depth
        //passDesc.depthAttachment.texture = nil
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        // Atomic operations does not wait subsequence texture read!!
        enc.waitForFence(self.resource.fence, before: .fragment)
        enc.label = "CopyDepth and Verify Pass"
        enc.setRenderPipelineState(self.resource.psoCopyDepth!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setFragmentTexture(self.resource.rasterTex!, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // Verify
        enc.setRenderPipelineState(self.resource.psoVerify!)
        enc.setDepthStencilState(self.resource.depthStateEqual)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        //enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        let passClear = MTLRenderPassDescriptor()
        passClear.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        passClear.colorAttachments[0].texture = self.resource.rasterTex!
        passClear.colorAttachments[0].loadAction = .clear
        passClear.colorAttachments[0].storeAction = .store
        let encClear = cmdBuf.makeRenderCommandEncoder(descriptor: passClear)!
        encClear.endEncoding()
        
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}

