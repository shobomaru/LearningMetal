#include <metal_stdlib>
using namespace metal;

struct VertexElement {
    packed_float3 position;
    packed_float3 normal;
};

struct CInfo {
    float aspectRatio;
    ushort primitiveCount;
    ushort padding;
};

struct CScene {
    float4x4 viewProj;
};

// [numthreads(32,1,1)]
kernel void preTessCS(ushort2 dtid [[thread_position_in_grid]],
                      device const VertexElement* vert [[buffer(0)]],
                      device const packed_ushort3* indices [[buffer(1)]],
                      device const float3x4* instanceWorldMat [[buffer(2)]],
                      device MTLTriangleTessellationFactorsHalf* tessFactor [[buffer(3)]],
                      constant CInfo& info [[buffer(4)]],
                      constant CScene& scene [[buffer(5)]])
{
    const ushort primitiveIndex = dtid.x;
    const ushort instanceIndex = dtid.y;
    if (primitiveIndex >= info.primitiveCount) {
        return;
    }
    const packed_ushort3 index = indices[primitiveIndex];
    const VertexElement v[3] = {vert[index.x], vert[index.y], vert[index.z]};
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceIndex][0], instanceWorldMat[instanceIndex][1], instanceWorldMat[instanceIndex][2], float4(0, 0, 0, 1));
    const float4 screenPos[3] = {
        float4(v[0].position, 1) * worldMat * scene.viewProj,
        float4(v[1].position, 1) * worldMat * scene.viewProj,
        float4(v[2].position, 1) * worldMat * scene.viewProj,
    };
    const float3 posT[3] = {
        screenPos[0].xyz / screenPos[0].w, screenPos[1].xyz / screenPos[1].w, screenPos[2].xyz / screenPos[2].w
    };
    const float edge[3] = {
        length((posT[1].xy - posT[0].xy) * float2(info.aspectRatio, 1.0)),
        length((posT[2].xy - posT[1].xy) * float2(info.aspectRatio, 1.0)),
        length((posT[0].xy - posT[2].xy) * float2(info.aspectRatio, 1.0)),
    };
    float c = 9.0;
    float p = 0.8;
    float factor[3] = {
        max(1.0, pow(edge[0], p) * c),
        max(1.0, pow(edge[1], p) * c),
        max(1.0, pow(edge[2], p) * c)
    };
    // Cull degenerated triangles
    if (dot(posT[1] - posT[0], posT[1] - posT[0]) < 1e-10
        || dot(posT[2] - posT[1], posT[2] - posT[1]) < 1e-10
        || dot(posT[0] - posT[2], posT[0] - posT[2]) < 1e-10) {
        factor[0] = factor[1] = factor[2] = 0.0;
    }
    // debug
    //if (primitiveIndex == 0) factor[0] = instanceIndex * 10.0;
    //if (instanceIndex > 5) factor[0] = factor[1] = factor[2] == 0.0;
    
    MTLTriangleTessellationFactorsHalf tess;
    tess.edgeTessellationFactor[0] = half(factor[0]);
    tess.edgeTessellationFactor[1] = half(factor[1]);
    tess.edgeTessellationFactor[2] = half(factor[2]);
    tess.insideTessellationFactor = half(factor[0] + factor[1] + factor[2]) / 3.0h;
    tessFactor[uint(info.primitiveCount) * instanceIndex + primitiveIndex] = tess;
}
