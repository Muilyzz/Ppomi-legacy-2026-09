#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern char *ppomi_accounting_report(const uint8_t *bytes, intptr_t count);
extern void ppomi_accounting_free(char *result);

JNIEXPORT jbyteArray JNICALL
Java_com_ppomi_androidbridge_SharedAccounting_nativeReport(JNIEnv *env, jclass cls, jbyteArray input) {
    (void)cls;
    if (input == NULL) return NULL;
    jsize count = (*env)->GetArrayLength(env, input);
    if (count > 4 * 1024 * 1024) return NULL;
    uint8_t *bytes = malloc(count > 0 ? (size_t)count : 1);
    if (bytes == NULL) return NULL;
    (*env)->GetByteArrayRegion(env, input, 0, count, (jbyte *)bytes);
    if ((*env)->ExceptionCheck(env)) { free(bytes); return NULL; }
    char *result = ppomi_accounting_report(bytes, (intptr_t)count);
    free(bytes);
    if (result == NULL) return NULL;
    size_t length = strlen(result);
    jbyteArray output = (*env)->NewByteArray(env, (jsize)length);
    if (output != NULL) (*env)->SetByteArrayRegion(env, output, 0, (jsize)length, (const jbyte *)result);
    ppomi_accounting_free(result);
    return output;
}
