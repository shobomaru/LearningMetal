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
    var vb: MTLBuffer
    var ib: MTLBuffer
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var zTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var bvh: MTLAccelerationStructure?
    var bvhPlane: MTLAccelerationStructure?
    var bvhTlas: MTLAccelerationStructure?
    var tlasDescBuf: MTLBuffer?
    //var bvhScratch: MTLBuffer
    var isBvhOK = false
    init(device: MTLDevice, queue: MTLCommandQueue, alert: (String) -> Void) {
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
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        // Create acceleration structures and shared scratch buffer
        
        // Sphere BLAS
        let asGeomDesc = MTLAccelerationStructureTriangleGeometryDescriptor()
        asGeomDesc.vertexBuffer = self.vb
        asGeomDesc.vertexFormat = .float3
        asGeomDesc.vertexStride = MemoryLayout<VertexElement>.size
        asGeomDesc.vertexBufferOffset = 0
        asGeomDesc.indexType = .uint16
        asGeomDesc.indexBuffer = self.ib
        asGeomDesc.indexBufferOffset = 0
        asGeomDesc.triangleCount = 6 * SPHERE_SLICES * SPHERE_STACKS / 3
        asGeomDesc.transformationMatrixBuffer = nil
        asGeomDesc.transformationMatrixBufferOffset = 0
        let asDesc = MTLPrimitiveAccelerationStructureDescriptor()
        asDesc.geometryDescriptors = [asGeomDesc]
        //asDesc.usage = [.extendedLimits]
        let asSizes = device.accelerationStructureSizes(descriptor: asDesc)
        print("Sphere AS Size: \(asSizes.accelerationStructureSize / 1024) KiB, Scratch: \(asSizes.buildScratchBufferSize / 1024) KiB")
        self.bvh = device.makeAccelerationStructure(size: asSizes.accelerationStructureSize)
        guard let _ = self.bvh else { return }
        self.bvh!.label = "BLAS Sphere"
        
        // Plane BLAS
        let asPlaneGeomDesc = asGeomDesc.copy() as! MTLAccelerationStructureTriangleGeometryDescriptor
        asPlaneGeomDesc.vertexBuffer = self.vbPlane
        asPlaneGeomDesc.indexBuffer = self.ibPlane
        asPlaneGeomDesc.triangleCount = 6 / 3
        let asPlaneDesc = asDesc.copy() as! MTLPrimitiveAccelerationStructureDescriptor
        asPlaneDesc.geometryDescriptors = [asPlaneGeomDesc]
        let asPlaneSizes = device.accelerationStructureSizes(descriptor: asPlaneDesc)
        print("Plane AS Size: \(asPlaneSizes.accelerationStructureSize / 1024) KiB, Scratch: \(asPlaneSizes.buildScratchBufferSize / 1024) KiB")
        self.bvhPlane = device.makeAccelerationStructure(descriptor: asPlaneDesc)
        guard let _ = self.bvhPlane else { return }
        self.bvhPlane!.label = "BLAS Plane"
        
        // Instance list
        // The structure layout is different from DirectX Raytracing
        // struct MTLAccelerationStructureInstanceDescriptor
        // {
        //   packed_float3 transformationMatrix[4];
        //   uint flags;
        //   uint mask;
        //   uint intersectionFunctionTableOffset;
        //   uint accelerationStructureIndex;
        // };
        // Note that first version of Metal raytracing automatically calculate instance_id
        // If you want a user defined instance ID such as D3D12_RAYTRACING_INSTANCE_DESC,
        // you can use MTLAccelerationStructureUserIDInstanceDescriptor and user_instance_id (Metal 2.4+)
        let matIdentity = MTLPackedFloat4x3.init(columns: (MTLPackedFloat3Make(1, 0, 0),
                                                          MTLPackedFloat3Make(0, 1, 0),
                                                          MTLPackedFloat3Make(0, 0, 1),
                                                          MTLPackedFloat3Make(0, 0, 0)))
        var asInstanceDesc: [MTLAccelerationStructureInstanceDescriptor] = Array(repeating: MTLAccelerationStructureInstanceDescriptor(), count: 2)
        asInstanceDesc[0].accelerationStructureIndex = 0
        asInstanceDesc[0].transformationMatrix = matIdentity
        asInstanceDesc[0].mask = 0xFF // Non extended limit AS can use 8bit mask
        asInstanceDesc[0].options = [.opaque, .disableTriangleCulling] // Fastest options
        //asInstanceDesc[0].userID = 0xCAFE;
        asInstanceDesc[1].accelerationStructureIndex = 1
        asInstanceDesc[1].transformationMatrix = matIdentity
        asInstanceDesc[1].mask = 0xFF
        asInstanceDesc[1].options = [.opaque, .disableTriangleCulling]
        //asInstanceDesc[1].userID = 0xBABE;
        self.tlasDescBuf = device.makeBuffer(bytes: asInstanceDesc, length: MemoryLayout.size(ofValue: asInstanceDesc[0]) * asInstanceDesc.count, options: [.cpuCacheModeWriteCombined])!
        self.tlasDescBuf!.label = "AS Instance descriptor list"
        
        // TLAS
        let asTlasDesc = MTLInstanceAccelerationStructureDescriptor()
        asTlasDesc.instanceDescriptorType = .default //.userID
        asTlasDesc.instancedAccelerationStructures = [self.bvh!, self.bvhPlane!]
        asTlasDesc.instanceCount = asInstanceDesc.count
        asTlasDesc.instanceDescriptorBuffer = self.tlasDescBuf!
        asTlasDesc.instanceDescriptorBufferOffset = 0
        asTlasDesc.instanceDescriptorStride = MemoryLayout.size(ofValue: asInstanceDesc[0])
        
        let asTlasSizes = device.accelerationStructureSizes(descriptor: asTlasDesc)
        print("TLAS Size: \(asTlasSizes.accelerationStructureSize / 1024) KiB, Scratch: \(asTlasSizes.buildScratchBufferSize / 1024) KiB")
        self.bvhTlas = device.makeAccelerationStructure(size: asTlasSizes.accelerationStructureSize)
        guard let _ = self.bvhTlas else { return }
        self.bvhTlas!.label = "TLAS :)"
        
        // AS Scratch
        let maxScratchSize = max(asSizes.buildScratchBufferSize, max(asPlaneSizes.buildScratchBufferSize, asTlasSizes.buildScratchBufferSize))
        let bvhScratch = device.makeBuffer(length: maxScratchSize, options: [.storageModePrivate])!
        
        // Build acceleration structures
        let cmdBuf = queue.makeCommandBuffer()!
        cmdBuf.label = "AS command buffer"
        let enc = cmdBuf.makeAccelerationStructureCommandEncoder()!
        enc.label = "AS command encoder 1"
        enc.build(accelerationStructure: self.bvh!, descriptor: asDesc, scratchBuffer: bvhScratch, scratchBufferOffset: 0)
        enc.endEncoding()
        // GPU fence for waiting the scratch buffer free
        // MTLAccelerationStructureCommandEncoder doesn't have memoryBarrier()?
        let enc1 = cmdBuf.makeAccelerationStructureCommandEncoder()!
        enc1.label = "AS command encoder 2"
        enc1.build(accelerationStructure: self.bvhPlane!, descriptor: asPlaneDesc, scratchBuffer: bvhScratch, scratchBufferOffset: 0)
        enc1.endEncoding()
        // GPU fence
        let enc2 = cmdBuf.makeAccelerationStructureCommandEncoder()!
        enc2.label = "AS command encoder 3"
        enc2.build(accelerationStructure: self.bvhTlas!, descriptor: asTlasDesc, scratchBuffer: bvhScratch, scratchBufferOffset: 0)
        enc2.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        if let err = cmdBuf.error {
            print(err.localizedDescription)
            alert(String(describing: err))
        }
        else if cmdBuf.status == .completed {
            self.isBvhOK = true
        }
        else {
            alert("Invalid AS build status: \(cmdBuf.status)")
        }
        // Now the temporary scratch buffer can be freed if you want to use unretained command buffer
    }
    func available() -> Bool {
        self.pso != nil && self.isBvhOK
    }
}

let SPHERE_STACKS: Int = 50
let SPHERE_SLICES: Int = 60

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
        //#if !targetEnvironment(simulator)
        if !device.supportsRaytracing || !device.supportsRaytracingFromRender {
            parent.enqueueAlert("Your GPU does not support raytracing for RenderCommandEncoder")
        }
        //#endif
        self.cmdQueue = self.device.makeCommandQueue()!
        self.resource = MyResource(device: device, queue: self.cmdQueue, alert: { (s: String) -> Void  in
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
        
        let deg = 360.0 * Float(self.frameCount) / 240.0
        let rad = deg * Float.pi / 180.0
        let virtualShadowPos = simd_float3(sin(rad) * 10.0, 5.0, cos(rad) * 10.0)
        let lightDir = normalize(virtualShadowPos)
        
        let viewMat = MathUtil.lookAt(pos: self.scene.cameraPos, target: self.scene.cameraTarget, up: self.scene.cameraUp)
        let projMat = MathUtil.perspective(fov: self.scene.cameraFov, aspect: Float(view.drawableSize.width / view.drawableSize.height), near: self.scene.cameraFar, far: self.scene.cameraNear)
        
        struct CBScene {
            let viewProj: float4x4
            let lightDir: MTLPackedFloat3
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj, lightDir: MTLPackedFloat3Make(lightDir.x, lightDir.y, lightDir.z))
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
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        enc.setFragmentAccelerationStructure(self.resource.bvhTlas, bufferIndex: 0) // TLAS
        //enc.setFragmentAccelerationStructure(self.resource.bvh, bufferIndex: 0) // Also BLAS can trace directly!
        enc.setFragmentBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        
        // DON'T FORGET THIS!! YOU WILL LOSE ANY RAY INTERSECTIONS, AND SHOW CORRECTLY ONLY IN THE FRAME DEBUGGER!!
        // Note that Metal API makes resident only the TLAS, not the BLAS referenced by that
        enc.useResources([self.resource.bvh!, self.resource.bvhPlane!], usage: .read, stages: .fragment)
        
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.setVertexBuffer(self.resource.vbPlane, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ibPlane, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}

