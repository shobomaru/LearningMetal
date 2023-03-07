#include <metal_stdlib>
using namespace metal;

struct ICBContainer {
    command_buffer cmdBuf [[id(0)]];
    render_pipeline_state pso [[id(1)]];
    constant void* vb;
    constant void* vbPlane;
    constant ushort* ib;
    constant ushort* ibPlane;
    constant void* arguments0;
    constant void* arguments1;
};

kernel void sceneIndirectCommandBuffer(ushort dtid [[thread_position_in_grid]],
                                       ushort gtid [[thread_position_in_threadgroup]],
                                       const constant ICBContainer& icb [[buffer(0)]],
                                       const constant uint& frameIndex [[buffer(1)]],
                                       const constant uint2& ibCount [[buffer(2)]])
{
    render_command render(icb.cmdBuf, dtid);
    //render.set_render_pipeline_state(icb.pso);
    render.set_vertex_buffer(dtid == 0 ? icb.vb : icb.vbPlane, 0);
    render.set_vertex_buffer(frameIndex == 0 ? icb.arguments0 : icb.arguments1, 1); // same argument buffer
    render.set_fragment_buffer(frameIndex == 0 ? icb.arguments0 : icb.arguments1, 1); // same arugment buffer
    render.draw_indexed_primitives(primitive_type::triangle, dtid == 0 ? ibCount.x : ibCount.y, dtid == 0 ? icb.ib : icb.ibPlane, 1);
}
