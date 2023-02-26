#include <metal_stdlib>
using namespace metal;

enum {
    MaxVertexCount = 256,
    MaxPrimitiveCount = 84,
    NumThreads = 128,
};
struct Meshlet {
    uint primitiveCount;
    packed_float3 positions[MaxVertexCount];
    packed_float3 normals[MaxVertexCount];
    uchar indices[MaxPrimitiveCount * 3];
    uint vertexCount;
    packed_uint3 padding;
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct OutputPrimitive {
    uchar primitiveID;
    uchar meshletID;
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

// Metal's max numthreads is 1024, but D3D12's max is 128, so we align with the lower side
// [numthreads(128,1,1)]
[[mesh, max_total_threads_per_threadgroup(NumThreads)]]
void sceneMS(ushort2 dtid [[thread_position_in_grid]],
             ushort gtid [[thread_index_in_threadgroup]],
             MeshOutput output,
             const constant Meshlet* meshlet [[buffer(0)]],
             constant CScene &scene [[buffer(1)]],
             const constant float3x4* instanceWorldMat [[buffer(2)]])
{
    const ushort meshletID = dtid.x / NumThreads;
    const ushort instanceID = dtid.y;
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceID][0], instanceWorldMat[instanceID][1], instanceWorldMat[instanceID][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    
    constant const Meshlet& mlet = meshlet[meshletID];
    output.set_primitive_count(mlet.primitiveCount);
    
    for (ushort id = gtid; id < min(mlet.vertexCount, (uint)MaxVertexCount); id++)
    {
        Output o;
        o.position = float4(mlet.positions[id], 1) * worldMat * scene.viewProj;
        o.world = o.position.xyz / o.position.w;
        o.normal = normalize(half3(mlet.normals[id]) * GetNormalMatrix(worldMat));
        output.set_vertex(id, o);
    }
    
    for (ushort id = gtid; id < min(mlet.primitiveCount, (uint)MaxPrimitiveCount); id++)
    {
        OutputPrimitive op;
        op.primitiveID = (uchar)id;
        op.meshletID = (uchar)meshletID;
        output.set_primitive(id, op);
        
        uchar3 idx = { mlet.indices[3 * id], mlet.indices[3 * id + 1], mlet.indices[3 * id + 2] };
        output.set_index(3 * id, idx[0]);
        output.set_index(3 * id + 1, idx[1]);
        output.set_index(3 * id + 2, idx[2]);
    }
}

fragment half4 sceneFS(PixelInput input [[stage_in]])
{
    half3 intensity = input.perVertex.normal * 0.5 + 0.5;
    if (input.perPrimitive.meshletID & 1) {
        intensity = 0.5 + 0.5 * intensity;
    }
    else {
        intensity = intensity;
    }
    return half4(intensity, 1.0);
}
