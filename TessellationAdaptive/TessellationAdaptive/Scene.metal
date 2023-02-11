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

// https://ogldev.org/www/tutorial31/tutorial31.html
float3 ProjectToPlane(float3 point, float3 planePoint, float3 planeNormal)
{
    float3 v = point - planePoint;
    float len = dot(v, planeNormal);
    float3 d = len * planeNormal;
    return (point - d);
}

struct PatchControlInfo {
    float3 b300, b030, b003; // edge
    float3 b210, b120, b021, b012, b102, b201; // midpoint
    float3 b111; // center
};

PatchControlInfo CalcPatchInfo(const float3 pos[3], const float3 norm[3])
{
    PatchControlInfo cp = {pos[0], pos[1], pos[2]};
    float3 b210 = mix(cp.b300, cp.b030, 1.0 / 3.0);
    float3 b120 = mix(cp.b300, cp.b030, 2.0 / 3.0);
    float3 b021 = mix(cp.b030, cp.b003, 1.0 / 3.0);
    float3 b012 = mix(cp.b030, cp.b003, 2.0 / 3.0);
    float3 b102 = mix(cp.b003, cp.b300, 1.0 / 3.0);
    float3 b201 = mix(cp.b003, cp.b300, 2.0 / 3.0);
    cp.b021 = ProjectToPlane(b021, cp.b030, norm[1]);
    cp.b012 = ProjectToPlane(b012, cp.b003, norm[2]);
    cp.b102 = ProjectToPlane(b102, cp.b003, norm[2]);
    cp.b201 = ProjectToPlane(b201, cp.b300, norm[0]);
    cp.b210 = ProjectToPlane(b210, cp.b300, norm[0]);
    cp.b120 = ProjectToPlane(b120, cp.b030, norm[1]);
    float3 c = (cp.b300 + cp.b030 + cp.b003) / 3.0;
    float3 b111 = (cp.b021 + cp.b012 + cp.b102 + cp.b201 + cp.b210 + cp.b120) / 6.0;
    cp.b111 = b111 + (b111 - c) / 2.0;
    return cp;
}

// https://developer.download.nvidia.com/whitepapers/2010/PN-AEN-Triangles-Whitepaper.pdf
float3 InterpolatePN(float3 bary, const PatchControlInfo cp)
{
    float uu = bary.x * bary.x;
    float vv = bary.y * bary.y;
    float ww = bary.z * bary.z;
    float uu3 = uu * 3.0;
    float vv3 = vv * 3.0;
    float ww3 = ww * 3.0;
    float3 p = cp.b300 * uu * bary.x + cp.b030 * vv * bary.y + cp.b003 * ww * bary.z;
    p += cp.b210 * uu3 * bary.y + cp.b120 * vv3 * bary.x;
    p += cp.b021 * vv3 * bary.z + cp.b012 * ww3 * bary.y;
    p += cp.b102 * ww3 * bary.x + cp.b201 * uu3 * bary.z;
    p += cp.b111 * 6.0 * bary.x * bary.y * bary.z;
    return p;
}

[[patch(triangle, 3)]]
vertex Output sceneVS(PatchInput input [[stage_in]],
                      float3 barycentric [[position_in_patch]],
                      ushort instanceCount [[instance_id]],
                      constant CScene &scene [[buffer(1)]],
                      const device float3x4* instanceWorldMat [[buffer(2)]])
{
    const float3 posList[3] = {input.cp[0].position, input.cp[1].position, input.cp[2].position};
    const float3 normList[3] = {input.cp[0].normal, input.cp[1].normal, input.cp[2].normal};
    const auto patch = CalcPatchInfo(posList, normList);
    const float3 pos = InterpolatePN(barycentric, patch);
    const float4x4 worldMat = float4x4(instanceWorldMat[instanceCount][0], instanceWorldMat[instanceCount][1], instanceWorldMat[instanceCount][2], float4(0, 0, 0, 1));
    //const float4x4 worldMat = float4x4(float4(1,0,0,0),float4(0,1,0,0),float4(0,0,1,0), float4(0,0,0,1));
    Output output;
    output.position = float4(pos, 1) * worldMat * scene.viewProj;
    output.world = output.position.xyz / output.position.w;
    //output.normal = half3(barycentric) * 2 - 1;
    const float3 normal = barycentric.x * input.cp[0].normal + barycentric.y * input.cp[1].normal + barycentric.z * input.cp[2].normal;
    output.normal = normalize(half3(normal) * GetNormalMatrix(worldMat));
#if 0
    // Now culling has already run in CS
    if (dot(patch.b030 - patch.b300, patch.b030 - patch.b300) < 1e-10
        || dot(patch.b003 - patch.b030, patch.b003 - patch.b030) < 1e-10
        || dot(patch.b300 - patch.b003, patch.b300 - patch.b003) < 1e-10) {
        output.position.w = as_type<float>(0x7FFFFFFF/*NaN*/);
    }
#endif
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]])
{
    half3 intensity = input.normal * 0.5 + 0.5;
    return half4(intensity, 1);
}
