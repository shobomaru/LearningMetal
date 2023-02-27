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
    uint meshletID;
    uint baseInstance;
    uint padding;
};

struct Payload {
    uint numMeshlets;
    uint numInstances;
    Meshlet meshlet;
    // See below...
    float3x4 instanceWorldMat[2];
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

// [numthreads(32)]
[[object, max_total_threads_per_threadgroup(32), max_total_threadgroups_per_mesh_grid(2)]]
void sceneOS(ushort2 dtid [[thread_position_in_grid]],
             ushort gtid [[thread_index_in_threadgroup]],
             object_data Payload& payload [[payload]],
             mesh_grid_properties meshGridProps,
             const constant Meshlet* meshlet [[buffer(0)]],
             const constant float3x4* instanceWorldMat [[buffer(2)]],
             const constant uint2& numMeshletsAndInstances [[buffer(3)]])
{
    // Load a meshlet into payload
    payload.numMeshlets = numMeshletsAndInstances.x;
    payload.numInstances = numMeshletsAndInstances.y;
    constant Meshlet& mlet = meshlet[dtid.x / 32];
    if (gtid == 0)
    {
        payload.meshlet.primitiveCount = mlet.primitiveCount;
        payload.meshlet.vertexCount = mlet.vertexCount;
        payload.meshlet.meshletID = dtid.x / 32;
    }
    for (short id = gtid; id < MaxVertexCount; id += 32)
    {
        payload.meshlet.positions[id] = mlet.positions[id];
        payload.meshlet.normals[id] = mlet.normals[id];
    }
    for (short id = gtid; id < MaxPrimitiveCount; id += 32)
    {
        payload.meshlet.indices[3 * id] = mlet.indices[3 * id];
        payload.meshlet.indices[3 * id + 1] = mlet.indices[3 * id + 1];
        payload.meshlet.indices[3 * id + 2] = mlet.indices[3 * id + 2];
    }
    
    // Load matrices
    const ushort baseInstance = dtid.y * 2;
    const ushort maxInstance = (ushort)numMeshletsAndInstances.y;
    const ushort numInstance = min(2, maxInstance - baseInstance);
    for (ushort id = gtid; id < numInstance; id += 32)
    {
        payload.instanceWorldMat[gtid] = instanceWorldMat[baseInstance + gtid];
    }
    if (gtid == 0)
    {
        payload.meshlet.baseInstance = baseInstance;
    }
    
    // Dispatch instances
    uint dispatchX = numInstance;
    meshGridProps.set_threadgroups_per_grid(uint3(1, dispatchX, 1));
}
    
using MeshOutput = metal::mesh<Output, OutputPrimitive, MaxVertexCount, MaxPrimitiveCount, metal::topology::triangle>;

// Metal's max numthreads is 1024, but D3D12's max is 128, so we align with the lower side
// [numthreads(128,1,1)]
[[mesh, max_total_threads_per_threadgroup(NumThreads)]]
void sceneMS(ushort2 dtid [[thread_position_in_grid]],
             ushort gtid [[thread_index_in_threadgroup]],
             const object_data Payload& payload [[payload]],
             MeshOutput output,
             const constant float3x4* instanceWorldMat [[buffer(2)]],
             constant CScene &scene [[buffer(1)]])
{
    // Currently on MacOS 13.1 and iOS 16.3, MTLCompiler has crashed when using dynamicaly indexed buffer access
    // so we draw same instances multiple times :(
    
    ushort instanceIdx = 1;//dtid.y;
    instanceIdx = min(instanceIdx, (ushort)(2 - 1));
    //ushort instanceID = (ushort)payload.meshlet.baseInstance + instanceIdx;
    const float4x4 worldMat = float4x4(payload.instanceWorldMat[instanceIdx][0], payload.instanceWorldMat[instanceIdx][1], payload.instanceWorldMat[instanceIdx][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    
    //constant const Meshlet& mlet = payload.meshlet[meshletID];
    Meshlet mlet = payload.meshlet;
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
        op.meshletID = (uchar)payload.meshlet.meshletID;
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
