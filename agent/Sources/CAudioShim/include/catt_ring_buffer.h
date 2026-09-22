#ifndef CATT_RING_BUFFER_H
#define CATT_RING_BUFFER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lock-free single-producer/single-consumer ring buffer for interleaved
// Float32 audio, ported from micloop's driver/src/RingBuffer.cpp so it can
// be called from Swift without enabling C++ interop.
typedef struct CattRingBuffer CattRingBuffer;

// capacityFrames: ring buffer size in frames. channels: samples per frame.
// Returns NULL on allocation failure. Not real-time safe (allocates) — call
// only during setup, never from an IOProc.
CattRingBuffer* catt_ring_buffer_create(size_t capacityFrames, size_t channels);

// Not real-time safe (frees) — call only during teardown, never from an IOProc.
void catt_ring_buffer_destroy(CattRingBuffer* rb);

// Real-time safe: no allocation, no locks, no blocking calls.
// Returns the number of frames actually written (less than frameCount if the
// buffer is full — excess input is dropped, not blocked on).
size_t catt_ring_buffer_write(CattRingBuffer* rb, const float* data, size_t frameCount);

// Real-time safe. Returns the number of frames actually read; any shortfall
// (buffer underrun) is filled with silence so the caller always gets a full,
// glitch-free buffer to hand to CoreAudio.
size_t catt_ring_buffer_read(CattRingBuffer* rb, float* data, size_t frameCount);

size_t catt_ring_buffer_available_for_read(const CattRingBuffer* rb);
size_t catt_ring_buffer_available_for_write(const CattRingBuffer* rb);

// Not real-time safe — call only while IO is stopped.
void catt_ring_buffer_clear(CattRingBuffer* rb);

#ifdef __cplusplus
}
#endif

#endif
