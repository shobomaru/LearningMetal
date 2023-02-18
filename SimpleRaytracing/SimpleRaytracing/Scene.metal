#include <metal_stdlib>
using namespace metal;
using namespace metal::raytracing;

struct Input {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
};

struct Output {
    float4 position [[position]];
    float3 world;
    half3 normal;
};

struct CScene {
    float4x4 viewProj;
    packed_float3 lightDir;
};

vertex Output sceneVS(Input input [[stage_in]],
                      constant CScene &scene [[buffer(1)]],
                      uint vid [[vertex_id]])
{
    Output output;
    output.position = float4(input.position, 1) * scene.viewProj;
    output.world = input.position;
    output.normal = half3(input.normal);
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]],
                       const instance_acceleration_structure tlas [[buffer(0)]], // TLAS
                       //const primitive_acceleration_structure blas [[buffer(0)]], // BLAS
                       constant CScene &scene [[buffer(1)]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    
    // Emit a shadow ray
    ray r;
    r.origin = input.world;
    r.direction = scene.lightDir; // Assume directional light
    r.min_distance = 10e-5; // Avoid self intersection
    r.max_distance = 1000;
    intersection_params params;
    params.accept_any_intersection(true);
    params.assume_geometry_type(geometry_type::triangle);
    params.force_opacity(forced_opacity::opaque);
    params.set_opacity_cull_mode(opacity_cull_mode::none);
#if 1
    // TLAS
    intersection_query<instancing> query;
    query.reset(r, tlas, 0x1, params);
#else
    // BLAS
    intersection_query<triangle_data> query;
    query.reset(r, blas);
#endif
    query.next();
    bool isHit = query.get_committed_intersection_type() == intersection_type::triangle;
    if (isHit) {
        intensity *= 0.2;
    }
    
    return half4(intensity, 1);
}
