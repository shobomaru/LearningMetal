import SwiftUI
import MetalKit
import simd

let ManualTracking = true
// MTLFence cannot sync between render passes?? Artifacs oocur on M1 Mac
let UseEvent = false

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

let DownsampleLevel = 4

class MyResource {
    var psoStretch: MTLRenderPipelineState?
    var psoStretchBlend: MTLRenderPipelineState?
    var psoBlur: MTLRenderPipelineState?
    var sailboatTex: MTLTexture
    var heap: MTLHeap
    var downsampleTex: [MTLTexture]
    var fence: MTLFence
    var event: MTLEvent
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "filterVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "stretchFS") else { fatalError() }
        guard let fsBlur = lib.makeFunction(name: "blurFS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.label = "Stretch PSO"
        do {
            self.psoStretch = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc.colorAttachments[0].isBlendingEnabled = true
        psoDesc.colorAttachments[0].rgbBlendOperation = .add
        psoDesc.colorAttachments[0].alphaBlendOperation = .add
        psoDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        psoDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        psoDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        psoDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        psoDesc.label = "StretchBlend PSO"
        do {
            self.psoStretchBlend = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc.fragmentFunction = fsBlur
        psoDesc.colorAttachments[0].isBlendingEnabled = false
        psoDesc.label = "Blur PSO"
        do {
            self.psoBlur = try device.makeRenderPipelineState(descriptor: psoDesc)
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
            let desc = MTLTextureDescriptor()
            desc.width = 128
            desc.height = 128
            desc.pixelFormat = .rgba8Unorm
            desc.textureType = .type2D
            desc.usage = [.shaderRead, .renderTarget]
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
                let desc = MTLTextureDescriptor()
                desc.width = 128 / (i + 1)
                desc.height = 128 / (i + 1)
                desc.pixelFormat = .rgba8Unorm
                desc.textureType = .type2D
                desc.usage = [.shaderRead, .renderTarget]
                desc.storageMode = .private
                self.downsampleTex.append(self.heap.makeTexture(descriptor: desc, offset: heapPlacementList[2 * i + j])!)
                self.downsampleTex.last!.label = "DownsampleTex[\(i)][\(j)]"
            }
        }
        
        self.fence = device.makeFence()!
        self.event = device.makeEvent()!
    }
    func available() -> Bool {
        self.psoStretch != nil && self.psoStretchBlend != nil && self.psoBlur != nil
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
        
        var eventNo = self.frameCount * 1000
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        var passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store
        for i in 0..<DownsampleLevel {
            passDesc.colorAttachments[0].texture = self.resource.downsampleTex[2 * i]
            var enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
            enc.label = "Downsample Pass"
            enc.setRenderPipelineState(self.resource.psoStretch!)
            enc.useHeap(self.resource.heap, stages: .fragment)
            if i == 0 {
                if ManualTracking {
                    enc.useResource(self.resource.sailboatTex, usage: .read, stages: .fragment)
                }
                enc.setFragmentTexture(self.resource.sailboatTex, index: 0)
            }
            else {
                enc.setFragmentTexture(self.resource.downsampleTex[2 * i - 1], index: 0)
            }
            let threshold: Float = (i == 0) ? 0.30 : 0.10
            enc.setFragmentBytes([Float](repeating: threshold, count: 1), length: 4, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if ManualTracking {
                enc.updateFence(self.resource.fence, after: .fragment)
            }
            enc.endEncoding()
            if UseEvent {
                cmdBuf.encodeSignalEvent(self.resource.event, value: eventNo)
                cmdBuf.encodeWaitForEvent(self.resource.event, value: eventNo)
                eventNo += 1
            }
            
            passDesc.colorAttachments[0].texture = self.resource.downsampleTex[2 * i + 1]
            enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
            enc.label = "Blur Pass"
            enc.setRenderPipelineState(self.resource.psoBlur!)
            enc.useHeap(self.resource.heap, stages: .fragment)
            enc.setFragmentTexture(self.resource.downsampleTex[2 * i], index: 0)
            if ManualTracking {
                enc.waitForFence(self.resource.fence, before: .fragment)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if ManualTracking {
                enc.updateFence(self.resource.fence, after: .fragment)
            }
            enc.endEncoding()
            if UseEvent {
                cmdBuf.encodeSignalEvent(self.resource.event, value: eventNo)
                cmdBuf.encodeWaitForEvent(self.resource.event, value: eventNo)
                eventNo += 1
            }
        }
        for i in (1..<DownsampleLevel).reversed() {
            passDesc.colorAttachments[0].loadAction = .load
            passDesc.colorAttachments[0].texture = self.resource.downsampleTex[2 * i - 1]
            let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
            enc.label = "Blend Pass"
            enc.setRenderPipelineState(self.resource.psoStretchBlend!)
            enc.useHeap(self.resource.heap, stages: .fragment)
            enc.setFragmentTexture(self.resource.downsampleTex[2 * i + 1], index: 0)
            enc.setFragmentBytes([Float](repeating: 0.12, count: 1), length: 4, index: 0)
            if ManualTracking {
                enc.waitForFence(self.resource.fence, before: .fragment)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if ManualTracking {
                enc.updateFence(self.resource.fence, after: .fragment)
            }
            enc.endEncoding()
            if UseEvent {
                cmdBuf.encodeSignalEvent(self.resource.event, value: eventNo)
                cmdBuf.encodeWaitForEvent(self.resource.event, value: eventNo)
                eventNo += 1
            }
        }
        
        passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setCullMode(.back)
        // Draw a base texture
        enc.setRenderPipelineState(self.resource.psoStretch!)
        enc.setFragmentBytes([Float](repeating: 0.0, count: 1), length: 4, index: 0)
        if ManualTracking {
            enc.useResource(self.resource.sailboatTex, usage: .read, stages: .fragment)
        }
        enc.setFragmentTexture(self.resource.sailboatTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // Blend a blurred texture
        enc.setRenderPipelineState(self.resource.psoStretchBlend!)
        enc.useHeap(self.resource.heap, stages: .fragment)
        enc.setFragmentBytes([Float](repeating: 0.0, count: 1), length: 4, index: 0)
        enc.setFragmentTexture(self.resource.downsampleTex[1], index: 0)
        if ManualTracking {
            enc.waitForFence(self.resource.fence, before: .fragment)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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

