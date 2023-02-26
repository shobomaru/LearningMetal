import SwiftUI
import MetalKit
import simd

let InstanceCount = 200

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

let MaxVerticesPerMeshlet = 256
let NumPrimiticesPerMeshlet = 84

struct Meshlet {
    var primitiveCount: UInt32 = 0
    var positions = [MTLPackedFloat3](repeating: MTLPackedFloat3Make(0 / 0.0, 0, 0), count: MaxVerticesPerMeshlet)
    var normals = [MTLPackedFloat3](repeating: MTLPackedFloat3Make(0 / 0.0, 0, 0), count: MaxVerticesPerMeshlet)
    var indices = [UInt16](repeating: 0xFFFF, count: NumPrimiticesPerMeshlet * 3)
    init() {
    }
    func convertGpuData() -> [UInt32] {
        assert(primitiveCount > 0)
        let meshletDataSize = MemoryLayout<UInt32>.size
            + MemoryLayout<MTLPackedFloat3>.size * MaxVerticesPerMeshlet
            + MemoryLayout<MTLPackedFloat3>.size * MaxVerticesPerMeshlet
            + MemoryLayout<UInt16>.size * (NumPrimiticesPerMeshlet * 3)
            + MemoryLayout<UInt32>.size
        var data = [UInt32](repeating: 0, count: (meshletDataSize / MemoryLayout<UInt32>.size))
        data[0] = self.primitiveCount
        var offset = 1
        for i in 0..<self.positions.count {
            data[offset + i * 3] = self.positions[i].x.bitPattern
            data[offset + i * 3 + 1] = self.positions[i].y.bitPattern
            data[offset + i * 3 + 2] = self.positions[i].z.bitPattern
        }
        offset += 3 * MaxVerticesPerMeshlet
        for i in 0..<self.normals.count {
            data[offset + i * 3] = self.normals[i].x.bitPattern
            data[offset + i * 3 + 1] = self.normals[i].y.bitPattern
            data[offset + i * 3 + 2] = self.normals[i].z.bitPattern
        }
        offset += 3 * MaxVerticesPerMeshlet
        for i in 0..<Int(self.primitiveCount) {
            if (i % 2) == 0 {
                data[offset + 3 * (i / 2)] = UInt32(self.indices[3 * i + 1]) << 16 | UInt32(self.indices[3 * i])
                data[offset + 3 * (i / 2) + 1] = UInt32(self.indices[3 * i + 2])
            }
            else {
                data[offset + 3 * (i / 2) + 1] |= UInt32(self.indices[3 * i]) << 16
                data[offset + 3 * (i / 2) + 2] = UInt32(self.indices[3 * i + 2]) << 16 | UInt32(self.indices[3 * i + 1])
            }
        }
        assert(NumPrimiticesPerMeshlet % 2 == 0) // TODO:
        offset += (NumPrimiticesPerMeshlet / 2) * 3
        data[offset] = 0x10BECEE1
        offset += 1
        return data
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
    var psoMS: MTLRenderPipelineState?
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var meshlet: MTLBuffer
    var meshletCount: Int
    var cbScene: [MTLBuffer]
    var zTex: MTLTexture?
    var depthState: MTLDepthStencilState
    var instanceMat: MTLBuffer
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let ms = lib.makeFunction(name: "sceneMS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        let psoDesc = MTLMeshRenderPipelineDescriptor()
        psoDesc.meshFunction = ms
        psoDesc.fragmentFunction = fs
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Scene PSO"
        do {
            self.psoMS = try device.makeRenderPipelineState(descriptor: psoDesc, options: []).0
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
        
        let meshletArray = MyResource.generateMeshlet(vertices: vbData, indices: ibData)
        var meshletData = [UInt32]()
        for i in meshletArray {
            let data = i.convertGpuData()
            meshletData += data
        }
        self.meshlet = device.makeBuffer(bytes: meshletData, length: (MemoryLayout<UInt32>.size * meshletData.count), options: [.cpuCacheModeWriteCombined])!
        self.meshletCount = meshletArray.count
        
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
        
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        // We use reproducible numbers for testability
        struct FixedRNG : RandomNumberGenerator {
            var stat: UInt32 = 0xFACECEA1
            mutating func next() -> UInt64 {
                self.stat = (48271 &* stat) % UInt32.max
                let t = self.stat
                self.stat = (48271 &* stat) % UInt32.max
                return (UInt64(t) << 32 | UInt64(self.stat))
            }
        }
        var rng = FixedRNG()
        
        var instanceMat = [float3x4](repeating: float3x4(), count: InstanceCount)
        instanceMat = instanceMat.map {_ in
            let tx = Float.random(in: -5.5...5.5, using: &rng)
            let ty = Float.random(in: -5.5...5.5, using: &rng)
            let tz = Float.random(in: -5.5...5.5, using: &rng)
            let sx = Float.random(in: 0.20...0.30, using: &rng)
            let sy = Float.random(in: 0.20...0.30, using: &rng)
            let sz = Float.random(in: 0.20...0.30, using: &rng)
            return float3x4(columns: (SIMD4(sx, 0, 0, tx),
                                  SIMD4(0, sy, 0, ty),
                                  SIMD4(0, 0, sz, tz)))
        }
        self.instanceMat = device.makeBuffer(bytes: instanceMat, length: MemoryLayout<float3x4>.size * instanceMat.count, options: .cpuCacheModeWriteCombined)!
    }
    private static func generateMeshlet(vertices: [VertexElement], indices: [QuadIndexList]) -> [Meshlet] {
        var meshlets = [Meshlet]()
        var inQuadCount = 0
        while inQuadCount < indices.count {
            // Load indices
            let quadCount = min((NumPrimiticesPerMeshlet / 2), (indices.count - inQuadCount))
            var idx = [UInt16](repeating: 0, count: (6 * quadCount))
            for i in 0..<quadCount {
                idx[6 * i] = indices[inQuadCount + i].v0
                idx[6 * i + 1] = indices[inQuadCount + i].v1
                idx[6 * i + 2] = indices[inQuadCount + i].v2
                idx[6 * i + 3] = indices[inQuadCount + i].v3
                idx[6 * i + 4] = indices[inQuadCount + i].v4
                idx[6 * i + 5] = indices[inQuadCount + i].v5
            }
            inQuadCount += quadCount
            // Convert original indices to zero based indices
            let minIdx = idx[0..<(6 * quadCount)].min()!
            let idx2 = idx.map { $0 - minIdx }
            // TODO: Index compaction
            assert(idx2.max()! < MaxVerticesPerMeshlet)
            var ms = Meshlet()
            ms.indices[0..<idx2.count] = idx2[0..<idx2.count]
            // Load vertices
            for i in 0..<idx2.count {
                let v = vertices[Int(idx[i])];
                ms.positions[Int(idx2[i])] = v.position
                ms.normals[Int(idx2[i])] = v.normal
            }
            ms.primitiveCount = UInt32(quadCount * 2)
            meshlets.append(ms)
        }
        return meshlets
    }
    func available() -> Bool {
        self.psoMS != nil
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
            parent.enqueueAlert("Mesh shader not supported")
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
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.psoMS!)
        enc.setCullMode(.back)
        enc.setTriangleFillMode(.fill)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setMeshBuffer(self.resource.meshlet, offset: 0, index: 0)
        enc.setMeshBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 1)
        enc.setMeshBuffer(self.resource.instanceMat, offset: 0, index: 2)
        let numThreads = MTLSizeMake(256, 1, 1)
        enc.drawMeshThreadgroups(MTLSizeMake(3/*meshlet per instance*/, InstanceCount, 1), threadsPerObjectThreadgroup: numThreads, threadsPerMeshThreadgroup: numThreads)
        enc.endEncoding()
        //enc.setVertexBuffer(self.resource.vbPlane, offset: 0, index: 0)
        //enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ibPlane, indexBufferOffset: 0, instanceCount: 1)
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
