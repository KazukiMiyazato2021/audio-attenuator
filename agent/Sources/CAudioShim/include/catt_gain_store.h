#ifndef CATT_GAIN_STORE_H
#define CATT_GAIN_STORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Fixed-capacity table of per-slot gains, written by the UI/control thread and
// read from the audio callbacks. Backed by atomic floats so the audio thread
// never takes a lock or allocates to read a gain that the UI is changing.
//
// Slots are allocated once at setup for the maximum number of simultaneously
// tapped apps, so adding or removing a tap at runtime never resizes the table.
typedef struct CattGainStore CattGainStore;

// Not real-time safe (allocates) — setup only. All slots start at 1.0.
CattGainStore* catt_gain_store_create(size_t capacity);
void catt_gain_store_destroy(CattGainStore* store);

// Real-time safe. Out-of-range indices read as 1.0 / ignore the write.
float catt_gain_store_get(const CattGainStore* store, size_t index);
void catt_gain_store_set(CattGainStore* store, size_t index, float gain);

size_t catt_gain_store_capacity(const CattGainStore* store);

#ifdef __cplusplus
}
#endif

#endif
