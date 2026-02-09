#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

#import <jni.h>
#import <jawt.h>
#import <jawt_md.h>

#include <atomic>
#include <cstdint>

#import "utils.h"

struct WebViewContext {
    // ObjC 指针：只在主线程读写
    WKWebView *webView = nil;
    NSWindow *hostWindow = nil;
    NSView *hostView = nil;
    CALayer *rootLayer = nil;

    // paint0 -> 主线程：pending geometry
    std::atomic<jint> pendingW{0};
    std::atomic<jint> pendingH{0};
    std::atomic<jint> pendingScreenX{0};
    std::atomic<jint> pendingScreenY{0};

    // 合并调度：避免 paint0 每次都 dispatch
    std::atomic<bool> applyScheduled{false};

    // paint0 线程缓存
    jint lastW = 0;
    jint lastH = 0;
    jint lastScreenX = INT32_MIN;
    jint lastScreenY = INT32_MIN;
};

void updateOverlayLayerGeometry(CALayer *layer, jint w, jint h) {
    if (!layer) return;

    CGRect bounds = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    layer.bounds = bounds;
    layer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
}


bool getComponentLocationOnScreen(JNIEnv *env, jobject component, jint *outX, jint *outY) {
    if (!env || !component || !outX || !outY) return false;

    jclass compClass = env->FindClass("java/awt/Component");
    if (!compClass) return false;

    jmethodID mid = env->GetMethodID(compClass, "getLocationOnScreen", "()Ljava/awt/Point;");
    if (!mid) {
        env->DeleteLocalRef(compClass);
        return false;
    }

    jobject pointObj = env->CallObjectMethod(component, mid);
    if (!pointObj) {
        env->DeleteLocalRef(compClass);
        return false;
    }

    jclass pointClass = env->FindClass("java/awt/Point");
    if (!pointClass) {
        env->DeleteLocalRef(pointObj);
        env->DeleteLocalRef(compClass);
        return false;
    }

    jfieldID fidX = env->GetFieldID(pointClass, "x", "I");
    jfieldID fidY = env->GetFieldID(pointClass, "y", "I");
    if (!fidX || !fidY) {
        env->DeleteLocalRef(pointClass);
        env->DeleteLocalRef(pointObj);
        env->DeleteLocalRef(compClass);
        return false;
    }

    *outX = env->GetIntField(pointObj, fidX);
    *outY = env->GetIntField(pointObj, fidY);

    env->DeleteLocalRef(pointClass);
    env->DeleteLocalRef(pointObj);
    env->DeleteLocalRef(compClass);
    return true;
}

extern "C" JNIEXPORT jlong JNICALL
Java_top_kagg886_WebView_initAndAttach(JNIEnv *env, jobject thiz) {
    @autoreleasepool {
        // JAWT surface layers
        JAWT awt;
        awt.version = JAWT_VERSION_1_4 | JAWT_MACOSX_USE_CALAYER;
        if (JAWT_GetAWT(env, &awt) == JNI_FALSE) return 0;

        JAWT_DrawingSurface *ds = awt.GetDrawingSurface(env, thiz);
        if (!ds) return 0;

        jint lock = ds->Lock(ds);
        if (lock & JAWT_LOCK_ERROR) {
            awt.FreeDrawingSurface(ds);
            return 0;
        }

        JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds);
        if (!dsi) {
            ds->Unlock(ds);
            awt.FreeDrawingSurface(ds);
            return 0;
        }

        id<JAWT_SurfaceLayers> surfaceLayers = (__bridge id<JAWT_SurfaceLayers>)dsi->platformInfo;
        if (!surfaceLayers) {
            ds->FreeDrawingSurfaceInfo(dsi);
            ds->Unlock(ds);
            awt.FreeDrawingSurface(ds);
            return 0;
        }

        const jint w = dsi->bounds.width;
        const jint h = dsi->bounds.height;

        WebViewContext *ctx = new WebViewContext();
        ctx->pendingW.store(w, std::memory_order_relaxed);
        ctx->pendingH.store(h, std::memory_order_relaxed);
        ctx->pendingScreenX.store(0, std::memory_order_relaxed);
        ctx->pendingScreenY.store(0, std::memory_order_relaxed);
        ctx->lastW = w;
        ctx->lastH = h;

        runOnMainSync(^{
            // 1) overlay layer（用于 JAWT CALayer surface）
            ctx->rootLayer = [CALayer layer];
            ctx->rootLayer.masksToBounds = YES;
            ctx->rootLayer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] CGColor];
            ctx->rootLayer.borderColor = [[NSColor redColor] CGColor];
            ctx->rootLayer.borderWidth = 2.0;
            updateOverlayLayerGeometry(ctx->rootLayer, w, h);

            // 2) WKWebView
            WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
            config.defaultWebpagePreferences.allowsContentJavaScript = YES;
            config.preferences.javaScriptCanOpenWindowsAutomatically = YES;

            WKWebView *wv = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, w, h) configuration:config];
            wv.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15";
            wv.hidden = NO;

            // 3) Load url
            NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.baidu.com"]];
            [wv loadRequest:req];

            ctx->webView = wv;

            // 3) 挂到 keyWindow.contentView（保证可见）
            NSWindow *win = [NSApp keyWindow];
            if (win && win.contentView) {
                ctx->hostWindow = win;
                ctx->hostView = win.contentView;
                [ctx->hostView addSubview:wv positioned:NSWindowAbove relativeTo:nil];
            }
        });

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        surfaceLayers.layer = ctx->rootLayer;
        [CATransaction commit];
        [CATransaction flush];

        ds->FreeDrawingSurfaceInfo(dsi);
        ds->Unlock(ds);
        awt.FreeDrawingSurface(ds);

        return (jlong)(uintptr_t)ctx;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_top_kagg886_WebView_paint0(JNIEnv *env, jobject thiz, jobject graphics, jlong handle) {
    (void)graphics;

    @autoreleasepool {
        if (handle == 0) return;
        auto *ctx = (WebViewContext *)(uintptr_t)handle;
        if (!ctx) return;

        JAWT awt;
        awt.version = JAWT_VERSION_1_4 | JAWT_MACOSX_USE_CALAYER;
        if (JAWT_GetAWT(env, &awt) == JNI_FALSE) return;

        JAWT_DrawingSurface *ds = awt.GetDrawingSurface(env, thiz);
        if (!ds) return;

        jint lock = ds->Lock(ds);
        if (lock & JAWT_LOCK_ERROR) {
            awt.FreeDrawingSurface(ds);
            return;
        }

        JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds);
        if (!dsi) {
            ds->Unlock(ds);
            awt.FreeDrawingSurface(ds);
            return;
        }

        const jint w = dsi->bounds.width;
        const jint h = dsi->bounds.height;

        bool needUpdate = false;
        if (w != ctx->lastW || h != ctx->lastH || (lock & JAWT_LOCK_BOUNDS_CHANGED)) {
            ctx->lastW = w;
            ctx->lastH = h;
            ctx->pendingW.store(w, std::memory_order_relaxed);
            ctx->pendingH.store(h, std::memory_order_relaxed);
            needUpdate = true;
        }

        jint sx = 0, sy = 0;
        if (getComponentLocationOnScreen(env, thiz, &sx, &sy)) {
            if (sx != ctx->lastScreenX || sy != ctx->lastScreenY) {
                ctx->lastScreenX = sx;
                ctx->lastScreenY = sy;
                ctx->pendingScreenX.store(sx, std::memory_order_relaxed);
                ctx->pendingScreenY.store(sy, std::memory_order_relaxed);
                needUpdate = true;
            }
        }

        if (needUpdate) {
            bool expected = false;
            if (ctx->applyScheduled.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
                runOnMainAsync(^{
                    const jint pw = ctx->pendingW.load(std::memory_order_relaxed);
                    const jint ph = ctx->pendingH.load(std::memory_order_relaxed);
                    const jint psx = ctx->pendingScreenX.load(std::memory_order_relaxed);
                    const jint psy = ctx->pendingScreenY.load(std::memory_order_relaxed);

                    updateOverlayLayerGeometry(ctx->rootLayer, pw, ph);

                    if (ctx->webView && ctx->hostWindow && ctx->hostView) {
                        // Java 屏幕坐标：左上原点；Cocoa：左下原点（以主屏为参照）
                        CGFloat primaryH = NSScreen.mainScreen.frame.size.height;
                        NSRect cocoaScreenRect = NSMakeRect((CGFloat)psx,
                                                           primaryH - (CGFloat)psy - (CGFloat)ph,
                                                           (CGFloat)pw,
                                                           (CGFloat)ph);
                        NSRect windowRect = [ctx->hostWindow convertRectFromScreen:cocoaScreenRect];
                        NSRect target = [ctx->hostView convertRect:windowRect fromView:nil];

                        ctx->webView.frame = target;
                        [ctx->webView setNeedsLayout:YES];
                        [ctx->webView layoutSubtreeIfNeeded];
                    }

                    ctx->applyScheduled.store(false, std::memory_order_release);
                });
            }
        }

        ds->FreeDrawingSurfaceInfo(dsi);
        ds->Unlock(ds);
        awt.FreeDrawingSurface(ds);
    }
}
