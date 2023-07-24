#ifndef DxilToAir_hpp
#define DxilToAir_hpp

#if 0
#import <swift/bridging>
#include <vector>
#include <string>

struct CxxDxilToAir;

void retainCxxDxilToAir(CxxDxilToAir *_Nonnull);
void releaseCxxDxilToAir(CxxDxilToAir *_Nonnull);

struct IntrusiveRefCount
{
    int refCount = 0;
};

struct SWIFT_SHARED_REFERENCE(retainCxxDxilToAir, releaseCxxDxilToAir) CxxDxilToAir : IntrusiveRefCount
{
    CxxDxilToAir(const CxxDxilToAir&) = delete;
    CxxDxilToAir& operator=(const CxxDxilToAir&) = delete;
    ~CxxDxilToAir();
    
    static CxxDxilToAir *_Nonnull create();
    
    bool load(const std::vector<uint8_t>& data);
    
    std::string getEntryName() const SWIFT_COMPUTED_PROPERTY;
    
private:
    CxxDxilToAir() = default;
};
#else

#import <Foundation/Foundation.h>

@interface DxilToAir : NSObject
{
    int val;
}
- (bool)load:(NSArray *)data;
@end

#endif

// Xcode 15.0 beta failed to link SIMD library :(
extern "C" {
    typedef __attribute__((__ext_vector_type__(4))) float simd_float4;
    simd_float4 _ZL11simd_muladdDv4_fS_S_(simd_float4 v1, simd_float4 v2, simd_float4 v3);
}

#endif /* DxilToAir_hpp */
