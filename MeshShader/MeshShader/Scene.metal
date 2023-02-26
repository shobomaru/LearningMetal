#include <metal_stdlib>
using namespace metal;

enum {
    MaxVertexCount = 256,
    MaxPrimitiveCount = 84,
};
struct Meshlet {
    uint primitiveCount;
    packed_float3 positions[MaxVertexCount];
    packed_float3 normals[MaxVertexCount];
    ushort indices[MaxPrimitiveCount * 3];
    uint padding;
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct OutputPrimitive {
    ushort primitiveID;
};
    
struct PixelInput {
    Output perVertex;
    OutputPrimitive perPrimitive;
};

struct CScene {
    float4x4 viewProj;
};

half3x3 GetNormalMatrix(float4x4 m)
{
    return half3x3(half3(m[0].xyz), half3(m[1].xyz), half3(m[2].xyz));
}

using MeshOutput = metal::mesh<Output, OutputPrimitive, MaxVertexCount, MaxPrimitiveCount, metal::topology::triangle>;

// [numthreads(256,1,1)]
[[mesh, max_total_threads_per_threadgroup(256)]]
void sceneMS(ushort2 dtid [[thread_position_in_grid]],
             ushort gtid [[thread_index_in_threadgroup]],
             MeshOutput output,
             const constant Meshlet* meshlet [[buffer(0)]],
             constant CScene &scene [[buffer(1)]],
             const constant float3x4* instanceWorldMat [[buffer(2)]])
{
    const ushort instanceCount = dtid.y;
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceCount][0], instanceWorldMat[instanceCount][1], instanceWorldMat[instanceCount][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    
    constant const Meshlet& mlet = meshlet[dtid.x / 256];
    output.set_primitive_count(mlet.primitiveCount);
    
    if (gtid < MaxVertexCount)
    {
        Output o;
        o.position = float4(mlet.positions[gtid], 1) * worldMat * scene.viewProj;
        o.world = o.position.xyz / o.position.w;
        o.normal = normalize(half3(mlet.normals[gtid]) * GetNormalMatrix(worldMat));
        output.set_vertex(gtid, o);
    }
    
    if (gtid < mlet.primitiveCount)
    {
        OutputPrimitive op = { gtid };
        output.set_primitive(gtid, op);
        
        ushort3 idx = { mlet.indices[3 * gtid], mlet.indices[3 * gtid + 1], mlet.indices[3 * gtid + 2] };
        output.set_index(3 * gtid, idx[0]);
        output.set_index(3 * gtid + 1, idx[1]);
        output.set_index(3 * gtid + 2, idx[2]);
    }
}

fragment half4 sceneFS(PixelInput input [[stage_in]])
{
    half3 intensity = input.perVertex.normal * 0.5 + 0.5;
    return half4(intensity, 1.0);
}
