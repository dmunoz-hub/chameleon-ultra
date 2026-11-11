cmake_minimum_required(VERSION 3.22.1)
project(solver C)

# The firmware's Crypto1 key-recovery solvers + a JNI bridge, built as libsolver.so.
# Android's bionic libc provides pthreads (used by nested_util.c) — no extra linking.
add_library(solver SHARED
    common.c
    crapto1.c
    crypto1.c
    bucketsort.c
    parity.c
    nested_util.c
    mfkey.c
    solver_shim.c
    jni_bridge.c)

target_compile_options(solver PRIVATE -O3 -w)
