import SwiftUI
#if os(macOS)
import AppKit
#endif

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
        layer.wantsExtendedDynamicRangeContent = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.pixelFormat = .rgba8Unorm
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
    private var lock = NSLock()
    init(message: Binding<String>, isShowAlert: Binding<Bool>) {
        self._message = message
        self._isShowAlert = isShowAlert
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

class Model : MyViewDelegate {
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue?
    
    init(_ parent: ContentView2) {
        self.device = MTLCreateSystemDefaultDevice()!
        self.cmdQueue = self.device.makeCommandQueue()!
    }
    func myView(_ layer: CAMetalLayer, drawableSizeWillChange size: CGSize) {
    }
    func draw(in layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else {
            return
        }
        let cmdBuf = cmdQueue!.makeCommandBuffer()!
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.4, 0.2, 0.1, 1.0)
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.label = "RenderCE"
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
