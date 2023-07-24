#include "DxilToAir.hpp"

#if 0
#include <metal_irconverter/metal_irconverter.h>

void retainCxxDxilToAir(CxxDxilToAir *_Nonnull air)
{
    air->refCount++;
}

void releaseCxxDxilToAir(CxxDxilToAir *_Nonnull air)
{
    air->refCount--;
    if (air->refCount == 0)
        delete air;
}

CxxDxilToAir::~CxxDxilToAir()
{
}

CxxDxilToAir *_Nonnull CxxDxilToAir::create()
{
    return new CxxDxilToAir();
}

bool CxxDxilToAir::load(const std::vector<uint8_t>& data)
{
    return false;
}

std::string CxxDxilToAir::getEntryName() const
{
    return {};
}

#endif

// Xcode 15.0 beta failed to link SIMD library :(
simd_float4 _ZL11simd_muladdDv4_fS_S_(simd_float4 v1, simd_float4 v2, simd_float4 v3)
{
    simd_float4 r;
    r.x = v1.x * v2.x + v3.x;
    r.y = v1.y * v2.y + v3.y;
    r.z = v1.z * v2.z + v3.z;
    r.w = v1.w * v2.w + v3.w;
    return r;
}
