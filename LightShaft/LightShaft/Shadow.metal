#include <metal_stdlib>
using namespace metal;

struct Input {
    float3 position [[attribute(0)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
};

struct CScene {
    float4x4 viewProj;
    float4x4 shadowViewProj;
};

vertex Output shadowVS(Input input [[stage_in]],
                       constant CScene &scene [[buffer(1)]],
                       constant float3x4* instanceWorldMat [[buffer(2)]],
                       ushort instanceID [[instance_id]])
{
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceID][0], instanceWorldMat[instanceID][1], instanceWorldMat[instanceID][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    float4 wpos = float4(input.position, 1) * worldMat;
    
    Output output;
    output.position = wpos * scene.viewProj;
    output.world = wpos.xyz / wpos.w;
    return output;
}

fragment void shadowFS(Output input [[stage_in]])
{
}
