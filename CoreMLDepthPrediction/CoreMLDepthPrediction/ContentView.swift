import SwiftUI
import MetalKit
import simd
import CoreML
import Vision
import AVFoundation
import os.signpost

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
    var camera: CameraControl = CameraControl()
    var ml: MLControl = MLControl()
    func makeCoordinator() -> Coordinator {
        return Metal(self)
    }
    private func makeView(context: Context) -> MTKView {
        camera.start()
        ml.start(alert: enqueueAlert)
        
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

class CameraControl: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    var imageCI: CIImage?
    var isImageUpdate = false
    let imageLock = NSLock()
    override init() {
        super.init()
    }
    func start() {
        session = AVCaptureSession()
        // FCRNFP16 model supports only very low resolution (304x228)
        #if os(macOS)
        session!.sessionPreset = .qvga320x240
        #else
        session!.sessionPreset = .cif352x288
        #endif
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else { fatalError() }
        device = dev
        
        guard let input = try? AVCaptureDeviceInput(device: device!) else { fatalError() }
        session!.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "MyAVSample Thread"))
        // TODO: implement this
        #if false
        if isRotate {
            for conn in output.connections {
                if let c = conn as AVCaptureConnection? {
                    if c.isVideoOrientationSupported {
                        c.videoOrientation = AVCaptureVideoOrientation.portrait
                    }
                }
            }
        }
        #endif
        session!.addOutput(output)
        session!.commitConfiguration()
        
        // iOS specific warning?
        // -[AVCaptureSession startRunning] should be called from background thread. Calling it on the main thread can lead to UI unresponsiveness
        DispatchQueue.global().async {
            self.session!.startRunning()
        }
    }
    internal func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let sp = OSSignposter()
        let st = sp.beginInterval("Camera Capture", id: sp.makeSignpostID())
        
        let buf = CMSampleBufferGetImageBuffer(sampleBuffer)!
        //dump(sampleBuffer.formatDescription) // YUV2 on MacBook Air M1
        var imageCI = CIImage(cvPixelBuffer: buf, options: [.toneMapHDRtoSDR: true, .applyOrientationProperty: true])
        #if os(macOS)
        // The front camera seems to be flipped...
        imageCI = imageCI.oriented(.down)
        #elseif os(iOS)
        imageCI = imageCI.oriented(.upMirrored)
        #endif
        
        sp.endInterval("Camera Capture", st)
        
        imageLock.withLock {
            self.imageCI = imageCI
            // Now can read from external
            self.isImageUpdate = true
        }
    }
}

// If you want to build for x86_64, you need to write own FP32 -> FP16 conversion program
typealias MyFloat16 = Float16

class MLControl {
    private var vnModel: VNCoreMLModel?
    private var vnRequest: VNCoreMLRequest?
    private var vnHandler: VNImageRequestHandler?
    var srcImage: CIImage?
    var destImage: [MyFloat16] = Array()
    var destImageWidth = 0
    var isSrcUpdate = false
    var isDestUpdate = false
    var isExit = false
    let srcLock = NSLock()
    let destLock = NSLock()
    private var dispatcher: DispatchQueue
    private var alert: ((String) -> Void)?
    init() {
        dispatcher = DispatchQueue(label: "MyMLControl Thread")
    }
    deinit {
        isExit = true
    }
    func start(alert: @escaping (String) -> Void) {
        self.alert = alert
        let conf = MLModelConfiguration()
        //conf.allowLowPrecisionAccumulationOnGPU = true // 16bit
        conf.modelDisplayName = "FCRN-DepthPrediction sample model"
        conf.computeUnits = .cpuAndNeuralEngine
        //conf.computeUnits = .cpuOnly
        // 3.0 sec load time on MacBook Air M1, but second time 0.15 sec. Maybe cached by OS?
        let model: MLModel;
        do {
            // The asset size is too big, so please download manually from Apple's web site
            // I have tested 16bit version model
            // https://developer.apple.com/jp/machine-learning/models/#image
            // or direct link https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/FCRN/FCRNFP16.mlmodel
            let url = CoreMLDepthPrediction.FCRNFP16.urlOfModelInThisBundle
            model = try MLModel(contentsOf: url, configuration: conf)
        }
        catch let e {
            print(e.localizedDescription)
            alert(String(describing: e))
            return
        }
        do {
            vnModel = try VNCoreMLModel(for: model)
        }
        catch let e {
            print(e.localizedDescription)
            alert(String(describing: e))
            return
        }
        vnRequest = VNCoreMLRequest(model: vnModel!) { (request, error) in
            if let e = error {
                print(e.localizedDescription)
                self.alert!(String(describing: e))
            }
            if let res = request.results as? [VNCoreMLFeatureValueObservation],
               let source = res.first?.featureValue.multiArrayValue {
                assert(source.shape.count == 3)
                assert(source.dataType == .double)
                assert(source.shape[0].intValue == 1) // 1 color channel
                let w = source.shape[1].intValue
                let h = source.shape[2].intValue
                self.destLock.withLock {
                    if self.destImage.capacity < w * h {
                        self.destImage.reserveCapacity(w * h)
                    }
                    self.destImage.removeAll(keepingCapacity: true)
                    // 64bit FP is not suitable for GPU, 16bit FP is enough
                    source.withUnsafeBytes{ ptr in
                        let p = ptr.baseAddress!.assumingMemoryBound(to: Double.self)
                        for y in 0..<h {
                            for x in 0..<w {
                                var v = p[x * h + y]
                                v /= 2.5 // Just suitable for visualize...
                                self.destImage.append(Float16(v))
                            }
                        }
                    }
                    // Now can read from external
                    self.isDestUpdate = true
                    self.destImageWidth = w
                }
            }
        }
        vnRequest!.imageCropAndScaleOption = .scaleFill
        
        // Start ML worker thread
        dispatcher.async {
            while !self.isExit {
                // TODO: Improve efficient
                if self.isSrcUpdate {
                    self.srcLock.withLock {
                        self.perform(imageCI: self.srcImage!)
                    }
                    self.vnHandler = nil // Release memory
                    self.isSrcUpdate = false
                }
                else {
                    Thread.sleep(forTimeInterval: 1.0 / 60.0)
                }
            }
        }
    }
    private func perform(imageCI: CIImage) {
        let sp = OSSignposter()
        let st = sp.beginInterval("ML Perform", id: sp.makeSignpostID())
        
        var orient = CGImagePropertyOrientation.up
        #if os(macOS)
        orient = CGImagePropertyOrientation.right
        #elseif os(iOS)
        orient = CGImagePropertyOrientation.right
        #endif
        // Oh no, YUV2 image seems to convert to RGB pixel using GPU which is already run in my program!
        // This requires 1.5ms CPU time on MacBook Air M1, including GPU wait time
        vnHandler = VNImageRequestHandler(ciImage: imageCI, orientation: orient)
        do {
            // 7 - 15 msec process time on MacBook Air M1
            try vnHandler?.perform([self.vnRequest!])
        }
        catch let e {
            print(e.localizedDescription)
            self.alert!(String(describing: e))
        }
        
        sp.endInterval("ML Perform", st)
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
    var captureTex: MTLTexture?
    var mlTex: MTLTexture?
    var mlTexUpload: [MTLBuffer?] = Array(repeating: nil, count: 2)
    init(device: MTLDevice, alert: (String) -> Void) {
        guard let lib = device.makeDefaultLibrary() else { fatalError() }
        guard let vs = lib.makeFunction(name: "sceneVS") else { fatalError() }
        guard let fs = lib.makeFunction(name: "sceneFS") else { fatalError() }
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vs
        psoDesc.fragmentFunction = fs
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
        
        self.cbScene = [MTLBuffer](repeating: device.makeBuffer(length: 64, options: .cpuCacheModeWriteCombined)!, count: 2)
        
        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .greaterEqual
        dsDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: dsDesc)!
        
        var texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        texDesc.storageMode = .shared
        self.captureTex = device.makeTexture(descriptor: texDesc)!
        self.captureTex!.label = "Default capture texture"
        self.captureTex!.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [0], bytesPerRow: 4)
        
        texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        texDesc.storageMode = .shared
        self.mlTex = device.makeTexture(descriptor: texDesc)!
        self.captureTex!.label = "Default ML texture"
        self.captureTex!.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [0], bytesPerRow: 4)
    }
    func available() -> Bool {
        self.pso != nil
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
    var ciContext: CIContext
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
        
        // Use for CIImage to MTLTexture
        // Don't make CIContext every frame, or shader compiling occurs every render call!
        self.ciContext = CIContext(mtlDevice: self.device)
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
        
        // Get a captured image
        var uploadImage: CIImage? = nil
        if self.parent.camera.isImageUpdate {
            self.parent.camera.imageLock.withLock {
                if let image = self.parent.camera.imageCI {
                    let w = Int(image.extent.width)
                    let h = Int(image.extent.height)
                    if w != self.resource.captureTex!.width || h != self.resource.captureTex!.height {
                        // Resize
                        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
                        desc.usage = [.shaderRead, .shaderWrite]
                        desc.storageMode = .private
                        self.resource.captureTex = device.makeTexture(descriptor: desc)!
                        self.resource.captureTex!.label = "Capture texture"
                    }
                    uploadImage = image
                }
            }
        }
        // Also start ML predication
        if !self.parent.ml.isSrcUpdate, let uploadImage = uploadImage {
            self.parent.ml.srcLock.withLock {
                self.parent.ml.isSrcUpdate = true
                self.parent.ml.srcImage = uploadImage
            }
        }
        // Upload capture texutre
        if let uploadImage = uploadImage {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            self.ciContext.render(uploadImage, to: self.resource.captureTex!, commandBuffer: nil, bounds: uploadImage.extent, colorSpace: space)
        }
        // Get and upload ML texture
        if self.parent.ml.isDestUpdate {
            let bpp = MemoryLayout<MyFloat16>.size
            var w = 0
            var h = 0
            self.parent.ml.destLock.withLock {
                let img = self.parent.ml.destImage
                w = self.parent.ml.destImageWidth
                h = self.parent.ml.destImage.count / w
                assert(self.parent.ml.destImage.count % w == 0)
                if self.resource.mlTex!.width != w || self.resource.mlTex!.height != h {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
                    desc.storageMode = .private
                    self.resource.mlTex = self.device.makeTexture(descriptor: desc)!
                    self.resource.mlTex!.label = "ML texture"
                    
                    // Double buffering to avoid CPU overwrites the GPU reading resource
                    self.resource.mlTexUpload[0] = self.device.makeBuffer(length: bpp * w * h, options: [.storageModeShared, .cpuCacheModeWriteCombined])
                    self.resource.mlTexUpload[1] = self.device.makeBuffer(length: bpp * w * h, options: [.storageModeShared, .cpuCacheModeWriteCombined])
                    self.resource.mlTexUpload[0]!.label = "ML texture upload buffer[0]"
                    self.resource.mlTexUpload[1]!.label = "ML texture upload buffer[1]"
                }
                self.resource.mlTexUpload[frameIndex]!.contents().copyMemory(from: img, byteCount: bpp * w * h)
            }
            let queue = self.cmdQueue.makeCommandBuffer()!
            queue.label = "ML texture upload CommandQueue"
            let enc = queue.makeBlitCommandEncoder()!
            enc.copy(from: self.resource.mlTexUpload[frameIndex]!, sourceOffset: 0, sourceBytesPerRow: bpp * w, sourceBytesPerImage: 0, sourceSize: MTLSizeMake(w, h, 1), to: self.resource.mlTex!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            enc.endEncoding()
            queue.commit()
            // You can manually insert a fence, but no need to do so for tracked resources
        }
        
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
        enc.setRenderPipelineState(self.resource.pso!)
        enc.setCullMode(.back)
        enc.setDepthStencilState(self.resource.depthState)
        //
        enc.setFragmentTexture(self.resource.captureTex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        //
        enc.setFragmentTexture(self.resource.mlTex, index: 0)
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: 128 * 4.5, height: 160 * 4.5, znear: 0, zfar: 1))
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        //
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.addCompletedHandler {[weak self] _ in
            self?.sema.signal()
        }
        cmdBuf.commit()
    }
}

