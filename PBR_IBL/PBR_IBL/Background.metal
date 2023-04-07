#include <metal_stdlib>
using namespace metal;

struct CScene {
    float4x4 ViewProj;
    float4x4 InvViewProj;
    packed_float2 Metallic;
    packed_float2 Roughness;
};

struct CLight {
    float3 cameraPosition;
    float3 sunLightIntensity;
    float3 sunLightDirection;
};

struct Output {
    float4 position [[position]];
    float2 texcoord;
    ushort renderTargetIndex [[render_target_array_index]];
};

struct ColorAttachments {
    half4 lightAccum [[color(1)]];
};

fragment ColorAttachments backgroundFS(Output input [[stage_in]],
                            texturecube<half> texIBL [[texture(0)]],
                            constant CScene& cscene [[buffer(2)]],
                            constant CLight& clight [[buffer(0)]])
{
    constexpr sampler ss(filter::linear, address::repeat);
    
    float farZ = 0;
    float4 csPos = float4(input.texcoord.x * 2 - 1, input.texcoord.y * -2 + 1, farZ, 1);
    float4 wpos = csPos * cscene.InvViewProj;
    wpos.xyz /= wpos.w;
    
    float3 v = wpos.xyz - clight.cameraPosition;
    half3 col = texIBL.sample(ss, normalize(v)).rgb;
    
    ColorAttachments output = { half4(col, 1) };
    return output;
}

