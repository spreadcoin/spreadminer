#if 1

#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdint.h>
#include <stdio.h>
#include <memory.h>

#define TPB 128

static __device__ uint32_t cuda_swab32(uint32_t x)
{
	return __byte_perm(x, 0, 0x0123);
}

// das Hi Word in einem 64 Bit Typen ersetzen
static __device__ __forceinline__ unsigned long long REPLACE_HIWORD(const unsigned long long &x, const uint32_t &y) {
	return (x & 0xFFFFFFFFULL) | (((unsigned long long)y) << 32ULL);
}

// die Message it Padding zur Berechnung auf der GPU
__constant__ uint64_t c_PaddedMessage80[16]; // padded message (80 bytes + padding)

#define SPH_C64(x)    ((uint64_t)(x ## ULL))

__forceinline__ __device__ uint64_t ROTL64S(const uint64_t value, const int offset) {
    uint64_t result;
    asm("{\n\t"
    " .reg .u32 tl,th,vl,vh; \n\t"
    "mov.b64 {tl,th},%1; \n\t"
    "shf.l.wrap.b32 vh,tl,th,%2; \n\t"
    "shf.l.wrap.b32 vl,th,tl,%2; \n\t"
    "mov.b64 %0,{vl,vh}; \n\t"
    "}"
    : "=l"(result) : "l"(value) , "r"(offset));
    return  result;
}

__forceinline__ __device__ uint64_t ROTL64_32(const uint64_t value) {
    uint64_t result;
    asm("{\n\t"
    " .reg .u32 tl,th; \n\t"
    "mov.b64 {tl,th},%1; \n\t"
    "mov.b64 %0,{th,tl}; \n\t"
    "}"
    : "=l"(result) : "l"(value));
    return  result;
}

__forceinline__ __device__ uint64_t ROTL64B(const uint64_t value, const int offset) {
    uint64_t result;
    asm("{\n\t"
    " .reg .u32 tl,th,vl,vh; \n\t"
    "mov.b64 {tl,th},%1; \n\t"
    "shf.l.wrap.b32 vl,tl,th,%2; \n\t"
    "shf.l.wrap.b32 vh,th,tl,%2; \n\t"
    "mov.b64 %0,{vl,vh}; \n\t"
    "}"
    : "=l"(result) : "l"(value) , "r"(offset));
    return  result;
}

static __constant__ uint64_t d_constMem[16];
static uint64_t h_constMem[16] = {
	SPH_C64(0x8081828384858687),
    SPH_C64(0x88898A8B8C8D8E8F),
    SPH_C64(0x9091929394959697),
    SPH_C64(0x98999A9B9C9D9E9F),
    SPH_C64(0xA0A1A2A3A4A5A6A7),
    SPH_C64(0xA8A9AAABACADAEAF),
    SPH_C64(0xB0B1B2B3B4B5B6B7),
    SPH_C64(0xB8B9BABBBCBDBEBF),
    SPH_C64(0xC0C1C2C3C4C5C6C7),
    SPH_C64(0xC8C9CACBCCCDCECF),
    SPH_C64(0xD0D1D2D3D4D5D6D7),
    SPH_C64(0xD8D9DADBDCDDDEDF),
    SPH_C64(0xE0E1E2E3E4E5E6E7),
    SPH_C64(0xE8E9EAEBECEDEEEF),
    SPH_C64(0xF0F1F2F3F4F5F6F7),
    SPH_C64(0xF8F9FAFBFCFDFEFF)
};

#define Kb(j)   ((uint64_t)(j) * 0x0555555555555555ull)
#define Kc(j)   ((uint64_t)(j) + 0xaaaaaaaaaaaaaaa0ull)

static __constant__ uint64_t d_x55[16];
static const uint64_t h_x55[16] = {
	Kb(16), Kb(17), Kb(18), Kb(19), Kb(20), Kb(21), Kb(22), Kb(23),
    Kb(24), Kb(25), Kb(26), Kb(27), Kb(28), Kb(29), Kb(30), Kb(31)
};

static __constant__ uint64_t d_final[16];
static const uint64_t h_final[16] = {
    Kc(0), Kc(1), Kc(2), Kc(3), Kc(4), Kc(5), Kc(6), Kc(7),
    Kc(8), Kc(9), Kc(10), Kc(11), Kc(12), Kc(13), Kc(14), Kc(15)
};

#define SHL(x, n)            ((x) << (n))
#define SHR(x, n)            ((x) >> (n))

#define CONST_EXP2    q[i+0] + ROTL64S(q[i+1], 5)  + q[i+2] + ROTL64S(q[i+3], 11) + \
                    q[i+4] + ROTL64S(q[i+5], 27) + q[i+6] + ROTL64_32(q[i+7]) + \
                    q[i+8] + ROTL64B(q[i+9], 37) + q[i+10] + ROTL64B(q[i+11], 43) + \
                    q[i+12] + ROTL64B(q[i+13], 53) + (SHR(q[i+14],1) ^ q[i+14]) + (SHR(q[i+15],2) ^ q[i+15])

__device__ void Compression512(uint64_t *msg, uint64_t *hash)
{
    // Compression ref. implementation
    uint64_t tmp[16];
    uint64_t q[32];

    tmp[0] = (msg[ 5] ^ hash[ 5]) - (msg[ 7] ^ hash[ 7]) + (msg[10] ^ hash[10]) + (msg[13] ^ hash[13]) + (msg[14] ^ hash[14]);
    tmp[1] = (msg[ 6] ^ hash[ 6]) - (msg[ 8] ^ hash[ 8]) + (msg[11] ^ hash[11]) + (msg[14] ^ hash[14]) - (msg[15] ^ hash[15]);
    tmp[2] = (msg[ 0] ^ hash[ 0]) + (msg[ 7] ^ hash[ 7]) + (msg[ 9] ^ hash[ 9]) - (msg[12] ^ hash[12]) + (msg[15] ^ hash[15]);
    tmp[3] = (msg[ 0] ^ hash[ 0]) - (msg[ 1] ^ hash[ 1]) + (msg[ 8] ^ hash[ 8]) - (msg[10] ^ hash[10]) + (msg[13] ^ hash[13]);
    tmp[4] = (msg[ 1] ^ hash[ 1]) + (msg[ 2] ^ hash[ 2]) + (msg[ 9] ^ hash[ 9]) - (msg[11] ^ hash[11]) - (msg[14] ^ hash[14]);
    tmp[5] = (msg[ 3] ^ hash[ 3]) - (msg[ 2] ^ hash[ 2]) + (msg[10] ^ hash[10]) - (msg[12] ^ hash[12]) + (msg[15] ^ hash[15]);
    tmp[6] = (msg[ 4] ^ hash[ 4]) - (msg[ 0] ^ hash[ 0]) - (msg[ 3] ^ hash[ 3]) - (msg[11] ^ hash[11]) + (msg[13] ^ hash[13]);
    tmp[7] = (msg[ 1] ^ hash[ 1]) - (msg[ 4] ^ hash[ 4]) - (msg[ 5] ^ hash[ 5]) - (msg[12] ^ hash[12]) - (msg[14] ^ hash[14]);
    tmp[8] = (msg[ 2] ^ hash[ 2]) - (msg[ 5] ^ hash[ 5]) - (msg[ 6] ^ hash[ 6]) + (msg[13] ^ hash[13]) - (msg[15] ^ hash[15]);
    tmp[9] = (msg[ 0] ^ hash[ 0]) - (msg[ 3] ^ hash[ 3]) + (msg[ 6] ^ hash[ 6]) - (msg[ 7] ^ hash[ 7]) + (msg[14] ^ hash[14]);
    tmp[10] = (msg[ 8] ^ hash[ 8]) - (msg[ 1] ^ hash[ 1]) - (msg[ 4] ^ hash[ 4]) - (msg[ 7] ^ hash[ 7]) + (msg[15] ^ hash[15]);
    tmp[11] = (msg[ 8] ^ hash[ 8]) - (msg[ 0] ^ hash[ 0]) - (msg[ 2] ^ hash[ 2]) - (msg[ 5] ^ hash[ 5]) + (msg[ 9] ^ hash[ 9]);
    tmp[12] = (msg[ 1] ^ hash[ 1]) + (msg[ 3] ^ hash[ 3]) - (msg[ 6] ^ hash[ 6]) - (msg[ 9] ^ hash[ 9]) + (msg[10] ^ hash[10]);
    tmp[13] = (msg[ 2] ^ hash[ 2]) + (msg[ 4] ^ hash[ 4]) + (msg[ 7] ^ hash[ 7]) + (msg[10] ^ hash[10]) + (msg[11] ^ hash[11]);
    tmp[14] = (msg[ 3] ^ hash[ 3]) - (msg[ 5] ^ hash[ 5]) + (msg[ 8] ^ hash[ 8]) - (msg[11] ^ hash[11]) - (msg[12] ^ hash[12]);
    tmp[15] = (msg[12] ^ hash[12]) - (msg[ 4] ^ hash[ 4]) - (msg[ 6] ^ hash[ 6]) - (msg[ 9] ^ hash[ 9]) + (msg[13] ^ hash[13]);
    
    q[0] = (SHR(tmp[0], 1) ^ SHL(tmp[0], 3) ^ ROTL64S(tmp[0],  4) ^ ROTL64B(tmp[0], 37)) + hash[1];
    q[1] = (SHR(tmp[1], 1) ^ SHL(tmp[1], 2) ^ ROTL64S(tmp[1], 13) ^ ROTL64B(tmp[1], 43)) + hash[2];
    q[2] = (SHR(tmp[2], 2) ^ SHL(tmp[2], 1) ^ ROTL64S(tmp[2], 19) ^ ROTL64B(tmp[2], 53)) + hash[3];
    q[3] = (SHR(tmp[3], 2) ^ SHL(tmp[3], 2) ^ ROTL64S(tmp[3], 28) ^ ROTL64B(tmp[3], 59)) + hash[4];
    q[4] = (SHR(tmp[4], 1) ^ tmp[4]) + hash[5];
    q[5] = (SHR(tmp[5], 1) ^ SHL(tmp[5], 3) ^ ROTL64S(tmp[5],  4) ^ ROTL64B(tmp[5], 37)) + hash[6];
    q[6] = (SHR(tmp[6], 1) ^ SHL(tmp[6], 2) ^ ROTL64S(tmp[6], 13) ^ ROTL64B(tmp[6], 43)) + hash[7];
    q[7] = (SHR(tmp[7], 2) ^ SHL(tmp[7], 1) ^ ROTL64S(tmp[7], 19) ^ ROTL64B(tmp[7], 53)) + hash[8];
    q[8] = (SHR(tmp[8], 2) ^ SHL(tmp[8], 2) ^ ROTL64S(tmp[8], 28) ^ ROTL64B(tmp[8], 59)) + hash[9];
    q[9] = (SHR(tmp[9], 1) ^ tmp[9]) + hash[10];
    q[10] = (SHR(tmp[10], 1) ^ SHL(tmp[10], 3) ^ ROTL64S(tmp[10],  4) ^ ROTL64B(tmp[10], 37)) + hash[11];
    q[11] = (SHR(tmp[11], 1) ^ SHL(tmp[11], 2) ^ ROTL64S(tmp[11], 13) ^ ROTL64B(tmp[11], 43)) + hash[12];
    q[12] = (SHR(tmp[12], 2) ^ SHL(tmp[12], 1) ^ ROTL64S(tmp[12], 19) ^ ROTL64B(tmp[12], 53)) + hash[13];
    q[13] = (SHR(tmp[13], 2) ^ SHL(tmp[13], 2) ^ ROTL64S(tmp[13], 28) ^ ROTL64B(tmp[13], 59)) + hash[14];
    q[14] = (SHR(tmp[14], 1) ^ tmp[14]) + hash[15];
    q[15] = (SHR(tmp[15], 1) ^ SHL(tmp[15], 3) ^ ROTL64S(tmp[15], 4) ^ ROTL64B(tmp[15], 37)) + hash[0];

    // Expand 1
    for(int i=0;i<2;i++)
    {
        q[i+16] =
        (SHR(q[i], 1) ^ SHL(q[i], 2) ^ ROTL64S(q[i], 13) ^ ROTL64B(q[i], 43)) +
        (SHR(q[i+1], 2) ^ SHL(q[i+1], 1) ^ ROTL64S(q[i+1], 19) ^ ROTL64B(q[i+1], 53)) +
        (SHR(q[i+2], 2) ^ SHL(q[i+2], 2) ^ ROTL64S(q[i+2], 28) ^ ROTL64B(q[i+2], 59)) +
        (SHR(q[i+3], 1) ^ SHL(q[i+3], 3) ^ ROTL64S(q[i+3],  4) ^ ROTL64B(q[i+3], 37)) +
        (SHR(q[i+4], 1) ^ SHL(q[i+4], 2) ^ ROTL64S(q[i+4], 13) ^ ROTL64B(q[i+4], 43)) +
        (SHR(q[i+5], 2) ^ SHL(q[i+5], 1) ^ ROTL64S(q[i+5], 19) ^ ROTL64B(q[i+5], 53)) +
        (SHR(q[i+6], 2) ^ SHL(q[i+6], 2) ^ ROTL64S(q[i+6], 28) ^ ROTL64B(q[i+6], 59)) +
        (SHR(q[i+7], 1) ^ SHL(q[i+7], 3) ^ ROTL64S(q[i+7],  4) ^ ROTL64B(q[i+7], 37)) +
        (SHR(q[i+8], 1) ^ SHL(q[i+8], 2) ^ ROTL64S(q[i+8], 13) ^ ROTL64B(q[i+8], 43)) +
        (SHR(q[i+9], 2) ^ SHL(q[i+9], 1) ^ ROTL64S(q[i+9], 19) ^ ROTL64B(q[i+9], 53)) +
        (SHR(q[i+10], 2) ^ SHL(q[i+10], 2) ^ ROTL64S(q[i+10], 28) ^ ROTL64B(q[i+10], 59)) +
        (SHR(q[i+11], 1) ^ SHL(q[i+11], 3) ^ ROTL64S(q[i+11],  4) ^ ROTL64B(q[i+11], 37)) +
        (SHR(q[i+12], 1) ^ SHL(q[i+12], 2) ^ ROTL64S(q[i+12], 13) ^ ROTL64B(q[i+12], 43)) +
        (SHR(q[i+13], 2) ^ SHL(q[i+13], 1) ^ ROTL64S(q[i+13], 19) ^ ROTL64B(q[i+13], 53)) +
        (SHR(q[i+14], 2) ^ SHL(q[i+14], 2) ^ ROTL64S(q[i+14], 28) ^ ROTL64B(q[i+14], 59)) +
        (SHR(q[i+15], 1) ^ SHL(q[i+15], 3) ^ ROTL64S(q[i+15],  4) ^ ROTL64B(q[i+15], 37)) +
        ((    d_x55[i] + ROTL64S(msg[i], i+1) +
            ROTL64S(msg[i+3], i+4) - ROTL64S(msg[i+10], i+11) ) ^ hash[i+7]);
    }

#pragma unroll 4
    for(int i=2;i<6;i++) {
        q[i+16] = CONST_EXP2 + 
        ((    d_x55[i] + ROTL64S(msg[i], i+1) +
            ROTL64S(msg[i+3], i+4) - ROTL64S(msg[i+10], i+11) ) ^ hash[i+7]);
    }
#pragma unroll 3
    for(int i=6;i<9;i++) {
        q[i+16] = CONST_EXP2 + 
        ((    d_x55[i] + ROTL64S(msg[i], i+1) +
            ROTL64S(msg[i+3], i+4) - ROTL64S(msg[i-6], i-5) ) ^ hash[i+7]);
    }
#pragma unroll 4
    for(int i=9;i<13;i++) {
        q[i+16] = CONST_EXP2 + 
        ((    d_x55[i] + ROTL64S(msg[i], i+1) +
            ROTL64S(msg[i+3], i+4) - ROTL64S(msg[i-6], i-5) ) ^ hash[i-9]);
    }
#pragma unroll 3
    for(int i=13;i<16;i++) {
        q[i+16] = CONST_EXP2 + 
        ((    d_x55[i] + ROTL64S(msg[i], i+1) +
            ROTL64S(msg[i-13], i-12) - ROTL64S(msg[i-6], i-5) ) ^ hash[i-9]);
    }

    uint64_t XL64 = q[16]^q[17]^q[18]^q[19]^q[20]^q[21]^q[22]^q[23];
    uint64_t XH64 = XL64^q[24]^q[25]^q[26]^q[27]^q[28]^q[29]^q[30]^q[31];

    hash[0] =                       (SHL(XH64, 5) ^ SHR(q[16],5) ^ msg[ 0]) + (    XL64    ^ q[24] ^ q[ 0]);
    hash[1] =                       (SHR(XH64, 7) ^ SHL(q[17],8) ^ msg[ 1]) + (    XL64    ^ q[25] ^ q[ 1]);
    hash[2] =                       (SHR(XH64, 5) ^ SHL(q[18],5) ^ msg[ 2]) + (    XL64    ^ q[26] ^ q[ 2]);
    hash[3] =                       (SHR(XH64, 1) ^ SHL(q[19],5) ^ msg[ 3]) + (    XL64    ^ q[27] ^ q[ 3]);
    hash[4] =                       (SHR(XH64, 3) ^     q[20]    ^ msg[ 4]) + (    XL64    ^ q[28] ^ q[ 4]);
    hash[5] =                       (SHL(XH64, 6) ^ SHR(q[21],6) ^ msg[ 5]) + (    XL64    ^ q[29] ^ q[ 5]);
    hash[6] =                       (SHR(XH64, 4) ^ SHL(q[22],6) ^ msg[ 6]) + (    XL64    ^ q[30] ^ q[ 6]);
    hash[7] =                       (SHR(XH64,11) ^ SHL(q[23],2) ^ msg[ 7]) + (    XL64    ^ q[31] ^ q[ 7]);

    hash[ 8] = ROTL64S(hash[4], 9) + (    XH64     ^     q[24]    ^ msg[ 8]) + (SHL(XL64,8) ^ q[23] ^ q[ 8]);
    hash[ 9] = ROTL64S(hash[5],10) + (    XH64     ^     q[25]    ^ msg[ 9]) + (SHR(XL64,6) ^ q[16] ^ q[ 9]);
    hash[10] = ROTL64S(hash[6],11) + (    XH64     ^     q[26]    ^ msg[10]) + (SHL(XL64,6) ^ q[17] ^ q[10]);
    hash[11] = ROTL64S(hash[7],12) + (    XH64     ^     q[27]    ^ msg[11]) + (SHL(XL64,4) ^ q[18] ^ q[11]);
    hash[12] = ROTL64S(hash[0],13) + (    XH64     ^     q[28]    ^ msg[12]) + (SHR(XL64,3) ^ q[19] ^ q[12]);
    hash[13] = ROTL64S(hash[1],14) + (    XH64     ^     q[29]    ^ msg[13]) + (SHR(XL64,4) ^ q[20] ^ q[13]);
    hash[14] = ROTL64S(hash[2],15) + (    XH64     ^     q[30]    ^ msg[14]) + (SHR(XL64,7) ^ q[21] ^ q[14]);
    hash[15] = ROTL64S(hash[3],16) + (    XH64     ^     q[31]    ^ msg[15]) + (SHR(XL64,2) ^ q[22] ^ q[15]);
}

__global__ void quark_bmw512_gpu_hash_64(int threads, uint32_t startNounce, uint64_t *g_hash, uint32_t *g_nonceVector)
{
    int thread = (blockDim.x * blockIdx.x + threadIdx.x);
    if (thread < threads)
    {
        uint32_t nounce = (g_nonceVector != NULL) ? g_nonceVector[thread] : (startNounce + thread);

        int hashPosition = nounce - startNounce;
        uint64_t *inpHash = &g_hash[8 * hashPosition];
        uint64_t h[16];
        uint64_t message[16];

#pragma unroll 16
		for(int i=0;i<16;i++)
			h[i] = d_constMem[i];
#pragma unroll 8
        for(int i=0;i<8;i++)
            message[i] = inpHash[i];
#pragma unroll 6
        for(int i=9;i<15;i++)
            message[i] = 0;

        message[8] = SPH_C64(0x80);
        message[15] = SPH_C64(512);

        Compression512(message, h);

#pragma unroll 16
        for(int i=0;i<16;i++)
            message[i] = d_final[i];

        Compression512(h, message);

        uint64_t *outpHash = &g_hash[8 * hashPosition];

#pragma unroll 8
        for(int i=0;i<8;i++)
            outpHash[i] = message[i+8];
    }
}

__global__ void quark_bmw512_gpu_hash_80(int threads, uint32_t startNounce, uint64_t *g_hash)
{
    int thread = (blockDim.x * blockIdx.x + threadIdx.x);
    if (thread < threads)
    {
        uint32_t nounce = startNounce + thread;

        // Init
        uint64_t h[16];
#pragma unroll 16
		for(int i=0;i<16;i++)
			h[i] = d_constMem[i];

        // Nachricht kopieren (Achtung, die Nachricht hat 64 Byte,
        // BMW arbeitet mit 128 Byte!!!
        uint64_t message[16];
#pragma unroll 16
        for(int i=0;i<16;i++)
            message[i] = c_PaddedMessage80[i];

        // die Nounce durch die thread-spezifische ersetzen
        message[9] = REPLACE_HIWORD(message[9], cuda_swab32(nounce));

        // Compression 1
        Compression512(message, h);

        // Final
#pragma unroll 16
        for(int i=0;i<16;i++)
            message[i] = d_final[i];

        Compression512(h, message);

        // fertig
        uint64_t *outpHash = &g_hash[8 * thread];

#pragma unroll 8
        for(int i=0;i<8;i++)
            outpHash[i] = message[i+8];
    }
}

// Setup-Funktionen
__host__ void quark_bmw512_cpu_init(int thr_id, int threads)
{
    // nix zu tun ;-)
	// jetzt schon :D
	cudaMemcpyToSymbol(d_constMem, h_constMem, sizeof(h_constMem), 0, cudaMemcpyHostToDevice);
	cudaMemcpyToSymbol(d_x55, h_x55, sizeof(h_x55), 0, cudaMemcpyHostToDevice);
	cudaMemcpyToSymbol(d_final, h_final, sizeof(h_final), 0, cudaMemcpyHostToDevice);
}

// Bmw512 f�r 80 Byte grosse Eingangsdaten
__host__ void quark_bmw512_cpu_setBlock_80(void *pdata)
{
	// Message mit Padding bereitstellen
	// lediglich die korrekte Nonce ist noch ab Byte 76 einzusetzen.
	unsigned char PaddedMessage[128];
	memcpy(PaddedMessage, pdata, 80);
	memset(PaddedMessage+80, 0, 48);
	uint64_t *message = (uint64_t*)PaddedMessage;
	// Padding einf�gen (Byteorder?!?)
	message[10] = SPH_C64(0x80);
	// L�nge (in Bits, d.h. 80 Byte * 8 = 640 Bits
	message[15] = SPH_C64(640);

	// die Message zur Berechnung auf der GPU
	cudaMemcpyToSymbol( c_PaddedMessage80, PaddedMessage, 16*sizeof(uint64_t), 0, cudaMemcpyHostToDevice);
}

__host__ void quark_bmw512_cpu_hash_64(int thr_id, int threads, uint32_t startNounce, uint32_t *d_nonceVector, uint32_t *d_hash, int order)
{
    const int threadsperblock = TPB;

    // berechne wie viele Thread Blocks wir brauchen
    dim3 grid((threads + threadsperblock-1)/threadsperblock);
    dim3 block(threadsperblock);

    // Gr��e des dynamischen Shared Memory Bereichs
    size_t shared_size = 0;

    quark_bmw512_gpu_hash_64<<<grid, block, shared_size>>>(threads, startNounce, (uint64_t*)d_hash, d_nonceVector);

	cudaDeviceSynchronize();
}

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

__host__ void quark_bmw512_cpu_hash_80(int thr_id, int threads, uint32_t startNounce, uint32_t *d_hash, int order)
{
    const int threadsperblock = TPB;

    // berechne wie viele Thread Blocks wir brauchen
    dim3 grid((threads + threadsperblock-1)/threadsperblock);
    dim3 block(threadsperblock);

    // Gr��e des dynamischen Shared Memory Bereichs
    size_t shared_size = 0;

    quark_bmw512_gpu_hash_80<<<grid, block, shared_size>>>(threads, startNounce, (uint64_t*)d_hash);

	cudaDeviceSynchronize();
}

#endif
