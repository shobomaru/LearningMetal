import SwiftUI
import MetalKit
import simd

let ManualTracking = true

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
        v.framebufferOnly = false // .shaderWrite requires this option, may reduces GPU performance
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

let DownsampleLevel = 4
let NumThreads = MTLSize(width: 8, height: 8, depth: 1)

class MyResource {
    var psoStretch: MTLComputePipelineState?
    var psoAddBlend: MTLComputePipelineState?
    var psoBlur: MTLComputePipelineState?
    var sailboatTex: MTLTexture
    var heap: MTLHeap
    var downsampleTex: [MTLTexture]
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let csStretch = lib.makeFunction(name: "stretchCS") else { fatalError() }
        guard let csAddBlend = lib.makeFunction(name: "addBlendCS") else { fatalError() }
        guard let csBlur = lib.makeFunction(name: "blurCS") else { fatalError() }
        let psoDesc = MTLComputePipelineDescriptor()
        psoDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = true // may increse GPU performance
        do {
            psoDesc.computeFunction = csStretch
            self.psoStretch = try device.makeComputePipelineState(descriptor: psoDesc, options: []).0
            psoDesc.computeFunction = csAddBlend
            self.psoAddBlend = try device.makeComputePipelineState(descriptor: psoDesc, options: []).0
            psoDesc.computeFunction = csBlur
            self.psoBlur = try device.makeComputePipelineState(descriptor: psoDesc, options: []).0
            
            if (NumThreads.width * NumThreads.height) % self.psoStretch!.threadExecutionWidth != 0 {
                throw NSError(domain: "Unexpected thread execution width", code: 1)
            }
            if (NumThreads.width * NumThreads.height) % self.psoAddBlend!.threadExecutionWidth != 0 {
                throw NSError(domain: "Unexpected thread execution width", code: 1)
            }
            if (NumThreads.width * NumThreads.height) % self.psoBlur!.threadExecutionWidth != 0 {
                throw NSError(domain: "Unexpected thread execution width", code: 1)
            }
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        
        guard let sailboatPath = Bundle.main.url(forResource: "Sailboat", withExtension: "bmp") else { fatalError() }
        guard let sailboatFile = try? FileHandle(forReadingFrom: sailboatPath) else { fatalError() }
        let sailboatData = Metal.generateMipmap(Metal.loadBitmap(sailboatFile))
        let sailboatTexDesc = MTLTextureDescriptor()
        sailboatTexDesc.width = Int(sailboatData[0].extent[0])
        sailboatTexDesc.height = Int(sailboatData[0].extent[1])
        sailboatTexDesc.pixelFormat = .rgba8Unorm
        sailboatTexDesc.mipmapLevelCount = sailboatData.count
        sailboatTexDesc.usage = .shaderRead
        if ManualTracking {
            sailboatTexDesc.hazardTrackingMode = .untracked
        }
        self.sailboatTex = device.makeTexture(descriptor: sailboatTexDesc)!
        for i in 0..<sailboatData.count {
            self.sailboatTex.replace(region: MTLRegionMake2D(0, 0, Int(sailboatData[i].extent[0]), Int(sailboatData[i].extent[1])), mipmapLevel: i, withBytes: sailboatData[i].data, bytesPerRow: Int(4 * sailboatData[i].extent[0]))
        }
        
        // Textures placement in a heap
        // |0                                                                     totalSize|
        // |DownsampleTex00|
        // |DownsampleTex10|
        // |DownsampleTex20|
        // |DownsampleTex30|
        //                 |DownsampleTex01|
        //                                 |DownsampleTex11|
        //                                                 |DownsampleTex21|
        //                                                                 |DownsampleTex31|
        
        var heapPlacementList = [Int](repeating: 0, count: DownsampleLevel * 2)
        let align = { (s: Int, a: Int) -> Int in
            (s + a - 1) & ~(a - 1)
        }
        let calcDownsampleHeapSize = { () -> Int in
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            let downsample00Size = device.heapTextureSizeAndAlign(descriptor: desc)
            var totalSize = align(downsample00Size.size, downsample00Size.align)
            for i in 0..<DownsampleLevel {
                heapPlacementList[2 * i + 1] = totalSize
                desc.width = 128 / (i + 1)
                desc.height = 128 / (i + 1)
                let dsize = device.heapTextureSizeAndAlign(descriptor: desc)
                if (downsample00Size.align < dsize.align) {
                    fatalError("The small texture alignment bigger than big texture!?")
                }
                totalSize += align(dsize.size, dsize.align)
            }
            return totalSize
        }
        let heapSize = calcDownsampleHeapSize()
        //dump(heapPlacementList)
        
        let heapDesc = MTLHeapDescriptor()
        heapDesc.size = heapSize
        heapDesc.storageMode = .private
        heapDesc.hazardTrackingMode = ManualTracking ? .untracked : .tracked
        // .automatic expects that must used with makeAliasable?
        // I want usability like D3D12/Vulkan
        heapDesc.type = .placement
        self.heap = device.makeHeap(descriptor: heapDesc)!
        
        self.downsampleTex = [MTLTexture]()
        for i in 0..<DownsampleLevel {
            for j in 0..<2 {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128 / (i + 1), height: 128 / (i + 1), mipmapped: false)
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .private
                self.downsampleTex.append(self.heap.makeTexture(descriptor: desc, offset: heapPlacementList[2 * i + j])!)
                self.downsampleTex.last!.label = "DownsampleTex[\(i)][\(j)]"
            }
        }
    }
    func available() -> Bool {
        self.psoStretch != nil && self.psoAddBlend != nil && self.psoBlur != nil
    }
}

struct ImageData {
    var extent: [UInt]
    var data: [UInt8]
};

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView2
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
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
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        //
    }
    func draw(in view: MTKView) {
        if (!self.resource.available()) { return }
        guard let currentDrawable = view.currentDrawable else { return }
        sema.wait()
        self.frameCount += 1
        //let frameIndex = Int(self.frameCount % 2)
        
        let align = { (s: Int, a: Int) -> Int in
            (s + a - 1) & ~(a - 1)
        }
        let getDispatchNum = { (t: MTLTexture) -> MTLSize in
            MTLSize(width: align(t.width + NumThreads.width - 1, NumThreads.width), height: align(t.height + NumThreads.height - 1, NumThreads.height), depth: 1)
        }
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let enc = cmdBuf.makeComputeCommandEncoder()!
        enc.label = "Merged Pass"
        for i in 0..<DownsampleLevel {
            enc.pushDebugGroup("Downsample")
            enc.setComputePipelineState(self.resource.psoStretch!)
            enc.useHeap(self.resource.heap)
            if i == 0 {
                if ManualTracking {
                    enc.useResource(self.resource.sailboatTex, usage: .read)
                }
                enc.setTexture(self.resource.sailboatTex, index: 0)
            }
            else {
                enc.setTexture(self.resource.downsampleTex[2 * i - 1], index: 0)
            }
            enc.setTexture(self.resource.downsampleTex[2 * i], index: 1)
            let threshold: Float = (i == 0) ? 0.30 : 0.10
            enc.setBytes([Float](repeating: threshold, count: 1), length: 4, index: 0)
            enc.dispatchThreadgroups(getDispatchNum(self.resource.downsampleTex[2 * i]), threadsPerThreadgroup: NumThreads)
            enc.popDebugGroup()
            if ManualTracking {
                // MTLFence did not update/wait multiple times in one encoder,
                // so we use memory barrier
                enc.memoryBarrier(scope: MTLBarrierScope.textures)
            }
            
            enc.pushDebugGroup("Blur")
            enc.setComputePipelineState(self.resource.psoBlur!)
            enc.useHeap(self.resource.heap) // need multiple call in one encoder?
            enc.setTexture(self.resource.downsampleTex[2 * i], index: 0)
            enc.setTexture(self.resource.downsampleTex[2 * i + 1], index: 1)
            enc.dispatchThreadgroups(getDispatchNum(self.resource.downsampleTex[2 * i + 1]), threadsPerThreadgroup: NumThreads)
            enc.popDebugGroup()
            if ManualTracking {
                enc.memoryBarrier(scope: MTLBarrierScope.textures)
            }
        }
        for i in (1..<DownsampleLevel).reversed() {
            enc.pushDebugGroup("Blend")
            enc.setComputePipelineState(self.resource.psoAddBlend!)
            enc.useHeap(self.resource.heap)
            enc.setTexture(self.resource.downsampleTex[2 * i + 1], index: 0)
            enc.setTexture(self.resource.downsampleTex[2 * i - 1], index: 1)
            enc.setBytes([Float](repeating: 0.12, count: 1), length: 4, index: 0)
            enc.dispatchThreadgroups(getDispatchNum(self.resource.downsampleTex[2 * i + 1]), threadsPerThreadgroup: NumThreads)
            enc.popDebugGroup()
            if ManualTracking {
                enc.memoryBarrier(scope: MTLBarrierScope.textures)
            }
        }
        
        enc.pushDebugGroup("Scene")
        // Draw a base texture
        enc.setComputePipelineState(self.resource.psoStretch!)
        enc.setBytes([Float](repeating: 0.0, count: 1), length: 4, index: 0)
        if ManualTracking {
            enc.useResource(self.resource.sailboatTex, usage: .read)
        }
        enc.setTexture(self.resource.sailboatTex, index: 0)
        enc.setTexture(currentDrawable.texture, index: 1)
        enc.dispatchThreadgroups(getDispatchNum(currentDrawable.texture), threadsPerThreadgroup: NumThreads)
        if ManualTracking {
            enc.memoryBarrier(scope: MTLBarrierScope.textures)
        }
        // Blend a blurred texture
        enc.setComputePipelineState(self.resource.psoAddBlend!)
        enc.useHeap(self.resource.heap)
        enc.setTexture(self.resource.downsampleTex[1], index: 0)
        enc.dispatchThreadgroups(getDispatchNum(currentDrawable.texture), threadsPerThreadgroup: NumThreads)
        enc.popDebugGroup()
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
    static func loadBitmap(_ fh: FileHandle) -> ImageData {
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
    static func generateMipmap(_ mip0: ImageData) -> [ImageData] {
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
