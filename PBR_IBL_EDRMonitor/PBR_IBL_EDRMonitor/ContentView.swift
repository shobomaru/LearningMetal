import SwiftUI
#if os(macOS)
import AppKit
#endif
import Metal
import simd

let USE_EDR: Bool = true // Use Extended Dynamic Range

struct ContentView: View {
    @State private var message = "default"
    @State private var isShowAlert = false
    @State private var status = "PBR_IBL_EDRMonitor"
    
    var body: some View {
        VStack {
            ContentView2(message: $message, isShowAlert: $isShowAlert, status: $status)
                .alert(isPresented: $isShowAlert) { () -> Alert in
                    return Alert(title: Text("Error"), message: Text(message))
                }
            Text(status)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

#if os(iOS)
typealias MyViewRepresentable = UIViewRepresentable
typealias MyView = UIView
typealias MyRect = CGRect
#else
typealias MyViewRepresentable = NSViewRepresentable
typealias MyView = NSView
typealias MyRect = NSRect
#endif

protocol MyViewDelegate {
    func myView(_ layer: CAMetalLayer, drawableSizeWillChange size: CGSize)
    func draw(in layer: CAMetalLayer)
}

final class View2: MyView {
    public var renderDelegate: MyViewDelegate?
    private var metalLayer: CAMetalLayer?
    #if os(macOS)
    private var displayLink: CVDisplayLink?
    #else
    private var displayLink: CADisplayLink?
    #endif
    
    public override init(frame frameRect: MyRect) {
        super.init(frame: frameRect)
        initInternal()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        initInternal()
    }
    deinit {
        #if os(macOS)
        CVDisplayLinkStop(displayLink!)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: self)
        #else
        displayLink!.isPaused = true
        displayLink!.invalidate()
        #endif
    }
    private func initInternal() {
        #if os(macOS)
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(resizeCallback), name: NSView.frameDidChangeNotification, object: self)
        var cvRet = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        if (cvRet != kCVReturnSuccess) {
            fatalError()
        }
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        cvRet = CVDisplayLinkSetOutputCallback(displayLink!, {displayLink, inNow, inOutputTime, flagsIn, fragsOut, displayLinksContext in return View2.renderCallback(displayLink, inNow, inOutputTime, flagsIn, fragsOut, displayLinksContext) }, selfPtr)
        if (cvRet != kCVReturnSuccess) {
            fatalError()
        }
        #else
        setupMetalLayer(self.layer as! CAMetalLayer)
        displayLink = CADisplayLink(target: self, selector: #selector(renderCallback))
        #endif
    }
    public func renderStart() {
        if renderDelegate == nil {
            fatalError()
        }
        // Main thread only
        if drawableSize.width != 0 && drawableSize.height != 0 {
            renderDelegate!.myView(layer as! CAMetalLayer, drawableSizeWillChange: drawableSize)
        }
        #if os(macOS)
        CVDisplayLinkStart(displayLink!)
        #else
        displayLink!.add(to: .current, forMode: .default)
        #endif
    }
    
    #if os(macOS)
    private static func renderCallback(_ displayLink: CVDisplayLink, _ inNow: UnsafePointer<CVTimeStamp>, _ inOutputTime: UnsafePointer<CVTimeStamp>, _ flagsIn: CVOptionFlags, _ fragsOut: UnsafeMutablePointer<CVOptionFlags>, _ displayLinksContext: UnsafeMutableRawPointer?) -> CVReturn {
        let view2 = unsafeBitCast(displayLinksContext, to: View2.self) // retain
        view2.renderOnce()
        return kCVReturnSuccess
    }
    #else
    @objc private func renderCallback(displayLink: CADisplayLink) {
        renderOnce()
    }
    #endif
    private func renderOnce() {
        if drawableSize.width == 0 || drawableSize.height == 0 {
            return
        }
        var size: CGSize?
        lock.withLock {
            size = isNewSize ? drawableSize : nil
            isNewSize = false
        }
        if let size = size {
            renderDelegate!.myView(metalLayer!, drawableSizeWillChange: size)
        }
        renderDelegate!.draw(in: metalLayer!)
    }
    
    #if os(macOS)
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        setupMetalLayer(layer)
        return layer
    }
    #else
    override class var layerClass: AnyClass {
        get { CAMetalLayer.self }
    }
    #endif
    private func setupMetalLayer(_ layer: CAMetalLayer) {
        layer.device = layer.preferredDevice ?? MTLCreateSystemDefaultDevice()!
        if USE_EDR {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            layer.pixelFormat = .rgba16Float
        }
        else {
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.pixelFormat = .rgba8Unorm
        }
        metalLayer = layer // NSView.layer cannot touch from non UI thread when drawing asynchronously, so we save it now
    }
    
    #if os(macOS)
    @objc private func resizeCallback(_ notification: Notification) {
        if notification.object as? Self == self {
            metalLayer!.drawableSize = CGSizeMake(self.frame.size.width, self.frame.size.height)
            lock.withLock {
                drawableSize = CGSizeMake(self.frame.size.width, self.frame.size.height)
                isNewSize = true
            }
        }
    }
    #else
    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        metalLayer!.drawableSize = CGSizeMake(bounds.width, bounds.height)
        lock.withLock {
            drawableSize = CGSizeMake(bounds.width, bounds.height)
            isNewSize = true
        }
    }
    #endif
    public private(set) var drawableSize: CGSize = CGSizeMake(0, 0)
    public private(set) var isNewSize = false
    private var lock = NSLock()
}

struct ContentView2: MyViewRepresentable {
    #if os(macOS)
    typealias NSViewType = View2
    #endif
    typealias Coordinator = Model
    @Binding private var message: String
    @Binding private var isShowAlert: Bool
    @Binding private var status: String
    private var lock = NSLock()
    init(message: Binding<String>, isShowAlert: Binding<Bool>, status: Binding<String>) {
        self._message = message
        self._isShowAlert = isShowAlert
        self._status = status
    }
    func makeView(context: Context) -> View2 {
        View2()
    }
    func updateView(_ myView: View2, context: Context) {
        myView.renderDelegate = context.coordinator
        myView.renderStart()
    }
    func makeCoordinator() -> Model {
        Model(self)
    }
    func enqueueAlert(_ message: String) {
        Task { @MainActor in
            self.message = message;
            self.isShowAlert = true
        }
    }
#if os(iOS)
    func makeUIView(context: Context) -> View2 {
        makeView(context: context)
    }
    func updateUIView(_ uiView: View2, context: Context) {
        updateView(uiView, context: context)
    }
#else
    func makeNSView(context: Context) -> View2 {
        makeView(context: context)
    }
    func updateNSView(_ nsView: View2, context: Context) {
        updateView(nsView, context: context)
    }
#endif
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

struct ImageData16 {
    var extent: [UInt]
    var data: [Float16]
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
    var pso: MTLRenderPipelineState?
    var psoPost: MTLRenderPipelineState?
    var psoBackground: MTLRenderPipelineState?
    var psoAmbientBrdf: MTLRenderPipelineState?
    var psoPrefilterEnvMap: MTLRenderPipelineState?
    var psoIrradianceEnvMap: MTLRenderPipelineState?
    var psoProjSH: MTLComputePipelineState?
    var psoConvSH: MTLComputePipelineState?
    var vb: MTLBuffer
    var ib: MTLBuffer
    var vbPlane: MTLBuffer
    var ibPlane: MTLBuffer
    var cbScene: [MTLBuffer]
    var cbLight: [MTLBuffer]
    var instanceMatBuf: MTLBuffer
    var depthState: MTLDepthStencilState
    var depthStateBG: MTLDepthStencilState
    var depthStateIgnore: MTLDepthStencilState
    var sailboatTex: MTLTexture
    var lennaTex: MTLTexture
    var ss: MTLSamplerState
    var ambientBrdfTex: MTLTexture
    var radianceEnvTex: MTLTexture
    var prefilteredEnvTex: MTLTexture
    var irradianceEnvTex: MTLTexture
    var bufSH: MTLBuffer
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        guard let vsPost = lib.makeFunction(name: "postVS") else { fatalError() }
        guard let fsPost = lib.makeFunction(name: "postFS") else { fatalError() }
        guard let fsBackground = lib.makeFunction(name: "backgroundFS") else { fatalError() }
        guard let fsAmbientBrdf = lib.makeFunction(name: "ambientBrdfFS") else { fatalError() }
        guard let fsEnvMapFilter = lib.makeFunction(name: "envMapFilterFS") else { fatalError() }
        guard let fsIrradianceMap = lib.makeFunction(name: "irradianeMapFS") else { fatalError() }
        guard let csProjSH = lib.makeFunction(name: "projSHCS") else { fatalError() }
        guard let csConvSH = lib.makeFunction(name: "convSHCS") else { fatalError() }
        var psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].bufferIndex = 0
        vd.attributes[0].offset = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].bufferIndex = 0
        vd.attributes[1].offset = 12
        vd.attributes[2].format = .float2
        vd.attributes[2].bufferIndex = 0
        vd.attributes[2].offset = 24
        vd.layouts[0].stride = MemoryLayout<VertexElement>.stride
        psoDesc.vertexDescriptor = vd
        psoDesc.colorAttachments[0].pixelFormat = USE_EDR ? .rgba16Float : .rgba8Unorm
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Scene PSO"
        do {
            self.pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsPost
        psoDesc.colorAttachments[0].pixelFormat = USE_EDR ? .rgba16Float : .rgba8Unorm
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Post PSO"
        do {
            self.psoPost = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsBackground
        psoDesc.colorAttachments[0].pixelFormat = USE_EDR ? .rgba16Float : .rgba8Unorm
        psoDesc.colorAttachments[1].pixelFormat = .rgba16Float
        psoDesc.depthAttachmentPixelFormat = .depth32Float
        psoDesc.label = "Background PSO"
        do {
            self.psoBackground = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsAmbientBrdf
        psoDesc.colorAttachments[0].pixelFormat = .rg16Float
        psoDesc.label = "AmbientBRDF PSO"
        do {
            self.psoAmbientBrdf = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsEnvMapFilter
        psoDesc.colorAttachments[0].pixelFormat = .rgb9e5Float
        psoDesc.label = "EnvMapFilter PSO"
        do {
            self.psoPrefilterEnvMap = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.inputPrimitiveTopology = .triangle
        psoDesc.vertexFunction = vsPost
        psoDesc.fragmentFunction = fsIrradianceMap
        psoDesc.colorAttachments[0].pixelFormat = .rgb9e5Float
        psoDesc.label = "IrradianceMap PSO"
        do {
            self.psoIrradianceEnvMap = try device.makeRenderPipelineState(descriptor: psoDesc)
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        var csDesc = MTLComputePipelineDescriptor()
        csDesc.label = "SHProjection PSO"
        csDesc.computeFunction = csProjSH
        csDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        do {
            self.psoProjSH = try device.makeComputePipelineState(descriptor: csDesc, options: []).0
        } catch let e {
            print(e)
            alert(String(describing: e))
        }
        csDesc = MTLComputePipelineDescriptor()
        csDesc.label = "SHConversion PSO"
        csDesc.computeFunction = csConvSH
        csDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = false
        do {
            self.psoConvSH = try device.makeComputePipelineState(descriptor: csDesc, options: []).0
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
        self.cbLight = [MTLBuffer](closure: { device.makeBuffer(length: 1024, options: .cpuCacheModeWriteCombined)! }, count: 2)
        
        var instanceMat = [float3x4](repeating: float3x4(), count: 19)
        for i in 0..<18 {
            let tx: Float = Float(i % 6) * 1.1 - 3.3 + 0.65
            let ty: Float = Float(i / 6) * 1.1 + 1.1
            let s: Float = 0.5
            instanceMat[i] = float3x4(columns: (SIMD4(s, 0, 0, tx),
                                                SIMD4(0, s, 0, ty),
                                                SIMD4(0, 0, s, 0)))
        }
        instanceMat[18] = float3x4(columns: (SIMD4(3, 0, 0, 0), SIMD4(0, 3, 0, 2.5), SIMD4(0, 0, 3, 0)))
        self.instanceMatBuf = device.makeBuffer(bytes: instanceMat, length: MemoryLayout<float3x4>.size * instanceMat.count, options: .cpuCacheModeWriteCombined)!
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        dsDesc.depthCompareFunction = .equal
        dsDesc.isDepthWriteEnabled = false
        self.depthStateBG = device.makeDepthStencilState(descriptor: dsDesc)!
        
        dsDesc.depthCompareFunction = .always
        dsDesc.isDepthWriteEnabled = false
        self.depthStateIgnore = device.makeDepthStencilState(descriptor: dsDesc)!
        
        guard let sailboatPath = Bundle.main.url(forResource: "Sailboat", withExtension: "bmp") else { fatalError() }
        guard let sailboatFile = try? FileHandle(forReadingFrom: sailboatPath) else { fatalError() }
        let sailboatData = MyResource.generateMipmap(MyResource.loadBitmap(sailboatFile))
        let sailboatTexDesc = MTLTextureDescriptor()
        sailboatTexDesc.width = Int(sailboatData[0].extent[0])
        sailboatTexDesc.height = Int(sailboatData[0].extent[1])
        sailboatTexDesc.pixelFormat = .rgba8Unorm
        sailboatTexDesc.mipmapLevelCount = sailboatData.count
        sailboatTexDesc.usage = .shaderRead
        self.sailboatTex = device.makeTexture(descriptor: sailboatTexDesc)!
        for i in 0..<sailboatData.count {
            self.sailboatTex.replace(region: MTLRegionMake2D(0, 0, Int(sailboatData[i].extent[0]), Int(sailboatData[i].extent[1])), mipmapLevel: i, withBytes: sailboatData[i].data, bytesPerRow: Int(4 * sailboatData[i].extent[0]))
        }
        
        guard let lennaPath = Bundle.main.url(forResource: "Lenna", withExtension: "bmp") else { fatalError() }
        guard let lennaFile = try? FileHandle(forReadingFrom: lennaPath) else { fatalError() }
        let lennaData = MyResource.generateMipmap(MyResource.loadBitmap(lennaFile))
        let lennaTexDesc = MTLTextureDescriptor()
        lennaTexDesc.width = Int(sailboatData[0].extent[0])
        lennaTexDesc.height = Int(sailboatData[0].extent[1])
        lennaTexDesc.pixelFormat = .rgba8Unorm
        lennaTexDesc.mipmapLevelCount = sailboatData.count
        lennaTexDesc.usage = .shaderRead
        self.lennaTex = device.makeTexture(descriptor: lennaTexDesc)!
        for i in 0..<lennaData.count {
            self.lennaTex.replace(region: MTLRegionMake2D(0, 0, Int(lennaData[i].extent[0]), Int(lennaData[i].extent[1])), mipmapLevel: i, withBytes: lennaData[i].data, bytesPerRow: Int(4 * lennaData[i].extent[0]))
        }
        
        let ssDesc = MTLSamplerDescriptor()
        ssDesc.minFilter = .linear
        ssDesc.magFilter = .linear
        ssDesc.mipFilter = .linear
        ssDesc.sAddressMode = .repeat
        ssDesc.tAddressMode = .repeat
        ssDesc.maxAnisotropy = 4
        self.ss = device.makeSamplerState(descriptor: ssDesc)!
        
        var texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: 256, height: 256, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        self.ambientBrdfTex = device.makeTexture(descriptor: texDesc)!
        
        texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 128, height: 128, mipmapped: false)
        texDesc.textureType = .typeCube
        self.radianceEnvTex = device.makeTexture(descriptor: texDesc)!
        for i in 0..<6 {
            let loadHdrBinary = { (name: String) -> ImageData16 in
                guard let path = Bundle.main.url(forResource: name, withExtension: "bin") else { fatalError() }
                guard let fh = try? FileHandle(forReadingFrom: path) else { fatalError() }
                let w = 128
                let h = 128
                var data: [Float16] = Array(repeating: 0, count: w * h * 2 * 4)
                for y in 0..<h {
                    guard let oneline = try? fh.read(upToCount: 128 * 4 * 4) else { fatalError() }
                    oneline.withUnsafeBytes { ptr in
                        let p = ptr.baseAddress!.assumingMemoryBound(to: Float.self)
                        for x in 0..<w {
                            for c in 0..<4 {
                                data[4 * (y * w + x) + c] = Float16(p.advanced(by: 4 * x + c).pointee)
                            }
                        }
                    }
                }
                return ImageData16(extent: [UInt(w), UInt(h), 1], data: data)
            }
            let face1 = ((i % 2) == 0) ? "pos" : "neg"
            let face2 = (i / 2 == 0) ? "x" : (i / 2 == 1) ? "y" : "z"
            let data = loadHdrBinary("\(face1)\(face2)")
            self.radianceEnvTex.replace(region: MTLRegionMake2D(0, 0, Int(data.extent[0]), Int(data.extent[1])), mipmapLevel: 0, slice: i, withBytes: data.data, bytesPerRow: Int(data.extent[0] * 2 * 4), bytesPerImage: 0)
        }
        
        texDesc.textureType = .typeCube
        texDesc.mipmapLevelCount = 8
        texDesc.pixelFormat = .rgb9e5Float
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        self.prefilteredEnvTex = device.makeTexture(descriptor: texDesc)!
        
        texDesc.mipmapLevelCount = 1
        self.irradianceEnvTex = device.makeTexture(descriptor: texDesc)!
        
        self.bufSH = device.makeBuffer(length: 4 * (9 * 3 + 1), options: [.storageModePrivate])! // SH L2 RGB + weight
    }
    func available() -> Bool {
        self.pso != nil && self.psoPost != nil && self.psoBackground != nil && self.psoAmbientBrdf != nil && self.psoPrefilterEnvMap != nil && self.psoIrradianceEnvMap != nil && self.psoProjSH != nil && self.psoConvSH != nil
    }
    static private func loadBitmap(_ fh: FileHandle) -> ImageData {
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
    static private func generateMipmap(_ mip0: ImageData) -> [ImageData] {
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

class Model : MyViewDelegate {
    var frameCount: UInt64 = 0
    var sema = DispatchSemaphore(value: 2) // double buffer
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    var depthTex: MTLTexture?
    var lightAccumTex: MTLTexture?
    var scene: MyScene
    let resource: MyResource
    init(_ parent: ContentView2) {
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
    func myView(_ layer: CAMetalLayer, drawableSizeWillChange size: CGSize) {
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
    func draw(in layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else {
            return
        }
        sema.wait()
        self.frameCount += 1
        let frameIndex = Int(self.frameCount % 2)
        
        let viewMat = MathUtil.lookAt(pos: self.scene.cameraPos, target: self.scene.cameraTarget, up: self.scene.cameraUp)
        let projMat = MathUtil.perspective(fov: self.scene.cameraFov, aspect: Float(drawable.texture.width) / Float(drawable.texture.height), near: self.scene.cameraFar, far: self.scene.cameraNear)
        
        struct CBScene {
            let viewProj: float4x4
            let invViewProj: float4x4
            let metallic: packed_float2
            let roughness: packed_float2
        };
        let viewProj = viewMat.transpose * projMat.transpose
        var sceneData = CBScene(viewProj: viewProj, invViewProj: viewProj.inverse, metallic: packed_float2(0, 1), roughness: packed_float2(0.05, 0.95))
        self.resource.cbScene[frameIndex].contents().copyMemory(from: &sceneData, byteCount: MemoryLayout<CBScene>.size)
        
        struct CBLight {
            let cameraPosition: simd_float3
            let sunLightIntensity: simd_float3
            let sunLightDirection: simd_float3
        }
        var lightData = CBLight(cameraPosition: self.scene.cameraPos, sunLightIntensity: self.scene.sunLightIntensity, sunLightDirection: self.scene.sunLightDirection)
        self.resource.cbLight[frameIndex].contents().copyMemory(from: &lightData, byteCount: MemoryLayout<CBLight>.size)
        
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        
        if self.frameCount == 1 {
            // Create environment BRDF LUT
            var passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = self.resource.ambientBrdfTex
            passDesc.colorAttachments[0].loadAction = .dontCare
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.renderTargetArrayLength = 1
            var enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
            enc.label = "AmbientBRDF Pass"
            enc.setRenderPipelineState(self.resource.psoAmbientBrdf!)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            
            // Create GGX prefiltered cubemaps
            for i in 0..<8 {
                passDesc = MTLRenderPassDescriptor()
                passDesc.colorAttachments[0].texture = self.resource.prefilteredEnvTex
                passDesc.colorAttachments[0].level = i
                passDesc.colorAttachments[0].loadAction = .dontCare
                passDesc.colorAttachments[0].storeAction = .store
                passDesc.renderTargetArrayLength = 6
                enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
                enc.label = "FilterEnvMap Pass"
                enc.setRenderPipelineState(self.resource.psoPrefilterEnvMap!)
                if i == 0 {
                    enc.setFragmentTexture(self.resource.radianceEnvTex, index: 0)
                }
                else {
                    enc.setFragmentTexture(self.resource.prefilteredEnvTex, index: 0)
                }
                let data = [UInt32(i)]
                enc.setFragmentBytes(data, length: 4, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 6)
                enc.endEncoding()
            }
            
            // Create irradiance map from radiance cubemap
            passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = self.resource.irradianceEnvTex
            passDesc.colorAttachments[0].loadAction = .dontCare
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.renderTargetArrayLength = 6
            enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
            enc.label = "IrradianceMap Pass"
            enc.setRenderPipelineState(self.resource.psoIrradianceEnvMap!)
            enc.setFragmentTexture(self.resource.prefilteredEnvTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 6)
            enc.endEncoding()
            
            // Clear accumulation buffer
            let bltEnc = cmdBuf.makeBlitCommandEncoder()!
            bltEnc.label = "Clear Pass"
            bltEnc.fill(buffer: self.resource.bufSH, range: 0..<self.resource.bufSH.length, value: 0)
            bltEnc.endEncoding()
            
            let csEnc = cmdBuf.makeComputeCommandEncoder(dispatchType: .serial)!
            csEnc.label = "DiffuseSH Pass"
            // Calcurate SH factors from irradiance map
            csEnc.setComputePipelineState(self.resource.psoProjSH!)
            csEnc.setTexture(self.resource.irradianceEnvTex, index: 0)
            csEnc.setBuffer(self.resource.bufSH, offset: 0, index: 0)
            csEnc.dispatchThreadgroups(MTLSizeMake((self.resource.irradianceEnvTex.width + 7) / 8, (self.resource.irradianceEnvTex.height + 7) / 8, 6), threadsPerThreadgroup: MTLSizeMake(8, 8, 1))
            // Barrier
            csEnc.memoryBarrier(resources: [self.resource.bufSH])
            // Convert SH factors
            csEnc.setComputePipelineState(self.resource.psoConvSH!)
            csEnc.dispatchThreadgroups(MTLSizeMake(1, 1, 1), threadsPerThreadgroup: MTLSizeMake(27, 1, 1))
            csEnc.endEncoding()
        }
        
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[1].texture = self.lightAccumTex
        passDesc.colorAttachments[1].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 0.0/*not rendered flag*/)
        passDesc.colorAttachments[1].loadAction = .clear
        passDesc.colorAttachments[1].storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 0.0
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.texture = self.depthTex
        passDesc.renderTargetArrayLength = 1
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "Scene Pass"
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        enc.setVertexBuffer(self.resource.vb, offset: 0, index: 0)
        enc.setVertexBuffer(self.resource.instanceMatBuf, offset: 0, index: 1)
        enc.setVertexBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.setFragmentBuffer(self.resource.cbLight[frameIndex], offset: 0, index: 0)
        enc.setFragmentBuffer(self.resource.bufSH, offset: 0, index: 1)
        enc.setFragmentBuffer(self.resource.cbScene[frameIndex], offset: 0, index: 2)
        enc.setFragmentTexture(self.resource.sailboatTex, index: 0)
        enc.setFragmentTexture(self.resource.ambientBrdfTex, index: 3)
        enc.setFragmentTexture(self.resource.prefilteredEnvTex, index: 4)
        enc.setFragmentSamplerState(self.resource.ss, index: 0)
        // Scene
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6 * SPHERE_SLICES * SPHERE_STACKS, indexType: .uint16, indexBuffer: self.resource.ib, indexBufferOffset: 0, instanceCount: 18)
        enc.setVertexBuffer(self.resource.vbPlane, offset: 0, index: 0)
        enc.setFragmentTexture(self.resource.lennaTex, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: self.resource.ibPlane, indexBufferOffset: 0, instanceCount: 1, baseVertex: 0, baseInstance: 18)
        // Background
        enc.setFragmentTexture(self.resource.radianceEnvTex, index: 0)
        enc.setDepthStencilState(self.resource.depthStateBG)
        enc.setRenderPipelineState(self.resource.psoBackground!)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        // Post
        enc.setDepthStencilState(self.resource.depthStateIgnore)
        enc.setRenderPipelineState(self.resource.psoPost!)
        var isEdr: [UInt32] = [USE_EDR ? 1 : 0]
        enc.setFragmentBytes(&isEdr, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}
