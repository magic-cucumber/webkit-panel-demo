#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

#import <jni.h>
#import <jawt.h>
#import <jawt_md.h>

#include <cstdint>

#import "utils.h"

struct WebViewContext {
    // ObjC 指针：只在主线程读写
    WKWebView *webView = nil;
    NSWindow *hostWindow = nil;
    NSView *hostView = nil;
    CALayer *rootLayer = nil;

    // 几何状态：只在主线程读写（由 resize/move 统一调度到主线程更新）
    jint w = 0;
    jint h = 0;
    jint screenX = INT32_MIN; // Java 屏幕坐标：左上原点
    jint screenY = INT32_MIN;
};

static void updateOverlayLayerGeometry(CALayer *layer, jint w, jint h) {
    if (!layer) return;

    CGRect bounds = CGRectMake(0, 0, (CGFloat)w, (CGFloat)h);
    layer.bounds = bounds;
    layer.position = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
}

static void ensureHostAttachedOnMain(WebViewContext *ctx) {
    if (!ctx || !ctx->webView) return;

    // 已经挂载在目标 view 上
    if (ctx->hostView && ctx->webView.superview == ctx->hostView) return;

    NSWindow *win = [NSApp keyWindow];
    if (!win || !win.contentView) return;

    ctx->hostWindow = win;
    ctx->hostView = win.contentView;

    if (ctx->webView.superview != ctx->hostView) {
        [ctx->webView removeFromSuperview];
        [ctx->hostView addSubview:ctx->webView positioned:NSWindowAbove relativeTo:nil];
    }
}

static NSRect javaScreenRectToCocoa(jint sx, jint sy, jint w, jint h) {
    // Java 屏幕坐标：左上原点；Cocoa：左下原点（以主屏为参照）
    CGFloat primaryH = NSScreen.mainScreen.frame.size.height;
    return NSMakeRect((CGFloat)sx,
                      primaryH - (CGFloat)sy - (CGFloat)h,
                      (CGFloat)w,
                      (CGFloat)h);
}

static void applyGeometryOnMain(WebViewContext *ctx) {
    if (!ctx) return;

    // 1) AWT surface overlay layer bounds
    updateOverlayLayerGeometry(ctx->rootLayer, ctx->w, ctx->h);

    // 2) WKWebView frame
    if (!ctx->webView) return;

    ensureHostAttachedOnMain(ctx);
    if (!ctx->hostWindow || !ctx->hostView) return;

    // screenX/screenY 未初始化时，仅更新 layer，不动 webView
    if (ctx->screenX == INT32_MIN || ctx->screenY == INT32_MIN) return;

    NSRect cocoaScreenRect = javaScreenRectToCocoa(ctx->screenX, ctx->screenY, ctx->w, ctx->h);
    NSRect windowRect = [ctx->hostWindow convertRectFromScreen:cocoaScreenRect];
    NSRect target = [ctx->hostView convertRect:windowRect fromView:nil];

    ctx->webView.frame = target;
    [ctx->webView setNeedsLayout:YES];
    [ctx->webView layoutSubtreeIfNeeded];
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
        ctx->w = w;
        ctx->h = h;

        runOnMainSync(^{
            ctx->rootLayer = [CALayer layer];
//            ctx->rootLayer.masksToBounds = YES;
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

            // 4) 挂到 keyWindow.contentView（保证可见）
            ensureHostAttachedOnMain(ctx);
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
Java_top_kagg886_WebView_resize(JNIEnv *env, jobject thiz, jlong handle, jint w, jint h) {
    (void)env;
    (void)thiz;

    @autoreleasepool {
        if (handle == 0) return;
        auto *ctx = (WebViewContext *)(uintptr_t)handle;
        if (!ctx) return;

        runOnMainAsync(^{
            ctx->w = w;
            ctx->h = h;
            applyGeometryOnMain(ctx);
        });
    }
}

extern "C" JNIEXPORT void JNICALL
Java_top_kagg886_WebView_move(JNIEnv *env, jobject thiz, jlong handle, jint screenX, jint screenY) {
    (void)env;
    (void)thiz;

    @autoreleasepool {
        if (handle == 0) return;
        auto *ctx = (WebViewContext *)(uintptr_t)handle;
        if (!ctx) return;

        runOnMainAsync(^{
            ctx->screenX = screenX;
            ctx->screenY = screenY;
            applyGeometryOnMain(ctx);
        });
    }
}

// resize + move 的合并版：一次调用同时更新 size 与屏幕坐标（Java 左上原点）
extern "C" JNIEXPORT void JNICALL
Java_top_kagg886_WebView_update(JNIEnv *env, jobject thiz, jlong handle, jint w, jint h, jint x, jint y) {
    (void)env;
    (void)thiz;

    @autoreleasepool {
        if (handle == 0) return;
        auto *ctx = (WebViewContext *)(uintptr_t)handle;
        if (!ctx) return;

        runOnMainAsync(^{
            ctx->w = w;
            ctx->h = h;
            ctx->screenX = x;
            ctx->screenY = y;
            applyGeometryOnMain(ctx);
        });
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

        id<JAWT_SurfaceLayers> surfaceLayers = (__bridge id<JAWT_SurfaceLayers>)dsi->platformInfo;
        if (surfaceLayers && surfaceLayers.layer != ctx->rootLayer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            surfaceLayers.layer = ctx->rootLayer;
            [CATransaction commit];
        }

        ds->FreeDrawingSurfaceInfo(dsi);
        ds->Unlock(ds);
        awt.FreeDrawingSurface(ds);
    }
}
