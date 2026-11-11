//  solver_shim.h
//  Clean, callable wrappers around the firmware's Crypto1 key-recovery solvers
//  (nested / staticnested / darkside), so Swift can call them directly instead
//  of shelling out to CLI executables. Each returns the number of candidate keys
//  written to `out` (capped at maxOut). Keys are 48-bit, packed in a uint64.

#ifndef SOLVER_SHIM_H
#define SOLVER_SHIM_H

#include <stdint.h>

// Dynamic nested attack. Inputs: uid, nonce distance, and n nonce triples.
int sv_nested(uint32_t uid, uint32_t dist,
              const uint32_t *nt, const uint32_t *nt_enc, const uint8_t *par, int n,
              uint64_t *out, int maxOut);

// Static nested attack. type is 0x60 (A) or 0x61 (B); n nonce pairs.
int sv_staticnested(uint32_t uid, uint8_t type,
                    const uint32_t *nt, const uint32_t *nt_enc, int n,
                    uint64_t *out, int maxOut);

// Darkside attack. n parameter sets: nt, ks_list, par_list, nr, ar.
int sv_darkside(uint32_t uid,
                const uint32_t *nt, const uint64_t *ks_list, const uint64_t *par_list,
                const uint32_t *nr, const uint32_t *ar, int n,
                uint64_t *out, int maxOut);

#endif /* SOLVER_SHIM_H */
