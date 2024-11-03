#include <metal_stdlib>
// You must set compiler options "-fmetal-enable-logging"
#include <metal_logging>

using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct CScene {
    float4x4 viewProj;
};

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      constant ulong &counter [[buffer(2)]],
                      uint vid [[vertex_id]])
{
    if (vid == 0 && (counter % 60 == 0))
    {
        os_log_default.log_info("Hello, world! %lu", counter);
    }
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    output.world = input.position;
    output.normal = half3(input.normal);
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return half4(intensity, 1);
}
