#include <metal_stdlib>
using namespace metal;

struct ICBContainer {
    command_buffer cmdBuf [[id(0)]];
    render_pipeline_state pso [[id(1)]];
};

kernel void sceneIndirectCommandBuffer(ushort dtid [[thread_position_in_grid]],
                                       ushort gtid [[thread_position_in_threadgroup]],
                                       const device ICBContainer& icb [[buffer(0)]],
                                       const device uint64_t* vbList [[buffer(1)]],
                                       const device uint64_t* ibList [[buffer(2)]],
                                       const device uint* indexCountList [[buffer(3)]],
                                       const device uint64_t* argList [[buffer(4)]])
{
    render_command render(icb.cmdBuf, dtid);
    //render.set_render_pipeline_state(icb.pso);
    render.set_vertex_buffer(reinterpret_cast<const device void*>(vbList[dtid]), 0);
    // right
    render.set_vertex_buffer(reinterpret_cast<const device void*>(argList[0]), 1); // same argument buffer
    // WRONG!
    uint MakeOutOfBounds = 0xDEAD101;
    //render.set_vertex_buffer(reinterpret_cast<const device void*>(argList[0 + MakeOutOfBounds]), 1); // same argument buffer
    render.set_fragment_buffer(reinterpret_cast<const device void*>(argList[0]), 1); // same arugment buffer
    render.draw_indexed_primitives(primitive_type::triangle, indexCountList[dtid], reinterpret_cast<const device ushort*>(ibList[dtid]), 1);
}
