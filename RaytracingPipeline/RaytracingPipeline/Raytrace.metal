#include <metal_stdlib>
using namespace metal;
using namespace metal::raytracing;

struct VertexElement {
    packed_float3 position;
    packed_float3 normal;
};

struct CScene {
    float4x4 viewProj;
    float4x4 invViewProj;
    packed_float3 cameraPos;
    uint _0;
    packed_float3 lightDir;
};

struct RayInput {
    float3 rayOrigin;
    float3 rayDir;
    float rayT;
    float3 rayBarycentric;
    ushort rayPrimID;
    ushort rayGeomID;
    uint rayInstanceID;
    constant VertexElement* vertices;
    constant ushort* indices;
};

struct RayOutput {
    bool accept;
    half4 shadingColor;
};

using ClosestOrAnyOrMissHitShader = RayOutput(const thread RayInput&);

[[visible]]
RayOutput shadeCS(const thread RayInput& input)
{
    // Read vertices
    VertexElement ve[3] = {};
    ve[0] = input.vertices[input.indices[0]];
    ve[1] = input.vertices[input.indices[1]];
    ve[2] = input.vertices[input.indices[2]];
    
    // Calculate intersection point
    VertexElement veInterp;
    veInterp.position = ve[0].position * input.rayBarycentric.x + ve[1].position * input.rayBarycentric.y + ve[2].position * input.rayBarycentric.z;
    veInterp.normal = ve[0].normal * input.rayBarycentric.x + ve[1].normal * input.rayBarycentric.y + ve[2].normal * input.rayBarycentric.z;
    veInterp.normal = normalize(veInterp.normal);
    
    RayOutput output;
    output.accept = true; // Currently all rays are acceptable
    output.shadingColor = half4(half3(veInterp.normal) * 0.5 + 0.5, 1.0);
    return output;
}

[[visible]]
RayOutput shadowCS(const thread RayInput& input)
{
    RayOutput output = { true, half4(1.0) }; // Currently all rays are acceptable
    return output;
}

[[visible]]
RayOutput missCS(const thread RayInput& input)
{
    RayOutput output = { false, half4(0.1, 0.2, 0.4, 1.0) };
    return output;
}

enum class RayShaderIndex : int {
    Shade = 0,
    Shadow = 1,
    Miss = 2,
};

template<typename T>
T getBarycentric(float2 bary)
{
    // float2 -> float3
    return T(1.0 - bary.x - bary.y, bary.x, bary.y);
}

struct BindlessVBIB {
    constant VertexElement* vb[2];
    constant ushort* ib[2];
};

kernel void raytraceCS(ushort2 dtid [[thread_position_in_grid]],
                       instance_acceleration_structure tlas [[buffer(0)]],
                       visible_function_table<ClosestOrAnyOrMissHitShader> funcTable [[buffer(1)]],
                       constant MTLAccelerationStructureInstanceDescriptor* instanceDesc [[buffer(2)]],
                       //constant VertexElement* sphereVB [[buffer(3)]],
                       //constant ushort* sphereIB [[buffer(4)]],
                       //constant VertexElement* planeVB [[buffer(5)]],
                       //constant ushort* planeIB [[buffer(6)]],
                       constant BindlessVBIB &bindlessVBIB [[buffer(3)]],
                       constant CScene &scene [[buffer(7)]],
                       texture2d<half, access::write> output [[texture(0)]])
{
    // Calcurate ray diretion
    const auto texWidth = output.get_width(), texHeight = output.get_height();
    //const half2 texcoord = half2(1.0 / (half)(texWidth - 1), 1.0 / (half)(texHeight - 1));
    const half2 svpos = (0.5 + (half2)dtid) / half2(texWidth, texHeight);
    const half3 ndc = half3(svpos.x * 2 - 1, svpos.y * -2 + 1, 1);
    float4 farPos = float4(float3(ndc), 1) * scene.invViewProj;
    farPos.xyz /= farPos.w;
    
    // Emit a main ray
    ray r;
    r.origin = scene.cameraPos;
    r.direction = normalize(farPos.xyz - r.origin);
    r.min_distance = 10e-5; // Avoid self intersection
    r.max_distance = 1000;
    //
    // triangle_data: barycentric, front_face
    // instancing: instance_id, user_instance_id
    // world_space_data: world_to_object_transform, object_to_world_transform (Metal 2.4+)
    intersector<triangle_data, instancing> myInt;
    myInt.accept_any_intersection(false); // Need closest intersection for main ray
    RayOutput shadeResult;
    float shadeT;
    do {
        auto result = myInt.intersect(r, tlas, 0x1);
        if (result.type == intersection_type::none) {
            // Clear background
            shadeResult = funcTable[(int)RayShaderIndex::Miss](RayInput{});
            output.write(shadeResult.shadingColor, dtid);
            // Stop processing
            return;
        }
        constant VertexElement* ve = nullptr;
        constant ushort* idx = nullptr;
        ve = bindlessVBIB.vb[result.instance_id];
        idx = bindlessVBIB.ib[result.instance_id];
        idx += 3 * result.primitive_id;
        RayInput rayInput = {
            r.origin, r.direction, result.distance, getBarycentric<float3>(result.triangle_barycentric_coord),
            (ushort)result.primitive_id, (ushort)result.geometry_id, result.instance_id,
            ve, idx,
        };
        shadeResult = funcTable[(int)RayShaderIndex::Shade](rayInput);
        shadeT = result.distance;
    } while (shadeResult.accept == false);
    
    half4 color = shadeResult.shadingColor;
    
    // Emit a shadow ray
    r.origin = r.origin + shadeT * r.direction; // shaded surface point
    r.direction = scene.lightDir; // Assume directional light
    intersector<triangle_data, instancing> myIntShadow;
    myIntShadow.accept_any_intersection(false); // No need closest intersection for shadow ray
    bool isHit = false;
    do {
        auto result = myIntShadow.intersect(r, tlas, 0x1);
        if (result.type == intersection_type::none) {
            break;
        }
        constant VertexElement* ve = nullptr;
        constant ushort* idx = nullptr;
        ve = bindlessVBIB.vb[result.instance_id];
        idx = bindlessVBIB.ib[result.instance_id];
        idx += 3 * result.primitive_id;
        RayInput rayInput = {
            r.origin, r.direction, result.distance, getBarycentric<float3>(result.triangle_barycentric_coord),
            (ushort)result.primitive_id, (ushort)result.geometry_id, result.instance_id,
            ve, idx,
        };
        auto shadowResult = funcTable[(int)RayShaderIndex::Shadow](rayInput);
        isHit = shadowResult.accept;
    } while (isHit == false);
    if (isHit) {
        color.rgb *= 0.2;
    }
    
    output.write(color, dtid);
}
