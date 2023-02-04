#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
};

struct Output {
    float4 position [[position]];
};

struct CScene {
    float4x4 viewProj;
    float4x4 shadowViewProj;
};

vertex Output shadowVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    return output;
}

fragment void shadowFS(Output input [[stage_in]])
{
}
