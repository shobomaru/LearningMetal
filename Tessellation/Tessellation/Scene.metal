#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct PatchInput {
    patch_control_point<Input> cp;
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct CScene {
    float4x4 viewProj;
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

[[patch(triangle, 3)]]
vertex Output sceneVS(PatchInput input [[stage_in]],
                      float3 barycentric [[position_in_patch]],
                      ushort instanceCount [[instance_id]],
                      constant CScene &scene [[buffer(1)]],
                      const device float3x4* instanceWorldMat [[buffer(2)]])
{
    const float3 pos = barycentric.x * input.cp[0].position.xyz + barycentric.y * input.cp[1].position.xyz + barycentric.z * input.cp[2].position.xyz;
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceCount][0], instanceWorldMat[instanceCount][1], instanceWorldMat[instanceCount][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    Output output;
    output.position = float4(pos, 1) * worldMat * scene.viewProj;
    output.world = output.position.xyz / output.position.w;
    output.normal = half3(barycentric) * 2 - 1;
    //output.normal = normalize(half3(input.normal) * GetNormalMatrix(worldMat));
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return half4(intensity, 1);
}
