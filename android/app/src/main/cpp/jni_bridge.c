//  jni_bridge.c
//  JNI glue: exposes sv_nested / sv_staticnested / sv_darkside to Kotlin's
//  com.demomdl.chameleon.KeyRecovery object.

#include <jni.h>
#include "solver_shim.h"

#define MAXK 64

JNIEXPORT jlongArray JNICALL
Java_com_demomdl_chameleon_KeyRecovery_nested(JNIEnv *env, jobject thiz,
        jint uid, jint dist, jintArray nt, jintArray ntEnc, jbyteArray par) {
    jsize n = (*env)->GetArrayLength(env, nt);
    jint *pNt  = (*env)->GetIntArrayElements(env, nt, NULL);
    jint *pEnc = (*env)->GetIntArrayElements(env, ntEnc, NULL);
    jbyte *pPar = (*env)->GetByteArrayElements(env, par, NULL);

    uint64_t out[MAXK];
    int c = sv_nested((uint32_t)uid, (uint32_t)dist,
                      (const uint32_t *)pNt, (const uint32_t *)pEnc, (const uint8_t *)pPar,
                      (int)n, out, MAXK);

    (*env)->ReleaseIntArrayElements(env, nt, pNt, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, ntEnc, pEnc, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, par, pPar, JNI_ABORT);

    jlongArray res = (*env)->NewLongArray(env, c);
    if (c > 0) (*env)->SetLongArrayRegion(env, res, 0, c, (const jlong *)out);
    return res;
}

JNIEXPORT jlongArray JNICALL
Java_com_demomdl_chameleon_KeyRecovery_staticNested(JNIEnv *env, jobject thiz,
        jint uid, jint type, jintArray nt, jintArray ntEnc) {
    jsize n = (*env)->GetArrayLength(env, nt);
    jint *pNt  = (*env)->GetIntArrayElements(env, nt, NULL);
    jint *pEnc = (*env)->GetIntArrayElements(env, ntEnc, NULL);

    uint64_t out[MAXK];
    int c = sv_staticnested((uint32_t)uid, (uint8_t)type,
                            (const uint32_t *)pNt, (const uint32_t *)pEnc,
                            (int)n, out, MAXK);

    (*env)->ReleaseIntArrayElements(env, nt, pNt, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, ntEnc, pEnc, JNI_ABORT);

    jlongArray res = (*env)->NewLongArray(env, c);
    if (c > 0) (*env)->SetLongArrayRegion(env, res, 0, c, (const jlong *)out);
    return res;
}

JNIEXPORT jlongArray JNICALL
Java_com_demomdl_chameleon_KeyRecovery_darkside(JNIEnv *env, jobject thiz,
        jint uid, jintArray nt, jlongArray ksList, jlongArray parList,
        jintArray nr, jintArray ar) {
    jsize n = (*env)->GetArrayLength(env, nt);
    jint  *pNt = (*env)->GetIntArrayElements(env, nt, NULL);
    jlong *pKs = (*env)->GetLongArrayElements(env, ksList, NULL);
    jlong *pPar = (*env)->GetLongArrayElements(env, parList, NULL);
    jint  *pNr = (*env)->GetIntArrayElements(env, nr, NULL);
    jint  *pAr = (*env)->GetIntArrayElements(env, ar, NULL);

    uint64_t out[MAXK];
    int c = sv_darkside((uint32_t)uid,
                        (const uint32_t *)pNt, (const uint64_t *)pKs, (const uint64_t *)pPar,
                        (const uint32_t *)pNr, (const uint32_t *)pAr,
                        (int)n, out, MAXK);

    (*env)->ReleaseIntArrayElements(env, nt, pNt, JNI_ABORT);
    (*env)->ReleaseLongArrayElements(env, ksList, pKs, JNI_ABORT);
    (*env)->ReleaseLongArrayElements(env, parList, pPar, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, nr, pNr, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, ar, pAr, JNI_ABORT);

    jlongArray res = (*env)->NewLongArray(env, c);
    if (c > 0) (*env)->SetLongArrayRegion(env, res, 0, c, (const jlong *)out);
    return res;
}
