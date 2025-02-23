#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

struct Input {
    packed_float3 position;
    packed_float3 normal;
};

struct CScene {
    float4x4 viewProj;
};

static float edgeFunction(float2 a, float2 b, float2 c)
{
    float t = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    return t;
}
/*static float edgeFunction(float3 a, float3 b, float3 c)
{
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}*/

kernel void softwareRaster(uint threadID [[thread_position_in_grid]],
                           constant Input *vertexBuffer [[buffer(0)]],
                           constant ushort *indexBuffer [[buffer(1)]],
                           constant CScene &scene [[buffer(2)]],
                           //texture2d<ulong, access::read_write> rasterTex [[texture(0)]])
                           texture2d<uint, access::read_write> rasterTex [[texture(0)]])
{
    const float2 screenSize = float2(rasterTex.get_width(), rasterTex.get_height());
    const ushort3 indexValue = {
        indexBuffer[3 * threadID],
        indexBuffer[3 * threadID + 1],
        indexBuffer[3 * threadID + 2],
    };
    const Input vertexValue[3] = {
        vertexBuffer[indexValue.x],
        vertexBuffer[indexValue.y],
        vertexBuffer[indexValue.z]};
    
    const float3 positionValue[3] = {vertexValue[0].position, vertexValue[1].position, vertexValue[2].position};
    const float4 transformedPos[3] = {
        float4(positionValue[0], 1.0) * scene.viewProj,
        float4(positionValue[1], 1.0) * scene.viewProj,
        float4(positionValue[2], 1.0) * scene.viewProj};
    const float3 tpos[3] = {
        transformedPos[0].xyz / transformedPos[0].w,
        transformedPos[1].xyz / transformedPos[1].w,
        transformedPos[2].xyz / transformedPos[2].w
    };
    float2 npos[3] = {
        (tpos[0].xy * 0.5 + 0.5) * screenSize,
        (tpos[1].xy * 0.5 + 0.5) * screenSize,
        (tpos[2].xy * 0.5 + 0.5) * screenSize,
    };
    npos[0].y = screenSize.y - npos[0].y;
    npos[1].y = screenSize.y - npos[1].y;
    npos[2].y = screenSize.y - npos[2].y;
    const float4 aabb = float4(min(min(npos[0].x, npos[1].x), npos[2].x),
                               min(min(npos[0].y, npos[1].y), npos[2].y),
                               max(max(npos[0].x, npos[1].x), npos[2].x),
                               max(max(npos[0].y, npos[1].y), npos[2].y));
    const uint3 color[3] = {
        uint3((vertexValue[0].normal.xyz * 0.5 + 0.5) * 255.0),
        uint3((vertexValue[1].normal.xyz * 0.5 + 0.5) * 255.0),
        uint3((vertexValue[2].normal.xyz * 0.5 + 0.5) * 255.0),
    };
    const uint packedColor[3] = {
        color[0].x | (color[0].y << 8) | (color[0].z << 16),
        color[1].x | (color[1].y << 8) | (color[1].z << 16),
        color[2].x | (color[2].y << 8) | (color[2].z << 16),
    };
    
    float area = edgeFunction(npos[0], npos[1], npos[2]);
    float areaInv = 1.0 / area;
    if (area <= 0)
    {
        return;
    }
    
    // Optimization for rasterization loop
    const float2 edge[3] = {
        float2(npos[1].y - npos[2].y, npos[2].x - npos[1].x) * areaInv,
        float2(npos[2].y - npos[0].y, npos[0].x - npos[2].x) * areaInv,
        float2(npos[0].y - npos[1].y, npos[1].x - npos[0].x) * areaInv,
    };
    const float3 p0 = float3(floor(aabb.xy) + 0.5, 0);
    float3 w = float3(edgeFunction(npos[1], npos[2], p0.xy) * areaInv,
                      edgeFunction(npos[2], npos[0], p0.xy) * areaInv,
                      edgeFunction(npos[0], npos[1], p0.xy) * areaInv);
    float z = dot(w, float3(tpos[0].z, tpos[1].z, tpos[2].z));
    const float gradZX = edge[0].x * tpos[0].z + edge[1].x * tpos[1].z + edge[2].x * tpos[2].z;
    const float gradZY = edge[0].y * tpos[0].z * edge[1].y * tpos[1].z + edge[2].y * tpos[2].z;
    
    for (float y = aabb.y; y <= aabb.w; y += 1.0)
    {
        float w0 = w.x, w1 = w.y, w2 = w.z;
        float zz = z;
        
        for (float x = aabb.x; x <= aabb.z; x += 1.0)
        {
#if 0
            float2 p = float2(floor(x) + 0.5, floor(y) + 0.5);
            w0 = edgeFunction(npos[1], npos[2], p) * areaInv;
            w1 = edgeFunction(npos[2], npos[0], p) * areaInv;
            w2 = edgeFunction(npos[0], npos[1], p) * areaInv;
#endif
            if (min(min(w0, w1), w2) >= 0)
            {
#if 1
                float z2 = w0 * tpos[0].z + w1 * tpos[1].z + w2 * tpos[2].z;
                rasterTex.atomic_fetch_max(uint2(x, y), as_type<uint>(z2));
#else
                rasterTex.atomic_fetch_max(uint2(x, y), as_type<uint>(zz));
#endif
            }
            w0 += edge[0].x;
            w1 += edge[1].x;
            w2 += edge[2].x;
            zz += gradZX;
        }
        w.x += edge[0].y;
        w.y += edge[1].y;
        w.z += edge[2].y;
        z += gradZY;
    }
}

// -----------------------------------------------------------------

struct Output2 {
    float4 position [[position]];
};

vertex Output2 fullscreenVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output2 output;
    output.position = float4(x, y, 0, 1);
    //output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

fragment half4 verifyFS(Output2 input [[stage_in]],
                        texture2d<uint, access::read> rasterTex [[texture(0)]])
{
    //uint data = rasterTex.read(uint2(input.position.xy)).x;
    return half4(1, 1, 0, 1);
}

struct Fragment2 {
    float depth [[depth(any)]];
};

fragment Fragment2 copyDepthFS(Output2 input [[stage_in]],
                               texture2d<uint, access::read> rasterTex [[texture(0)]])
{
    uint data = rasterTex.read(uint2(input.position.xy)).x;
    Fragment2 output = { as_type<float>(data) };
    return output;
}
