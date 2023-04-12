#include <metal_stdlib>
using namespace metal;

half3 directionFrom3D(half x, half y, uint z) {
    switch (z) {
    case 0: return half3(+1, -y, -x);
    case 1: return half3(-1, -y, +x);
    case 2: return half3(+x, +1, +y);
    case 3: return half3(+x, -1, -y);
    case 4: return half3(+x, -y, +1);
    case 5: return half3(-x, -y, -1);
    }
    return (half3)0;
}

struct SH
{
    half f[9];
    thread const half& operator [](const int i) const {
        return f[i];
    }
    thread half& operator [](const int i) {
        return f[i];
    }
};

// https://andrew-pham.blog/2019/08/26/spherical-harmonics/
// https://www.ppsloan.org/publications/StupidSH36.pdf
// https://www.ppsloan.org/publications/SHJCGT.pdf
void SHNewEval3(half fX, half fY, half fZ, thread SH& pSH) {
    half fC0, fC1, fS0, fS1, fTmpA, fTmpB, fTmpC;
    half fZ2 = fZ * fZ;
    pSH[0] = 0.2820947917738781h;
    pSH[2] = 0.4886025119029199h * fZ;
    pSH[6] = 0.9461746957575601h * fZ2 - 0.3153915652525201h;
    fC0 = fX;
    fS0 = fY;
    fTmpA = -0.48860251190292h;
    pSH[3] = fTmpA * fC0;
    pSH[1] = fTmpA * fS0;
    fTmpB = -1.092548430592079h * fZ;
    pSH[7] = fTmpB * fC0;
    pSH[5] = fTmpB * fS0;
    fC1 = fX * fC0 - fY * fS0;
    fS1 = fX * fS0 + fY * fC0;
    fTmpC = 0.5462742152960395h;
    pSH[8] = fTmpC * fC1;
    pSH[4] = fTmpC * fS1;
}
void SHScale(const thread SH& input, half scale, thread SH& output) {
    for (int i = 0; i < 9; ++i) {
        output[i] = input[i] * scale;
    }
}
void SHAdd(const thread SH& inputA, const thread SH& inputB, thread SH& output) {
    for (int i = 0; i < 9; ++i) {
        output[i] = inputA[i] + inputB[i];
    }
}
void writeSH(SH r, int idx, device atomic_float* buf) {
    for (int i = 0; i < 9; ++i) {
        // Reduce atomic operation
        float sum = simd_sum((float)r[i]);
        simdgroup_barrier(mem_flags::mem_none);
        if (simd_is_first()) {
            atomic_fetch_add_explicit(buf + (9 * idx + i), sum, memory_order_relaxed);
        }
    }
}
void writeSHWeight(half w, device atomic_float* buf) {
    float sum = simd_sum((float)w);
    simdgroup_barrier(mem_flags::mem_none);
    if (simd_is_first()) {
        atomic_fetch_add_explicit(buf + (9 * 3), sum, memory_order_relaxed);
    }
}
void processProjectSH(half3 dir, half3 color, half2 uv, device atomic_float* buf) {
    half u = uv.x * 2 - 1;
    half v = uv.y * 2 - 1;
    half temp = 1.0 + u * u + v * v;
    half weight = 4 / (sqrt(temp) * temp);
    SH basis;
    SHNewEval3(-dir.x, -dir.y, -dir.z, basis);
    SH tempR, tempG, tempB;
    SHScale(basis, color.r * weight, tempR);
    SHScale(basis, color.g * weight, tempG);
    SHScale(basis, color.b * weight, tempB);
    writeSH(tempR, 0, buf);
    writeSH(tempG, 1, buf);
    writeSH(tempB, 2, buf);
    writeSHWeight(weight, buf);
}
// [numthreads(8, 8, 1)]
kernel void projSHCS(ushort3 dtid [[thread_position_in_grid]],
                     texturecube<half> tex [[texture(0)]],
                     device atomic_float* buf [[buffer(0)]])
{
    half width = tex.get_width();
    half height = tex.get_height();
    half2 uv = ((half2)dtid.xy + 0.5h) / half2(width, height);
    half3 dir = directionFrom3D(uv.x * 2 - 1, uv.y * 2 - 1, dtid.z);
    half3 color = tex.read(dtid.xy, dtid.z, 0).rgb;
    processProjectSH(normalize(dir), color, uv, buf);
}

// [numthreads(27, 1, 1)]
kernel void convSHCS(ushort dtid [[thread_position_in_grid]],
                     device float* buf [[buffer(0)]]) {
    float sNorm;
    float k = buf[dtid];
    
    if (simd_is_first()) {
        float fWtSum = buf[9 * 3];
        sNorm = 4 * M_PI_F / fWtSum; // area of sphere
    }
    sNorm = simd_broadcast_first(sNorm);
    simdgroup_barrier(mem_flags::mem_none);
    
    k *= sNorm;
    buf[dtid] = k;
}
