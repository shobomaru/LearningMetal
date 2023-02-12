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

struct Argument {
    const device CScene* scene [[id(0)]];
    depth2d<float> shadowMap [[id(1)]];
    sampler shadowSampler [[id(2)]];
};

vertex Output sceneVS(Input input [[stage_in]],
                      const device Argument& args [[buffer(1)]],
                      uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * args.scene->viewProj;
    output.world = input.position;
    output.normal = half3(input.normal);
    // WRONG!
    uint MakeOutOfBounds = 0xDEAD101;
    //output.position += args.scene[MakeOutOfBounds].shadowViewProj[0].xyzw;
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]],
                       const device Argument& args [[buffer(1)]])
{
    half3 color = input.normal * 0.5 + 0.5;
    float4 shadow_svpos = float4(input.world, 1) * args.scene->shadowViewProj;
    float2 shadow_uv = shadow_svpos.xy / shadow_svpos.w * 0.5 + 0.5;
    if (all(shadow_uv >= 0.0) && all(shadow_uv <= 1.0)) {
        float shadowZ = shadow_svpos.z / shadow_svpos.w;
        float shadowBias = 0.00005;
        uint shadowValue = args.shadowMap.sample_compare(args.shadowSampler, shadow_uv, shadowZ + shadowBias);
        if (shadowValue > 0) {
            color *= 0.2h;
        }
    }
    return half4(color, 1);
}
