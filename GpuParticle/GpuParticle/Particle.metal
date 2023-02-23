#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    // float3 direction
    half4 color [[attribute(1)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half4 color;
    float pointSize [[point_size]];
};

struct CScene {
    float4x4 viewProj;
};

vertex Output particleVS(Input input [[stage_in]],
                         constant CScene &scene [[buffer(1)]],
                         uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    output.world = input.position;
    output.color = input.color;
    output.pointSize = 4.0;
    return output;
}

fragment half4 particleFS(Output input [[stage_in]])
{
    return input.color;
}
