#include <metal_stdlib>
using namespace metal;

kernel void sceneGpuCommandBuffer(ushort dtid [[thread_position_in_grid]],
                                  ushort gtid [[thread_position_in_threadgroup]])
{
    //
}
