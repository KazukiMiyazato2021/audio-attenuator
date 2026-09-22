#include "catt_gain_store.h"

#include <stdatomic.h>
#include <stdlib.h>

struct CattGainStore {
    _Atomic float* gains;
    size_t capacity;
};

CattGainStore* catt_gain_store_create(size_t capacity) {
    if (capacity == 0) return NULL;

    CattGainStore* store = (CattGainStore*)calloc(1, sizeof(CattGainStore));
    if (!store) return NULL;

    store->gains = (_Atomic float*)calloc(capacity, sizeof(_Atomic float));
    if (!store->gains) {
        free(store);
        return NULL;
    }
    store->capacity = capacity;
    for (size_t i = 0; i < capacity; i++) {
        atomic_store_explicit(&store->gains[i], 1.0f, memory_order_relaxed);
    }
    return store;
}

void catt_gain_store_destroy(CattGainStore* store) {
    if (!store) return;
    free(store->gains);
    free(store);
}

float catt_gain_store_get(const CattGainStore* store, size_t index) {
    if (!store || index >= store->capacity) return 1.0f;
    return atomic_load_explicit(&store->gains[index], memory_order_relaxed);
}

void catt_gain_store_set(CattGainStore* store, size_t index, float gain) {
    if (!store || index >= store->capacity) return;
    atomic_store_explicit(&store->gains[index], gain, memory_order_relaxed);
}

size_t catt_gain_store_capacity(const CattGainStore* store) {
    return store ? store->capacity : 0;
}
