#import "utils.h"

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>

void runOnMainSync(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

void runOnMainAsync(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

void println0(JNIEnv *env, const char *message) {
    if (env == nullptr) return;

    jclass sysClass = env->FindClass("java/lang/System");
    if (sysClass == nullptr) return;

    jfieldID outID = env->GetStaticFieldID(sysClass, "out", "Ljava/io/PrintStream;");
    if (outID == nullptr) return;

    jobject outObj = env->GetStaticObjectField(sysClass, outID);
    if (outObj == nullptr) return;

    jclass psClass = env->FindClass("java/io/PrintStream");
    if (psClass == nullptr) return;

    jmethodID printlnID = env->GetMethodID(psClass, "println", "(Ljava/lang/String;)V");
    if (printlnID == nullptr) return;

    jstring jmsg = env->NewStringUTF(message);
    env->CallVoidMethod(outObj, printlnID, jmsg);

    env->DeleteLocalRef(jmsg);
    env->DeleteLocalRef(sysClass);
    if (psClass != nullptr) env->DeleteLocalRef(psClass);
    if (outObj != nullptr) env->DeleteLocalRef(outObj);
}
