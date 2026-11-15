// Copyright (c) 2026 MacRunner contributors.
// SPDX-License-Identifier: Apache-2.0
#pragma once
// Bounded, schema-pinned capture of actual converter INPUT configuration.
// No GPU/API calls; no unbounded archive allocations; no root runtime enable.
#include "config_wire_fields.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <type_traits>
#include <unistd.h>

namespace mr_capture {
constexpr size_t MaxBytes=2u*1024u*1024u, MaxItems=4096;
constexpr const char* Schema="095c0d48880fc92ceabcceb3bd2e783808b7ff0099e95f349c0359226f976477";
inline void check(bool v,const char* message) {if(!v)throw std::runtime_error(message);}
inline std::string sha(const void* data,size_t size) {
    check(size<=MaxBytes,"hash input too large");
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data,static_cast<CC_LONG>(size),bytes);
    std::ostringstream out;for(auto b:bytes)out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b);
    return out.str();
}
inline int moduleIndex(const std::string& digest) {
    const char* hashes[]={
        "a6e4c229ecb8e60730090f98d985410dbf78478d3a0403196ace91b0c8067388",
        "05018f407f9604d4121129bc6084fe16463ccd8fc1f2d6d5681f4f549e0a01b9",
        "9b22285b55d2d09c54ff2ce9d32035ec8c02b97557a6e7d8d8a3df20fb36e011",
        "44110eb8c1db947d91cc6f0f6544aaa37d5faa85ea0295b0dbb4bfab53a28626"};
    for(int i=0;i<4;++i)if(digest==hashes[i])return i;
    return -1;
}
class Writer {
public:
    std::string bytes;
    void append(const void* data,size_t count) {
        check(count<=MaxBytes && bytes.size()<=MaxBytes-count,"capture size limit");
        bytes.append(static_cast<const char*>(data),count);
    }
    template<class... T> void operator()(T&... values) {(one(values),...);}
    template<class T> void one(T& value) {
        if constexpr(std::is_arithmetic_v<T> || std::is_enum_v<T>) append(&value,sizeof(value));
        else mrCasSerialize(*this,value);
    }
    void one(std::string& value) {
        check(value.size()<=128,"string too large");uint32_t n=uint32_t(value.size());one(n);append(value.data(),n);
    }
    template<class T> void one(std::vector<T>& values) {
        check(values.size()<=MaxItems,"collection too large");uint32_t n=uint32_t(values.size());one(n);
        for(auto& item:values)one(item);
    }
    template<class T,size_t N> void one(T(&values)[N]) {for(auto& item:values)one(item);}
};
class Reader {
public:
    const std::string& bytes;size_t offset=0;
    explicit Reader(const std::string& input):bytes(input){check(input.size()<=MaxBytes,"record too large");}
    void take(void* data,size_t count) {
        check(count<=bytes.size()-offset,"truncated record");
        memcpy(data,bytes.data()+offset,count);offset+=count;
    }
    template<class... T> void operator()(T&... values) {(one(values),...);}
    template<class T> void one(T& value) {
        if constexpr(std::is_same_v<T,bool>) {uint8_t v;take(&v,1);check(v<=1,"invalid boolean");value=v!=0;}
        else if constexpr(std::is_arithmetic_v<T> || std::is_enum_v<T>) take(&value,sizeof(value));
        else mrCasSerialize(*this,value);
    }
    void one(std::string& value) {
        uint32_t n;one(n);check(n<=128 && n<=bytes.size()-offset,"string limit/truncation");
        value.assign(bytes.data()+offset,n);offset+=n;
    }
    template<class T> void one(std::vector<T>& values) {
        uint32_t n;one(n);check(n<=MaxItems && n<=bytes.size()-offset,"collection limit/truncation");
        values.resize(n);for(auto& item:values)one(item);
    }
    template<class T,size_t N> void one(T(&values)[N]) {for(auto& item:values)one(item);}
};
struct Record {
    uint64_t codeHash=0;
    std::string sourceSHA;
    std::vector<uint32_t> spirv;
    mvk::SPIRVToMSLConversionConfiguration config;
    struct Constant {uint32_t id,offset;uint64_t size;};
    std::vector<Constant> constants;
    std::vector<uint8_t> constantData;
    bool specializationPresent=false;
};
inline void validateConstants(const Record& r) {
    check(r.constants.size()<=256 && r.constantData.size()<=65536,"specialization size limit");
    check(r.specializationPresent || (r.constants.empty() && r.constantData.empty()),"absent specialization with data");
    for(auto& c:r.constants)check(c.size && c.size<=r.constantData.size() &&
        c.offset<=r.constantData.size()-c.size,"specialization range");
}
inline std::string encode(uint64_t codeHash,const std::vector<uint32_t>& spirv,
                          const mvk::SPIRVToMSLConversionConfiguration& config,
                          const Record& specialization=Record{}) {
    static_assert(sizeof(bool)==1 && sizeof(uint32_t)==4 && sizeof(uint64_t)==8);
    const uint32_t endian=1;check(*reinterpret_cast<const uint8_t*>(&endian)==1,"little endian required");
    check(spirv.size()>=5 && spirv.size()<=262144 && spirv[0]==0x07230203,"SPIR-V limit/header");
    std::string sourceSHA=sha(spirv.data(),spirv.size()*4);check(moduleIndex(sourceSHA)>=0,"module not allowlisted");
    auto cfg=config;check(cfg.options.entryPointStage==spv::ExecutionModelRayGenerationKHR,"not RayGen");
    Writer out;out.append("MRCASCF2",8);out.append(Schema,64);out.one(codeHash);out.append(sourceSHA.data(),64);
    uint32_t size=uint32_t(spirv.size()*4);out.one(size);out.append(spirv.data(),size);out.one(cfg);
    validateConstants(specialization);bool present=specialization.specializationPresent;out.one(present);
    uint32_t maps=uint32_t(specialization.constants.size());out.one(maps);
    for(auto constant:specialization.constants)out(constant.id,constant.offset,constant.size);
    uint32_t dataSize=uint32_t(specialization.constantData.size());out.one(dataSize);
    if(dataSize)out.append(specialization.constantData.data(),dataSize);
    auto checksum=sha(out.bytes.data(),out.bytes.size());out.append(checksum.data(),checksum.size());
    return out.bytes;
}
inline Record decode(const std::string& bytes) {
    check(bytes.size()>=64 && bytes.size()<=MaxBytes,"record length");
    check(sha(bytes.data(),bytes.size()-64)==bytes.substr(bytes.size()-64),"record checksum mismatch");
    Reader input(bytes);char magic[8],schema[64],digest[64];input.take(magic,8);input.take(schema,64);
    check(memcmp(magic,"MRCASCF2",8)==0 && memcmp(schema,Schema,64)==0,"schema/magic mismatch");
    Record result;input.one(result.codeHash);input.take(digest,64);result.sourceSHA.assign(digest,64);
    check(moduleIndex(result.sourceSHA)>=0,"unknown source SHA");
    uint32_t size;input.one(size);check(size>=20 && size<=1048576 && size%4==0,"invalid SPIR-V length");
    check(size<=bytes.size()-input.offset,"SPIR-V truncated");result.spirv.resize(size/4);input.take(result.spirv.data(),size);
    check(result.spirv[0]==0x07230203 && sha(result.spirv.data(),size)==result.sourceSHA,"SPIR-V digest mismatch");
    input.one(result.config);input.one(result.specializationPresent);
    uint32_t count;input.one(count);check(count<=256,"specialization map limit");result.constants.resize(count);
    for(auto& constant:result.constants)input(constant.id,constant.offset,constant.size);
    uint32_t dataSize;input.one(dataSize);check(dataSize<=65536 && dataSize<=bytes.size()-input.offset,"specialization data limit");
    result.constantData.resize(dataSize);if(dataSize)input.take(result.constantData.data(),dataSize);validateConstants(result);
    check(input.offset==bytes.size()-64,"trailing payload");
    check(result.config.options.entryPointStage==spv::ExecutionModelRayGenerationKHR,"non-RayGen configuration");
    return result;
}
// Return 0=disabled/not allowlisted/already exists, 1=saved, -1=bounded diagnostic
// failure. No exception reaches the game; no shader result/flags are changed.
inline int capture(const char* directory,uint64_t codeHash,const std::vector<uint32_t>& spirv,
                   const mvk::SPIRVToMSLConversionConfiguration& config,
                   const Record& specialization=Record{}) noexcept {
    if(!directory || !*directory)return 0;
    static std::atomic<unsigned> counters[4]{};
    int dir=-1,fd=-1;
    try {
        if(spirv.empty() || spirv.size()>262144)return 0;
        auto digest=sha(spirv.data(),spirv.size()*4);int module=moduleIndex(digest);if(module<0)return 0;
        auto bytes=encode(codeHash,spirv,config,specialization);auto bodySHA=sha(bytes.data(),bytes.size());
        std::string name=digest.substr(0,16)+"-"+bodySHA+".mrcas";
        dir=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);check(dir>=0,"capture directory must exist");
        // Identical input/configuration is deduplicated; different configurations
        // are kept separately rather than overwriting shader-hash-only files.
        if(faccessat(dir,name.c_str(),F_OK,0)==0){close(dir);return 0;}
        unsigned n=counters[module].load(std::memory_order_relaxed);
        while(n<8 && !counters[module].compare_exchange_weak(n,n+1,std::memory_order_relaxed)) {}
        if(n>=8){close(dir);return 0;} // Saturating quota: <=32 records, <=64 MiB/process.
        fd=openat(dir,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if(fd<0){close(dir);return -1;}
        size_t position=0;
        while(position<bytes.size()) {
            ssize_t count=write(fd,bytes.data()+position,bytes.size()-position);
            check(count>0,"capture write failed");position+=size_t(count);
        }
        int completedFd=fd;fd=-1;check(close(completedFd)==0,"capture close failed");
        close(dir);dir=-1;return 1;
    } catch(...) {if(fd>=0)close(fd);if(dir>=0)close(dir);return -1;}
}
// VkSpecializationInfo-shaped input, captured before a pipeline cache lookup.
// Generic to keep this bounded wire format independent of Vulkan headers.
template<class SpecializationInfo>
inline int captureSpecialized(const char* directory,uint64_t codeHash,
        const std::vector<uint32_t>& spirv,const mvk::SPIRVToMSLConversionConfiguration& config,
        const SpecializationInfo* input) noexcept {
    if(!directory || !*directory)return 0;
    try {
        Record r;
        if(input) {
            check(input->mapEntryCount<=256 && input->dataSize<=65536,"specialization input limits");
            check(!input->mapEntryCount || input->pMapEntries,"null specialization map");
            check(!input->dataSize || input->pData,"null specialization data");
            r.specializationPresent=true;
            for(uint32_t i=0;i<input->mapEntryCount;++i) {
                auto& c=input->pMapEntries[i];r.constants.push_back({c.constantID,c.offset,c.size});
            }
            if(input->dataSize) {
                auto* first=static_cast<const uint8_t*>(input->pData);r.constantData.assign(first,first+input->dataSize);
            }
        }
        return capture(directory,codeHash,spirv,config,r);
    }catch(...){return -1;}
}
} // namespace mr_capture
