#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct CScene {
    float4x4 viewProj;
    float4x4 shadowViewProj;
};

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    output.world = input.position;
    output.normal = half3(input.normal);
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]],
                       constant CScene &scene [[buffer(1)]],
                       depth2d<float> shadowMap [[texture(0)]],
                       sampler shadowSampler [[sampler(0)]])
{
    half3 color = input.normal * 0.5 + 0.5;
    float4 shadow_svpos = float4(input.world, 1) * scene.shadowViewProj;
    float2 shadow_uv = shadow_svpos.xy / shadow_svpos.w * 0.5 + 0.5;
    if (all(shadow_uv >= 0.0) && all(shadow_uv <= 1.0)) {
        float shadowZ = shadow_svpos.z / shadow_svpos.w;
        float shadowBias = 0.00005;
        uint shadowValue = shadowMap.sample_compare(shadowSampler, shadow_uv, shadowZ + shadowBias);
        if (shadowValue > 0) {
            color *= 0.2h;
        }
    }
    return half4(color, 1);
}
