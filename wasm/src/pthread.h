/* pthread.h — synchronous shim.
 *
 * nested_util.c includes "pthread.h" (quoted, so this local file wins over the
 * system header). The nested solver spawns THREAD_MAX worker threads that each
 * write their results into their own RecPar arg and return NULL; the return
 * value is discarded by pthread_join. Running them synchronously therefore
 * produces identical results — just on one thread.
 *
 * This lets us compile WITHOUT -pthread, so the WASM needs no SharedArrayBuffer
 * and no COOP/COEP headers, and can be served from any static host (Vercel,
 * python -m http.server, etc.).
 */
#ifndef PTHREAD_SHIM_H
#define PTHREAD_SHIM_H

typedef unsigned long pthread_t;
typedef int pthread_attr_t;

static inline int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                                 void *(*start_routine)(void *), void *arg) {
    (void)thread; (void)attr;
    start_routine(arg);   /* run synchronously */
    return 0;
}

static inline int pthread_join(pthread_t thread, void **retval) {
    (void)thread;
    if (retval) *retval = (void *)0;
    return 0;
}

#endif /* PTHREAD_SHIM_H */
