import SwiftUI
import MetalKit
import simd

struct ContentView: UIViewRepresentable {
    typealias Coordinator = Metal
    func makeCoordinator() -> Coordinator {
        Metal(self)
    }
    func makeUIView(context: UIViewRepresentableContext<ContentView>) -> MTKView {
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct VertexElement {
    var position: MTLPackedFloat3
    var normal: MTLPackedFloat3
};

struct QuadIndexList {
    var v0: UInt16
    var v1: UInt16
    var v2: UInt16
    var v3: UInt16
    var v4: UInt16
    var v5: UInt16
};

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    var pso: MTLRenderPipelineState
    var vb: MTLBuffer
    var ib: MTLBuffer
    var cbScene: [MTLBuffer]
    init(_ parent: ContentView) {
        self.parent = parent
        self.device = MTLCreateSystemDefaultDevice()!
        self.cmdQueue = self.device.makeCommandQueue()!
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
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            fatalError()
        }
        let vbData = [VertexElement(position: MTLPackedFloat3Make(0.5, 0.8, 1.0), normal: MTLPackedFloat3Make(0.1, 0.2, 0.3)),
                      VertexElement(position: MTLPackedFloat3Make(0.8, 0.2, 1.0), normal: MTLPackedFloat3Make(0.4, 0.5, 0.6)),
                      VertexElement(position: MTLPackedFloat3Make(0.2, 0.2, 1.0), normal: MTLPackedFloat3Make(0.7, 0.8, 0.9))]
        self.vb = device.makeBuffer(bytes: vbData, length: MemoryLayout<VertexElement>.size * vbData.count, options: .cpuCacheModeWriteCombined)!
        let ibData = [QuadIndexList(v0: 0, v1: 1, v2: 2, v3: 0, v4: 0, v5: 0)]
        self.ib = device.makeBuffer(bytes: ibData, length: MemoryLayout<QuadIndexList>.size * ibData.count, options: .cpuCacheModeWriteCombined)!
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!,  count: 2)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    func draw(in view: MTKView) {
        guard let currentDrawable = view.currentDrawable else { return }
        sema.wait()
        self.frameCount += 1
        let frameIndex = Int(self.frameCount % 2)
        
        let cbSceneData: [Float] = [2.0, 0.0, 0.0, -1.0,
                                    0.0, 2.0, 0.0, -1.0,
                                    0.0, 0.0, 2.0, -1.0,
                                    0.0, 0.0, 0.0, 1.0]
        self.cbScene[frameIndex].contents().copyMemory(from: cbSceneData, byteCount: 64)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.setRenderPipelineState(self.pso)
        enc.setCullMode(.back)
        enc.setVertexBuffer(self.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.cbScene[frameIndex], offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.ib, indexBufferOffset: 0, instanceCount: 1)
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}

