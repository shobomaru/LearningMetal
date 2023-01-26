import SwiftUI
import MetalKit

struct ContentView: UIViewRepresentable {
    typealias Coordinator = Metal
    func makeCoordinator() -> Coordinator {
        Metal(self)
    }
    func makeUIView(context: UIViewRepresentableContext<ContentView>) -> MTKView {
        let v = MTKView()
        v.delegate = context.coordinator
        v.enableSetNeedsDisplay = true
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

class Metal: NSObject, MTKViewDelegate {
    var parent: ContentView
    var device: MTLDevice
    var cmdQueue: MTLCommandQueue
    init(_ parent: ContentView) {
        self.parent = parent
        self.device = MTLCreateSystemDefaultDevice()!
        self.cmdQueue = self.device.makeCommandQueue()!
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        //
    }
    func draw(in view: MTKView) {
        guard let currentDrawable = view.currentDrawable else { return }
        let cmdBuf = self.cmdQueue.makeCommandBuffer()!
        let passDesc = view.currentRenderPassDescriptor!
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.4, 1.0)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!
        enc.endEncoding()
        cmdBuf.present(currentDrawable)
        cmdBuf.commit()
    }
}

