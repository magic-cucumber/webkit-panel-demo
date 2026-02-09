#pragma once

#include <jni.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
@class CALayer;
#endif

// 在主线程同步执行 block；若当前已在主线程则直接执行。
void runOnMainSync(void (^block)(void));

// 在主线程异步执行 block；若当前已在主线程则直接执行。
void runOnMainAsync(void (^block)(void));