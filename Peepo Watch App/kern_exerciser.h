//
//  kern_exerciser.h
//  Peepo Watch App
//
//  Created by Luke on 2026-01-24.
//

#ifndef kern_exerciser_h
#define kern_exerciser_h

// kern_exerciser.h
// Public interface for kern_exerciser.c

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Start the multithreaded exerciser.
// seed: 32-bit seed; same seed -> same pseudo-random choices (best-effort).
// duration_seconds: 0 disables duration limit (runs until steps_per_worker completes or exerciser_stop()).
// worker_count: number of worker threads (recommended 1-4 on watchOS).
// steps_per_worker: max steps per worker thread; 0 uses a default.
void exerciser_start(uint32_t seed, uint64_t duration_seconds, int worker_count, uint64_t steps_per_worker);

// Request stop and join threads (safe to call multiple times).
void exerciser_stop(void);

// Convenience: returns a time-based seed (non-cryptographic).
uint32_t exerciser_seed_from_time(void);

#ifdef __cplusplus
}
#endif

#endif /* kern_exerciser_h */
