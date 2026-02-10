#pragma once

#include <jni.h>
#include <sstream>
#include <string>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
@class CALayer;
#endif

#ifndef __UTILS_H

// 在主线程同步执行 block；若当前已在主线程则直接执行。
void runOnMainSync(void (^block)(void));

// 在主线程异步执行 block；若当前已在主线程则直接执行。
void runOnMainAsync(void (^block)(void));

void println0(JNIEnv *env, const char *message);



// 1. 内部辅助函数：使用模板递归或折叠表达式拼接参数
template <typename... Args>
std::string formatArgs(Args&&... args) {
    std::stringstream ss;
    // 使用 C++17 折叠表达式 (Fold Expression) 拼接所有参数
    (ss << ... << std::forward<Args>(args));
    return ss.str();
}

// 2. 包装函数：衔接你的原始 println 逻辑
template <typename... Args>
void jni_println_wrapper(JNIEnv *env, Args&&... args) {
    std::string message = formatArgs(std::forward<Args>(args)...);
    println0(env, message.c_str()); // 调用你提供的原始函数
}


#define printlnEnv(env, ...) jni_println_wrapper(env, __VA_ARGS__)

#define println(...) jni_println_wrapper(env, __VA_ARGS__)

#include <jni.h>

#define API_EXPORT(rtn, name, ...) \
    extern "C" JNIEXPORT rtn JNICALL Java_top_kagg886_wvbridge_WebView_##name(JNIEnv *env, jobject thiz, ##__VA_ARGS__)
#endif
