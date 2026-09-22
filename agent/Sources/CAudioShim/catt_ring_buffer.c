#include "catt_ring_buffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CattRingBuffer {
    float* buffer;
    size_t capacitySamples; // capacityFrames * channels
    size_t channels;
    _Atomic size_t writePos; // sample index, not frame index
    _Atomic size_t readPos;
};

CattRingBuffer* catt_ring_buffer_create(size_t capacityFrames, size_t channels) {
    if (capacityFrames == 0 || channels == 0) return NULL;

    CattRingBuffer* rb = (CattRingBuffer*)calloc(1, sizeof(CattRingBuffer));
    if (!rb) return NULL;

    rb->channels = channels;
    rb->capacitySamples = capacityFrames * channels;
    rb->buffer = (float*)calloc(rb->capacitySamples, sizeof(float));
    if (!rb->buffer) {
        free(rb);
        return NULL;
    }
    atomic_store_explicit(&rb->writePos, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->readPos, 0, memory_order_relaxed);
    return rb;
}

void catt_ring_buffer_destroy(CattRingBuffer* rb) {
    if (!rb) return;
    free(rb->buffer);
    free(rb);
}

size_t catt_ring_buffer_available_for_read(const CattRingBuffer* rb) {
    size_t writeIdx = atomic_load_explicit((_Atomic size_t*)&rb->writePos, memory_order_acquire);
    size_t readIdx = atomic_load_explicit((_Atomic size_t*)&rb->readPos, memory_order_relaxed);
    size_t availSamples = (writeIdx >= readIdx)
        ? (writeIdx - readIdx)
        : (rb->capacitySamples - readIdx + writeIdx);
    return availSamples / rb->channels;
}

size_t catt_ring_buffer_available_for_write(const CattRingBuffer* rb) {
    size_t writeIdx = atomic_load_explicit((_Atomic size_t*)&rb->writePos, memory_order_relaxed);
    size_t readIdx = atomic_load_explicit((_Atomic size_t*)&rb->readPos, memory_order_acquire);
    size_t freeSamples = (readIdx > writeIdx)
        ? (readIdx - writeIdx - rb->channels)
        : (rb->capacitySamples - writeIdx + readIdx - rb->channels);
    return freeSamples / rb->channels;
}

size_t catt_ring_buffer_write(CattRingBuffer* rb, const float* data, size_t frameCount) {
    size_t available = catt_ring_buffer_available_for_write(rb);
    size_t framesToWrite = (frameCount > available) ? available : frameCount;
    size_t samplesToWrite = framesToWrite * rb->channels;
    if (samplesToWrite == 0) return 0;

    size_t writeIdx = atomic_load_explicit(&rb->writePos, memory_order_relaxed);
    size_t firstPart = rb->capacitySamples - writeIdx;

    if (samplesToWrite <= firstPart) {
        memcpy(rb->buffer + writeIdx, data, samplesToWrite * sizeof(float));
    } else {
        memcpy(rb->buffer + writeIdx, data, firstPart * sizeof(float));
        memcpy(rb->buffer, data + firstPart, (samplesToWrite - firstPart) * sizeof(float));
    }

    size_t newWritePos = (writeIdx + samplesToWrite) % rb->capacitySamples;
    atomic_store_explicit(&rb->writePos, newWritePos, memory_order_release);
    return framesToWrite;
}

size_t catt_ring_buffer_read(CattRingBuffer* rb, float* data, size_t frameCount) {
    size_t available = catt_ring_buffer_available_for_read(rb);
    size_t framesToRead = (frameCount > available) ? available : frameCount;
    size_t samplesToRead = framesToRead * rb->channels;

    if (samplesToRead == 0) {
        memset(data, 0, frameCount * rb->channels * sizeof(float));
        return 0;
    }

    size_t readIdx = atomic_load_explicit(&rb->readPos, memory_order_relaxed);
    size_t firstPart = rb->capacitySamples - readIdx;

    if (samplesToRead <= firstPart) {
        memcpy(data, rb->buffer + readIdx, samplesToRead * sizeof(float));
    } else {
        memcpy(data, rb->buffer + readIdx, firstPart * sizeof(float));
        memcpy(data + firstPart, rb->buffer, (samplesToRead - firstPart) * sizeof(float));
    }

    size_t newReadPos = (readIdx + samplesToRead) % rb->capacitySamples;
    atomic_store_explicit(&rb->readPos, newReadPos, memory_order_release);

    if (framesToRead < frameCount) {
        size_t silenceFrames = frameCount - framesToRead;
        memset(data + samplesToRead, 0, silenceFrames * rb->channels * sizeof(float));
    }

    return framesToRead;
}

void catt_ring_buffer_clear(CattRingBuffer* rb) {
    atomic_store_explicit(&rb->writePos, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->readPos, 0, memory_order_relaxed);
    memset(rb->buffer, 0, rb->capacitySamples * sizeof(float));
}
