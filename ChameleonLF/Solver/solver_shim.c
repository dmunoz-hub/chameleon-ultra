//  solver_shim.c
//  Callable versions of nested.c / staticnested.c / darkside.c main(), adapted to
//  return candidate keys into a caller buffer instead of printing. Logic mirrors
//  the firmware tools verbatim.

#include "solver_shim.h"
#include "common.h"
#include "crapto1.h"
#include "nested_util.h"
#include "mfkey.h"

#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

int sv_nested(uint32_t uid, uint32_t dist,
              const uint32_t *nts, const uint32_t *ntencs, const uint8_t *pars, int n,
              uint64_t *out, int maxOut) {
    NtpKs1 *pNK = NULL;
    uint32_t j = 0, m;
    uint8_t par_arr[3] = { 0 };

    for (int i = 0; i < n; i++) {
        uint32_t nt1 = nts[i], nt2 = ntencs[i];
        uint8_t par_int = pars[i];
        if (par_int != 0) {
            for (m = 0; m < 3; m++) par_arr[m] = (par_int >> m) & 0x01;
        } else {
            memset(par_arr, 0, 3);
        }
        uint32_t nttest = prng_successor(nt1, dist - 14);
        for (m = dist - 14; m <= dist + 14; m += 1) {
            uint32_t ks1 = nt2 ^ nttest;
            if (valid_nonce(nttest, nt2, ks1, par_arr)) {
                void *tmp = realloc(pNK, sizeof(NtpKs1) * (j + 1));
                if (tmp == NULL) { free(pNK); return 0; }
                pNK = tmp;
                pNK[j].ntp = nttest;
                pNK[j].ks1 = ks1;
                j++;
            }
            nttest = prng_successor(nttest, 1);
        }
    }

    uint32_t keyCount = 0;
    uint64_t *keys = nested(pNK, j, uid, &keyCount);
    free(pNK);

    int c = 0;
    for (uint32_t i = 0; i < keyCount && c < maxOut; i++) out[c++] = keys[i];
    free(keys);
    return c;
}

int sv_staticnested(uint32_t uid, uint8_t type,
                    const uint32_t *nts, const uint32_t *ntencs, int n,
                    uint64_t *out, int maxOut) {
    NtpKs1 *pNK = NULL;
    uint32_t j = 0;
    uint32_t dist = 0;
    bool checked = false;

    for (int i = 0; i < n; i++) {
        uint32_t nt1 = nts[i], nt2 = ntencs[i];
        if (!checked) {
            if (nt1 == 0x01200145) {
                dist = 160;
            } else if (nt1 == 0x009080A2) {
                if (type == 0x61) dist = 161;
                else if (type == 0x60) dist = 160;
                else { free(pNK); return 0; }
            } else {
                free(pNK); return 0;
            }
            checked = true;
        }
        uint32_t nttest = prng_successor(nt1, dist);
        uint32_t ks1 = nt2 ^ nttest;
        void *tmp = realloc(pNK, sizeof(NtpKs1) * (j + 1));
        if (tmp == NULL) { free(pNK); return 0; }
        pNK = tmp;
        pNK[j].ntp = nttest;
        pNK[j].ks1 = ks1;
        j++;
        dist += 160;
    }

    uint32_t keyCount = 0;
    uint64_t *keys = nested(pNK, j, uid, &keyCount);
    free(pNK);

    int c = 0;
    for (uint32_t i = 0; i < keyCount && c < maxOut; i++) out[c++] = keys[i];
    free(keys);
    return c;
}

int sv_darkside(uint32_t uid,
                const uint32_t *nts, const uint64_t *ks_lists, const uint64_t *par_lists,
                const uint32_t *nrs, const uint32_t *ars, int n,
                uint64_t *out, int maxOut) {
    uint64_t *keylist = NULL, *last_keylist = NULL;
    uint32_t keycount = 0;
    int c = 0;

    for (int i = 0; i < n; i++) {
        uint32_t nt = nts[i], nr = nrs[i], ar = ars[i];
        uint64_t par_list = par_lists[i], ks_list = ks_lists[i];

        keycount = nonce2key(uid, nt, nr, ar, par_list, ks_list, &keylist);
        if (keycount == 0) continue;

        if (par_list == 0) {
            qsort(keylist, keycount, sizeof(*keylist), compare_uint64);
            keycount = intersection(last_keylist, keylist);
            if (keycount == 0) {
                free(last_keylist);
                last_keylist = keylist;
                continue;
            }
        }
        for (uint32_t j = 0; j < keycount && c < maxOut; j++) {
            out[c++] = (par_list == 0) ? last_keylist[j] : keylist[j];
        }
    }

    if (last_keylist == keylist && last_keylist != NULL) {
        free(keylist);
    } else {
        if (last_keylist) free(last_keylist);
        if (keylist) free(keylist);
    }
    return c;
}
