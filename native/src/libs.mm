#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <Cocoa/Cocoa.h>
#import <jni.h>
#import <jawt_md.h>

#include "jawt.h"
#import <QuartzCore/QuartzCore.h>

#include <assert.h>
#include <dispatch/dispatch.h>
#include <atomic>
#include <cstdint>

static void println(JNIEnv *env, const char *message) {
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

static inline void runOnMainSync(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static inline void runOnMainAsync(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static bool getComponentLocationOnScreen(JNIEnv *env, jobject component, jint *outX, jint *outY) {
    if (!env || !component || !outX || !outY) return false;

    jclass compClass = env->FindClass("java/awt/Component");
    if (!compClass) return false;

    jmethodID mid = env->GetMethodID(compClass, "getLocationOnScreen", "()Ljava/awt/Point;");
    if (!mid) {
        env->DeleteLocalRef(compClass);
        return false;
    }

    jobject pointObj = env->CallObjectMethod(component, mid);
    if (env->ExceptionCheck()) {
        // 组件还未 showing 时可能抛 IllegalComponentStateException
        env->ExceptionClear();
        env->DeleteLocalRef(compClass);
        return false;
    }
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

struct WebViewContext {
    // 仅允许主线程读写以下 ObjC 指针字段（尽量只在主线程操作 view）
    WKWebView *webView;
    NSWindow *hostWindow;
    NSView *hostView;

    // JAWT overlay layer（调试用）：如果它都不显示，说明 JAWT overlay 模式没生效
    CALayer *rootLayer;

    // pending geometry（paint0 -> 主线程）
    std::atomic<jint> pendingW;
    std::atomic<jint> pendingH;
    std::atomic<jint> pendingScreenX; // Java 屏幕坐标：左上为原点
    std::atomic<jint> pendingScreenY;

    std::atomic<bool> dirty;
    std::atomic<bool> applyScheduled;

    // paint0 线程缓存：减少无意义调度
    jint lastW;
    jint lastH;
    jint lastScreenX;
    jint lastScreenY;
};

static void updateOverlayLayerGeometry(WebViewContext *ctx, jint w, jint h) {
    if (!ctx || !ctx->rootLayer) return;

    // 参考你给的 libs.mm_backup：用 bounds + position
    CGRect bounds = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    ctx->rootLayer.bounds = bounds;
    ctx->rootLayer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);

    // 仅更新 webView.layer 的几何信息（CALayer），避免触碰 WKWebView 的 view API
    if (ctx->webView && ctx->webView.layer) {
        ctx->webView.layer.frame = bounds;
    }
}

static void attachLayerToSurface(id<JAWT_SurfaceLayers> surfaceLayers, CALayer *layer) {
    if (!surfaceLayers || !layer) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    surfaceLayers.layer = layer;
    [CATransaction commit];
    [CATransaction flush];
}

extern "C" JNIEXPORT jlong JNICALL
Java_top_kagg886_WebView_initAndAttach(JNIEnv *env, jobject thiz) {
    @autoreleasepool {
        println(env, "[trace][initAndAttach] enter");
        JavaVM *jvm = nullptr;
        println(env, "[trace][initAndAttach] env->GetJavaVM(&jvm)");
        env->GetJavaVM(&jvm);

        println(env, "[trace][initAndAttach] println(native called)");
        println(env, "[native] initAndAttach() called");

        // 获取 JAWT（按官方注释：<1.7 需要 OR JAWT_MACOSX_USE_CALAYER）
        println(env, "[trace][initAndAttach] JAWT awt");
        JAWT awt;
        println(env, "[trace][initAndAttach] awt.version = ...");
        awt.version = JAWT_VERSION_1_4 | JAWT_MACOSX_USE_CALAYER;
        println(env, "[trace][initAndAttach] jboolean ok = JAWT_GetAWT(...)");
        jboolean ok = JAWT_GetAWT(env, &awt);
        println(env, "[trace][initAndAttach] if (ok == JNI_FALSE)");
        if (ok == JNI_FALSE) {
            println(env, "[trace][initAndAttach] println(JAWT_GetAWT failed)");
            println(env, "[native] JAWT_GetAWT failed");
            println(env, "[trace][initAndAttach] return 0");
            return 0;
        }

        println(env, "[trace][initAndAttach] JAWT_DrawingSurface *ds = awt.GetDrawingSurface(...)");
        JAWT_DrawingSurface *ds = awt.GetDrawingSurface(env, thiz);
        println(env, "[trace][initAndAttach] if (!ds)");
        if (!ds) {
            println(env, "[trace][initAndAttach] println(GetDrawingSurface null)");
            println(env, "[native] GetDrawingSurface returned null (component not realized?)");
            println(env, "[trace][initAndAttach] return 0");
            return 0;
        }

        println(env, "[trace][initAndAttach] jint lock = ds->Lock(ds)");
        jint lock = ds->Lock(ds);
        println(env, "[trace][initAndAttach] if (lock & JAWT_LOCK_ERROR)");
        if (lock & JAWT_LOCK_ERROR) {
            println(env, "[trace][initAndAttach] println(Lock DrawingSurface failed)");
            println(env, "[native] Lock DrawingSurface failed");
            println(env, "[trace][initAndAttach] awt.FreeDrawingSurface(ds)");
            awt.FreeDrawingSurface(ds);
            println(env, "[trace][initAndAttach] return 0");
            return 0;
        }

        println(env, "[trace][initAndAttach] JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds)");
        JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds);
        println(env, "[trace][initAndAttach] if (!dsi)");
        if (!dsi) {
            println(env, "[trace][initAndAttach] println(GetDrawingSurfaceInfo null)");
            println(env, "[native] GetDrawingSurfaceInfo returned null");
            println(env, "[trace][initAndAttach] ds->Unlock(ds)");
            ds->Unlock(ds);
            println(env, "[trace][initAndAttach] awt.FreeDrawingSurface(ds)");
            awt.FreeDrawingSurface(ds);
            println(env, "[trace][initAndAttach] return 0");
            return 0;
        }

        println(env, "[trace][initAndAttach] surfaceLayers = (__bridge ... )dsi->platformInfo");
        id<JAWT_SurfaceLayers> surfaceLayers = (__bridge id<JAWT_SurfaceLayers>)dsi->platformInfo;
        println(env, "[trace][initAndAttach] if (!surfaceLayers)");
        if (!surfaceLayers) {
            println(env, "[trace][initAndAttach] println(platformInfo null)");
            println(env, "[native] platformInfo is null; cannot get JAWT_SurfaceLayers");
            println(env, "[trace][initAndAttach] ds->FreeDrawingSurfaceInfo(dsi)");
            ds->FreeDrawingSurfaceInfo(dsi);
            println(env, "[trace][initAndAttach] ds->Unlock(ds)");
            ds->Unlock(ds);
            println(env, "[trace][initAndAttach] awt.FreeDrawingSurface(ds)");
            awt.FreeDrawingSurface(ds);
            println(env, "[trace][initAndAttach] return 0");
            return 0;
        }

        println(env, "[trace][initAndAttach] const jint w = dsi->bounds.width");
        const jint w = dsi->bounds.width;
        println(env, "[trace][initAndAttach] const jint h = dsi->bounds.height");
        const jint h = dsi->bounds.height;

        println(env, "[trace][initAndAttach] WebViewContext *ctx = new WebViewContext()");
        WebViewContext *ctx = new WebViewContext();
        println(env, "[trace][initAndAttach] ctx->webView = nil");
        ctx->webView = nil;
        println(env, "[trace][initAndAttach] ctx->hostWindow = nil");
        ctx->hostWindow = nil;
        println(env, "[trace][initAndAttach] ctx->hostView = nil");
        ctx->hostView = nil;
        println(env, "[trace][initAndAttach] ctx->rootLayer = nil");
        ctx->rootLayer = nil;

        println(env, "[trace][initAndAttach] pendingW.store(w)");
        ctx->pendingW.store(w, std::memory_order_relaxed);
        println(env, "[trace][initAndAttach] pendingH.store(h)");
        ctx->pendingH.store(h, std::memory_order_relaxed);
        println(env, "[trace][initAndAttach] pendingScreenX.store(0)");
        ctx->pendingScreenX.store(0, std::memory_order_relaxed);
        println(env, "[trace][initAndAttach] pendingScreenY.store(0)");
        ctx->pendingScreenY.store(0, std::memory_order_relaxed);

        println(env, "[trace][initAndAttach] dirty.store(false)");
        ctx->dirty.store(false, std::memory_order_relaxed);
        println(env, "[trace][initAndAttach] applyScheduled.store(false)");
        ctx->applyScheduled.store(false, std::memory_order_relaxed);

        println(env, "[trace][initAndAttach] ctx->lastW = w");
        ctx->lastW = w;
        println(env, "[trace][initAndAttach] ctx->lastH = h");
        ctx->lastH = h;
        println(env, "[trace][initAndAttach] ctx->lastScreenX = INT32_MIN");
        ctx->lastScreenX = INT32_MIN;
        println(env, "[trace][initAndAttach] ctx->lastScreenY = INT32_MIN");
        ctx->lastScreenY = INT32_MIN;

        // 主线程：创建 WKWebView，并尽最大可能挂到窗口的 contentView
        println(env, "[trace][initAndAttach] runOnMainSync(block)");
        runOnMainSync(^{
            JNIEnv *menv = nullptr;
            bool detach = false;
            if (jvm) {
                jint ge = jvm->GetEnv((void **)&menv, JNI_VERSION_1_6);
                if (ge == JNI_EDETACHED) {
                    if (jvm->AttachCurrentThread((void **)&menv, nullptr) == JNI_OK) {
                        detach = true;
                    }
                }
            }

            // 1) 先创建一个 overlay layer（调试：若它都不显示，说明 JAWT overlay 没挂上）
            println(menv, "[trace][initAndAttach][main] ctx->rootLayer = [CALayer layer]");
            ctx->rootLayer = [CALayer layer];
            println(menv, "[trace][initAndAttach][main] ctx->rootLayer.masksToBounds = YES");
            ctx->rootLayer.masksToBounds = YES;
            println(menv, "[trace][initAndAttach][main] ctx->rootLayer.backgroundColor = ...");
            ctx->rootLayer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] CGColor];
            println(menv, "[trace][initAndAttach][main] ctx->rootLayer.borderColor = ...");
            ctx->rootLayer.borderColor = [[NSColor redColor] CGColor];
            println(menv, "[trace][initAndAttach][main] ctx->rootLayer.borderWidth = 2.0");
            ctx->rootLayer.borderWidth = 2.0;

            println(menv, "[trace][initAndAttach][main] updateOverlayLayerGeometry(ctx, w, h)");
            updateOverlayLayerGeometry(ctx, w, h);

            // 放一个可见的三角形 + 文本
            println(menv, "[trace][initAndAttach][main] begin triangle/text block");
            {
                println(menv, "[trace][initAndAttach][main] CAShapeLayer *shapeLayer = ...");
                CAShapeLayer *shapeLayer = [CAShapeLayer layer];
                println(menv, "[trace][initAndAttach][main] CGMutablePathRef path = ...");
                CGMutablePathRef path = CGPathCreateMutable();
                println(menv, "[trace][initAndAttach][main] CGFloat cw = (CGFloat)w");
                CGFloat cw = (CGFloat)w;
                println(menv, "[trace][initAndAttach][main] CGFloat ch = (CGFloat)h");
                CGFloat ch = (CGFloat)h;
                println(menv, "[trace][initAndAttach][main] CGFloat size = fmin(cw, ch) * 0.35");
                CGFloat size = fmin(cw, ch) * 0.35;
                println(menv, "[trace][initAndAttach][main] centerX/centerY");
                CGFloat centerX = cw / 2.0;
                CGFloat centerY = ch / 2.0;
                println(menv, "[trace][initAndAttach][main] CGPoint p1 = ...");
                CGPoint p1 = CGPointMake(centerX, centerY - size);
                println(menv, "[trace][initAndAttach][main] CGPoint p2 = ...");
                CGPoint p2 = CGPointMake(centerX - size * 0.866, centerY + size * 0.5);
                println(menv, "[trace][initAndAttach][main] CGPoint p3 = ...");
                CGPoint p3 = CGPointMake(centerX + size * 0.866, centerY + size * 0.5);
                println(menv, "[trace][initAndAttach][main] CGPathMoveToPoint");
                CGPathMoveToPoint(path, nullptr, p1.x, p1.y);
                println(menv, "[trace][initAndAttach][main] CGPathAddLineToPoint p2");
                CGPathAddLineToPoint(path, nullptr, p2.x, p2.y);
                println(menv, "[trace][initAndAttach][main] CGPathAddLineToPoint p3");
                CGPathAddLineToPoint(path, nullptr, p3.x, p3.y);
                println(menv, "[trace][initAndAttach][main] CGPathCloseSubpath");
                CGPathCloseSubpath(path);
                println(menv, "[trace][initAndAttach][main] shapeLayer.path = path");
                shapeLayer.path = path;
                println(menv, "[trace][initAndAttach][main] shapeLayer.fillColor = ...");
                shapeLayer.fillColor = [[NSColor colorWithCalibratedRed:0.2 green:0.4 blue:1.0 alpha:0.3] CGColor];
                println(menv, "[trace][initAndAttach][main] shapeLayer.strokeColor = ...");
                shapeLayer.strokeColor = [[NSColor blueColor] CGColor];
                println(menv, "[trace][initAndAttach][main] shapeLayer.lineWidth = 2.0");
                shapeLayer.lineWidth = 2.0;
                println(menv, "[trace][initAndAttach][main] shapeLayer.frame = ctx->rootLayer.bounds");
                shapeLayer.frame = ctx->rootLayer.bounds;
                println(menv, "[trace][initAndAttach][main] [ctx->rootLayer addSublayer:shapeLayer]");
                [ctx->rootLayer addSublayer:shapeLayer];
                println(menv, "[trace][initAndAttach][main] CGPathRelease(path)");
                CGPathRelease(path);

                println(menv, "[trace][initAndAttach][main] CATextLayer *text = ...");
                CATextLayer *text = [CATextLayer layer];
                println(menv, "[trace][initAndAttach][main] text.string = ...");
                text.string = @"JAWT layer attached";
                println(menv, "[trace][initAndAttach][main] text.foregroundColor = ...");
                text.foregroundColor = [[NSColor blackColor] CGColor];
                println(menv, "[trace][initAndAttach][main] text.fontSize = 14");
                text.fontSize = 14;
                println(menv, "[trace][initAndAttach][main] text.contentsScale = ...");
                text.contentsScale = NSScreen.mainScreen.backingScaleFactor;
                println(menv, "[trace][initAndAttach][main] text.frame = ...");
                text.frame = CGRectMake(8, 8, 220, 20);
                println(menv, "[trace][initAndAttach][main] [ctx->rootLayer addSublayer:text]");
                [ctx->rootLayer addSublayer:text];
            }

            // 2) 创建 WKWebView
            println(menv, "[trace][initAndAttach][main] WKWebViewConfiguration *config = ...");
            WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
            println(menv, "[trace][initAndAttach][main] WKWebView *wv = [[WKWebView alloc] initWithFrame:...]");
            WKWebView *wv = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, w, h) configuration:config];
            println(menv, "[trace][initAndAttach][main] if ([wv respondsToSelector:...])");
            if ([wv respondsToSelector:@selector(setDrawsBackground:)]) {
                println(menv, "[trace][initAndAttach][main] (drawsBackground line is commented out)");
//                wv.drawsBackground = YES;
            }
            println(menv, "[trace][initAndAttach][main] wv.hidden = NO");
            wv.hidden = NO;

            println(menv, "[trace][initAndAttach][main] NSString *html = ...");
            NSString *html = @"<!doctype html><html><head><meta charset='utf-8'>"
                              "<style>body{font-family:-apple-system,Helvetica,Arial; margin:24px;}"
                              "h1{font-size:20px;} .box{padding:12px;border:1px solid #ddd;border-radius:8px;}"
                              "</style></head><body>"
                              "<h1>WKWebView embedded in AWT</h1>"
                              "<div class='box'>If you see this page, NSView embedding works.</div>"
                              "</body></html>";
            println(menv, "[trace][initAndAttach][main] [wv loadHTMLString:html baseURL:nil]");
            [wv loadHTMLString:html baseURL:nil];
            println(menv, "[trace][initAndAttach][main] ctx->webView = wv");
            ctx->webView = wv;

            // 3) 尝试把 WKWebView 作为 subview 加到当前 keyWindow 的 contentView 上（优先保证能显示）
            println(menv, "[trace][initAndAttach][main] NSWindow *win = [NSApp keyWindow]");
            NSWindow *win = [NSApp keyWindow];
            println(menv, "[trace][initAndAttach][main] if (!win) win = [NSApp mainWindow]");
            if (!win) win = [NSApp mainWindow];
            println(menv, "[trace][initAndAttach][main] if (win && win.contentView)");
            if (win && win.contentView) {
                println(menv, "[trace][initAndAttach][main] ctx->hostWindow = win");
                ctx->hostWindow = win;
                println(menv, "[trace][initAndAttach][main] ctx->hostView = win.contentView");
                ctx->hostView = win.contentView;
                // 放到最上层，避免被 AWT view 覆盖
                println(menv, "[trace][initAndAttach][main] [ctx->hostView addSubview:wv positioned:...]");
                [ctx->hostView addSubview:wv positioned:NSWindowAbove relativeTo:nil];
            }

            if (detach && jvm) {
                jvm->DetachCurrentThread();
            }
        });

        // 在 ds lock 生命周期内，把 overlay layer 挂到 surface 上（不切线程）
        println(env, "[trace][initAndAttach] attachLayerToSurface(surfaceLayers, ctx->rootLayer)");
        attachLayerToSurface(surfaceLayers, ctx->rootLayer);

        // 打印是否找到了宿主窗口
        println(env, "[trace][initAndAttach] if (ctx->hostView)");
        if (ctx->hostView) {
            println(env, "[trace][initAndAttach] println(WKWebView attached)");
            println(env, "[native] WKWebView attached to keyWindow.contentView");
        } else {
            println(env, "[trace][initAndAttach] println(no keyWindow/mainWindow)");
            println(env, "[native] no keyWindow/mainWindow yet; will retry on paint0");
        }

        println(env, "[trace][initAndAttach] ds->FreeDrawingSurfaceInfo(dsi)");
        ds->FreeDrawingSurfaceInfo(dsi);
        println(env, "[trace][initAndAttach] ds->Unlock(ds)");
        ds->Unlock(ds);
        println(env, "[trace][initAndAttach] awt.FreeDrawingSurface(ds)");
        awt.FreeDrawingSurface(ds);

        println(env, "[trace][initAndAttach] println(success)");
        println(env, "[native] initAndAttach() success");
        println(env, "[trace][initAndAttach] return ctx handle");
        return (jlong)(uintptr_t)ctx;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_top_kagg886_WebView_paint0(JNIEnv *env, jobject thiz, jobject graphics, jlong handle) {
    (void)graphics;

    @autoreleasepool {
        println(env, "[trace][paint0] enter");
        JavaVM *jvm = nullptr;
        println(env, "[trace][paint0] env->GetJavaVM(&jvm)");
        env->GetJavaVM(&jvm);

        println(env, "[trace][paint0] if (handle == 0) return");
        if (handle == 0) return;
        println(env, "[trace][paint0] WebViewContext *ctx = (WebViewContext*)handle");
        WebViewContext *ctx = (WebViewContext *)(uintptr_t)handle;
        println(env, "[trace][paint0] if (!ctx) return");
        if (!ctx) return;

        println(env, "[trace][paint0] JAWT awt");
        JAWT awt;
        println(env, "[trace][paint0] awt.version = ...");
        awt.version = JAWT_VERSION_1_4 | JAWT_MACOSX_USE_CALAYER;
        println(env, "[trace][paint0] jboolean ok = JAWT_GetAWT(...)");
        jboolean ok = JAWT_GetAWT(env, &awt);
        println(env, "[trace][paint0] if (ok == JNI_FALSE) return");
        if (ok == JNI_FALSE) return;

        println(env, "[trace][paint0] JAWT_DrawingSurface *ds = awt.GetDrawingSurface(...)");
        JAWT_DrawingSurface *ds = awt.GetDrawingSurface(env, thiz);
        println(env, "[trace][paint0] if (!ds) return");
        if (!ds) return;

        println(env, "[trace][paint0] jint lock = ds->Lock(ds)");
        jint lock = ds->Lock(ds);
        println(env, "[trace][paint0] if (lock & JAWT_LOCK_ERROR)");
        if (lock & JAWT_LOCK_ERROR) {
            println(env, "[trace][paint0] awt.FreeDrawingSurface(ds)");
            awt.FreeDrawingSurface(ds);
            println(env, "[trace][paint0] return");
            return;
        }

        println(env, "[trace][paint0] JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds)");
        JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds);
        println(env, "[trace][paint0] if (!dsi)");
        if (!dsi) {
            println(env, "[trace][paint0] ds->Unlock(ds)");
            ds->Unlock(ds);
            println(env, "[trace][paint0] awt.FreeDrawingSurface(ds)");
            awt.FreeDrawingSurface(ds);
            println(env, "[trace][paint0] return");
            return;
        }

        println(env, "[trace][paint0] const jint w = dsi->bounds.width");
        const jint w = dsi->bounds.width;
        println(env, "[trace][paint0] const jint h = dsi->bounds.height");
        const jint h = dsi->bounds.height;
        println(env, "[trace][paint0] surfaceLayers = (__bridge ... )dsi->platformInfo");
        id<JAWT_SurfaceLayers> surfaceLayers = (__bridge id<JAWT_SurfaceLayers>)dsi->platformInfo;

        // 1) 确保 overlay layer 仍然 attach（不走 dispatch_sync；这一步很轻量）
        println(env, "[trace][paint0] ensure overlay layer attached");
        if (surfaceLayers && ctx->rootLayer && surfaceLayers.layer != ctx->rootLayer) {
            println(env, "[trace][paint0] attachLayerToSurface(surfaceLayers, ctx->rootLayer)");
            attachLayerToSurface(surfaceLayers, ctx->rootLayer);
        }

        // 2) 收集几何信息（包含屏幕坐标），用于主线程更新 WKWebView 的 frame
        println(env, "[trace][paint0] bool dirty = false");
        bool dirty = false;
        println(env, "[trace][paint0] if (w/h changed or bounds changed)");
        if (w != ctx->lastW || h != ctx->lastH || (lock & JAWT_LOCK_BOUNDS_CHANGED)) {
            println(env, "[trace][paint0] ctx->lastW = w");
            ctx->lastW = w;
            println(env, "[trace][paint0] ctx->lastH = h");
            ctx->lastH = h;
            println(env, "[trace][paint0] pendingW.store(w)");
            ctx->pendingW.store(w, std::memory_order_relaxed);
            println(env, "[trace][paint0] pendingH.store(h)");
            ctx->pendingH.store(h, std::memory_order_relaxed);
            println(env, "[trace][paint0] dirty = true");
            dirty = true;
        }

        println(env, "[trace][paint0] jint sx=0, sy=0");
        jint sx = 0, sy = 0;
        println(env, "[trace][paint0] if (getComponentLocationOnScreen(...))");
        if (getComponentLocationOnScreen(env, thiz, &sx, &sy)) {
            println(env, "[trace][paint0] if (sx/sy changed)");
            if (sx != ctx->lastScreenX || sy != ctx->lastScreenY) {
                println(env, "[trace][paint0] ctx->lastScreenX = sx");
                ctx->lastScreenX = sx;
                println(env, "[trace][paint0] ctx->lastScreenY = sy");
                ctx->lastScreenY = sy;
                println(env, "[trace][paint0] pendingScreenX.store(sx)");
                ctx->pendingScreenX.store(sx, std::memory_order_relaxed);
                println(env, "[trace][paint0] pendingScreenY.store(sy)");
                ctx->pendingScreenY.store(sy, std::memory_order_relaxed);
                println(env, "[trace][paint0] dirty = true");
                dirty = true;
            }
        }

        println(env, "[trace][paint0] if (dirty) ctx->dirty.store(true)");
        if (dirty) {
            println(env, "[trace][paint0] ctx->dirty.store(true)");
            ctx->dirty.store(true, std::memory_order_relaxed);
        }

        // 3) 合并调度：异步到主线程更新 WKWebView 的 frame（不阻塞 paint0）
        println(env, "[trace][paint0] if (ctx->dirty.load())");
        if (ctx->dirty.load(std::memory_order_relaxed)) {
            println(env, "[trace][paint0] bool expected = false");
            bool expected = false;
            println(env, "[trace][paint0] if (applyScheduled CAS)");
            if (ctx->applyScheduled.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
                println(env, "[trace][paint0] runOnMainAsync(block)");
                runOnMainAsync(^{
                    JNIEnv *menv = nullptr;
                    bool detach = false;
                    if (jvm) {
                        jint ge = jvm->GetEnv((void **)&menv, JNI_VERSION_1_6);
                        if (ge == JNI_EDETACHED) {
                            if (jvm->AttachCurrentThread((void **)&menv, nullptr) == JNI_OK) {
                                detach = true;
                            }
                        }
                    }

                    println(menv, "[trace][paint0][main] if (!ctx->dirty.exchange(false))");
                    if (!ctx->dirty.exchange(false, std::memory_order_acq_rel)) {
                        println(menv, "[trace][paint0][main] applyScheduled.store(false)");
                        ctx->applyScheduled.store(false, std::memory_order_release);
                        println(menv, "[trace][paint0][main] return");
                        if (detach && jvm) {
                            jvm->DetachCurrentThread();
                        }
                        return;
                    }

                    println(menv, "[trace][paint0][main] load pending geometry");
                    const jint pw = ctx->pendingW.load(std::memory_order_relaxed);
                    const jint ph = ctx->pendingH.load(std::memory_order_relaxed);
                    const jint psx = ctx->pendingScreenX.load(std::memory_order_relaxed);
                    const jint psy = ctx->pendingScreenY.load(std::memory_order_relaxed);

                    // 更新 overlay layer 尺寸（主线程）
                    println(menv, "[trace][paint0][main] updateOverlayLayerGeometry(ctx, pw, ph)");
                    updateOverlayLayerGeometry(ctx, pw, ph);

                    // 若之前没有拿到 window，这里重试
                    println(menv, "[trace][paint0][main] if (!ctx->hostWindow)");
                    if (!ctx->hostWindow) {
                        println(menv, "[trace][paint0][main] NSWindow *win = [NSApp keyWindow]");
                        NSWindow *win = [NSApp keyWindow];
                        println(menv, "[trace][paint0][main] if (!win) win = [NSApp mainWindow]");
                        if (!win) win = [NSApp mainWindow];
                        println(menv, "[trace][paint0][main] if (win) ctx->hostWindow = win");
                        if (win) ctx->hostWindow = win;
                    }
                    println(menv, "[trace][paint0][main] if (ctx->hostWindow && !ctx->hostView)");
                    if (ctx->hostWindow && !ctx->hostView) {
                        println(menv, "[trace][paint0][main] ctx->hostView = ctx->hostWindow.contentView");
                        ctx->hostView = ctx->hostWindow.contentView;
                    }

                    println(menv, "[trace][paint0][main] if (ctx->webView && ctx->hostView)");
                    if (ctx->webView && ctx->hostView) {
                        // 确保在最上层
                        println(menv, "[trace][paint0][main] if (ctx->webView.superview != ctx->hostView)");
                        if (ctx->webView.superview != ctx->hostView) {
                            println(menv, "[trace][paint0][main] addSubview positioned above");
                            [ctx->hostView addSubview:ctx->webView positioned:NSWindowAbove relativeTo:nil];
                        }

                        println(menv, "[trace][paint0][main] NSRect target = NSMakeRect(0,0,pw,ph)");
                        NSRect target = NSMakeRect(0, 0, pw, ph);

                        // 将 Java 屏幕坐标（左上原点）转换为 Cocoa screen 坐标（左下原点）
                        // 注：多显示器情况下仍可能有偏差，但单屏/主屏为主时可用。
                        println(menv, "[trace][paint0][main] CGFloat primaryH = ...");
                        CGFloat primaryH = NSScreen.mainScreen.frame.size.height;
                        println(menv, "[trace][paint0][main] cocoaScreenRect = NSMakeRect(psx, primaryH-psy-ph, pw, ph)");
                        NSRect cocoaScreenRect = NSMakeRect((CGFloat)psx, primaryH - (CGFloat)psy - (CGFloat)ph, (CGFloat)pw, (CGFloat)ph);

                        println(menv, "[trace][paint0][main] if (ctx->hostWindow && psx != INT32_MIN)");
                        if (ctx->hostWindow && psx != INT32_MIN) {
                            println(menv, "[trace][paint0][main] windowRect = convertRectFromScreen");
                            NSRect windowRect = [ctx->hostWindow convertRectFromScreen:cocoaScreenRect];
                            println(menv, "[trace][paint0][main] target = convertRect:fromView:nil");
                            target = [ctx->hostView convertRect:windowRect fromView:nil];
                        }

                        println(menv, "[trace][paint0][main] ctx->webView.frame = target");
                        ctx->webView.frame = target;
                        println(menv, "[trace][paint0][main] [ctx->webView setNeedsLayout:YES]");
                        [ctx->webView setNeedsLayout:YES];
                        println(menv, "[trace][paint0][main] [ctx->webView layoutSubtreeIfNeeded]");
                        [ctx->webView layoutSubtreeIfNeeded];
                    }

                    println(menv, "[trace][paint0][main] applyScheduled.store(false)");
                    ctx->applyScheduled.store(false, std::memory_order_release);

                    if (detach && jvm) {
                        jvm->DetachCurrentThread();
                    }
                });
            }
        }

        println(env, "[trace][paint0] ds->FreeDrawingSurfaceInfo(dsi)");
        ds->FreeDrawingSurfaceInfo(dsi);
        println(env, "[trace][paint0] ds->Unlock(ds)");
        ds->Unlock(ds);
        println(env, "[trace][paint0] awt.FreeDrawingSurface(ds)");
        awt.FreeDrawingSurface(ds);
        println(env, "[trace][paint0] exit");
    }
}
