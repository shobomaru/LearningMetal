import SwiftUI
#if os(macOS)
import AppKit
#endif

//
// We must set CADisableMinimumFrameDurationOnPhone to true in info.plist
//

struct ContentView: View {
    @State private var message = "default"
    @State private var isShowAlert = false
    
    var body: some View {
        VStack {
            ContentView2(message: $message, isShowAlert: $isShowAlert)
                .alert(isPresented: $isShowAlert) { () -> Alert in
                    return Alert(title: Text("Error"), message: Text(message))
                }
            Text("Hello, CAMetalLayer!")
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
    func draw(in update: CAMetalDisplayLink.Update)
}

final class View2: MyView, CALayerDelegate, CAMetalDisplayLinkDelegate {
    
    public var renderDelegate: MyViewDelegate?
    private var metalLayer: CAMetalLayer?
    private var displayLink: CAMetalDisplayLink?
    private var prevTimestamp: CFTimeInterval = CFTimeInterval()
    
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
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: self)
        #endif
        displayLink!.isPaused = true
        displayLink!.invalidate()
    }
    private func initInternal() {
        #if os(macOS)
        wantsLayer = true
        layerContentsRedrawPolicy = NSView.LayerContentsRedrawPolicy.duringViewResize
        NotificationCenter.default.addObserver(self, selector: #selector(resizeCallback), name: NSView.frameDidChangeNotification, object: self)
        #endif
        setupMetalLayer(self.layer as! CAMetalLayer)
    }
    public func renderStart() {
        if renderDelegate == nil {
            fatalError()
        }
        // Main thread only
        if drawableSize.width != 0 && drawableSize.height != 0 {
            renderDelegate!.myView(layer as! CAMetalLayer, drawableSizeWillChange: drawableSize)
        }
    }
    
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        var deltaTime = prevTimestamp - update.targetPresentationTimestamp
        prevTimestamp = update.targetPresentationTimestamp
        renderOnce(in: update)
    }
    private func renderOnce(in update: CAMetalDisplayLink.Update) {
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
        renderDelegate!.draw(in: update)
    }
    
    #if os(macOS)
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        return layer
    }
    #else
    override class var layerClass: AnyClass {
        get { CAMetalLayer.self }
    }
    #endif
    
    private func setupMetalLayer(_ layer: CAMetalLayer) {
        layer.device = layer.preferredDevice ?? MTLCreateSystemDefaultDevice()!
        layer.wantsExtendedDynamicRangeContent = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.pixelFormat = .rgba8Unorm
        metalLayer = layer // NSView.layer cannot touch from non UI thread when drawing asynchronously, so we save it now
        
        displayLink = CAMetalDisplayLink(metalLayer: layer)
        displayLink!.preferredFrameLatency = 2
        #if os(macOS)
        let maxFps = NSScreen.main?.maximumFramesPerSecond ?? 30
        #else
        let maxFps = UIScreen.main.maximumFramesPerSecond
        #endif
        displayLink!.preferredFrameRateRange = CAFrameRateRange.init(minimum: 30.0, maximum: Float(maxFps), preferred: nil)
        displayLink!.isPaused = false
        displayLink!.delegate = self
        
        displayLink!.add(to: RunLoop.current, forMode: RunLoop.Mode.common) // always update
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
    init(message: Binding<String>, isShowAlert: Binding<Bool>) {
        self._message = message
        self._isShowAlert = isShowAlert
    }
    private func makeView(context: Context) -> View2 {
        View2()
    }
    private func updateView(_ myView: View2, context: Context) {
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

class Model : MyViewDelegate {
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue?
    
    init(_ parent: ContentView2) {
        self.device = MTLCreateSystemDefaultDevice()!
        self.cmdQueue = self.device.makeCommandQueue()!
    }
    func myView(_ layer: CAMetalLayer, drawableSizeWillChange size: CGSize) {
    }
    
    private func HSVtoRGB(hsv: (h: Double, s: Double, v: Double)) -> (r: Double, g: Double, b: Double) {
        let h = hsv.h * 6.0 // Scale hue to [0, 6]
        let s = hsv.s
        let v = hsv.v

        let c = v * s // Chroma
        let x = c * (1 - abs(fmod(h, 2.0) - 1))
        let m = v - c

        var r = 0.0, g = 0.0, b = 0.0
        if 0 <= h && h < 1 {
            r = c; g = x
        } else if 1 <= h && h < 2 {
            r = x; g = c
        } else if 2 <= h && h < 3 {
            g = c; b = x
        } else if 3 <= h && h < 4 {
            g = x; b = c
        } else if 4 <= h && h < 5 {
            r = x; b = c
        } else {
            r = c; b = x
        }
        return (r + m, g + m, b + m)
    }
    
    var time = 0.0
    func draw(in update: CAMetalDisplayLink.Update) {
        time = (time + 0.005).truncatingRemainder(dividingBy: 1.0)
        let rgb = HSVtoRGB(hsv: (time, 1.0, 1.0))
        
        let drawable = update.drawable
        let cmdBuf = cmdQueue!.makeCommandBuffer()!
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(rgb.r, rgb.g, rgb.b, 1.0)
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "RenderCE"
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
