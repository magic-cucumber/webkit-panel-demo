#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <Cocoa/Cocoa.h>
#import <jni.h>
#import <jawt_md.h>

#ifdef __cplusplus
extern "C" {
#endif


#include "jawt.h"
#import <QuartzCore/QuartzCore.h>


typedef struct {
    WKWebView *webView;
    NSView *containerView;
} WebViewData;


void println(JNIEnv *env, const char *message) {
    if (env == nullptr) return;

    // 1. 获取 System 类
    jclass sysClass = env->FindClass("java/lang/System");
    if (sysClass == nullptr) return;

    // 2. 获取 System.out 静态字段 ID
    jfieldID outID = env->GetStaticFieldID(sysClass, "out", "Ljava/io/PrintStream;");
    if (outID == nullptr) return;

    // 3. 获取 System.out 对象实例
    jobject outObj = env->GetStaticObjectField(sysClass, outID);
    if (outObj == nullptr) return;

    // 4. 获取 PrintStream 类
    jclass psClass = env->FindClass("java/io/PrintStream");
    if (psClass == nullptr) return;

    // 5. 获取 println(String) 方法 ID
    jmethodID printlnID = env->GetMethodID(psClass, "println", "(Ljava/lang/String;)V");
    if (printlnID == nullptr) return;

    // 6. 将 C 字符串转换为 Java 字符串
    jstring jmsg = env->NewStringUTF(message);

    // 7. 执行调用
    env->CallVoidMethod(outObj, printlnID, jmsg);

    // 8. 清理局部引用
    env->DeleteLocalRef(jmsg);
    env->DeleteLocalRef(sysClass);
    if (psClass != nullptr) env->DeleteLocalRef(psClass);
    if (outObj != nullptr) env->DeleteLocalRef(outObj);
}


extern "C" JNIEXPORT void JNICALL
Java_top_kagg886_WebView_paint0(JNIEnv *env, jobject canvas, jobject graphics, jlong handle) {
    // 获取自定义数据
    WebViewData *data = (WebViewData*) handle;
    assert(data != nullptr && "WebViewData is null");
    assert(data->webView != nil && "WKWebView not created");

    // 获取 JAWT 绘制表面
    JAWT awt;
    awt.version = JAWT_VERSION_1_7;
    jboolean res = JAWT_GetAWT(env, &awt);
    assert(res == JNI_TRUE && "Failed to get JAWT");

    JAWT_DrawingSurface *ds = awt.GetDrawingSurface(env, canvas);
    assert(ds != NULL && "Failed to get DrawingSurface");
    jint lock = ds->Lock(ds);
    assert((lock & JAWT_LOCK_ERROR) == 0 && "Failed to lock DrawingSurface");
    JAWT_DrawingSurfaceInfo *dsi = ds->GetDrawingSurfaceInfo(ds);
    assert(dsi != nullptr && "Failed to get DrawingSurfaceInfo");

    // 获取符合 JAWT_SurfaceLayers 协议的对象
    id<JAWT_SurfaceLayers> surfaceLayers =
            (__bridge id<JAWT_SurfaceLayers>) dsi->platformInfo;
    assert(surfaceLayers != nil && "Failed to get JAWT_SurfaceLayers");

    // 记录组件大小
    int width = dsi->bounds.width;
    int height = dsi->bounds.height;

    // 释放绘制表面锁和信息
    ds->FreeDrawingSurfaceInfo(dsi);
    ds->Unlock(ds);
    awt.FreeDrawingSurface(ds);

    dispatch_async(dispatch_get_main_queue(), ^{
        // 更新尺寸
        data->containerView.frame = CGRectMake(0, 0, width, height);
        data->webView.frame = CGRectMake(0, 0, width, height);

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        surfaceLayers.layer = data->containerView.layer;

        [CATransaction commit];
        [CATransaction flush];
    });

}

extern "C" JNIEXPORT jlong JNICALL
Java_top_kagg886_WebView_create(JNIEnv *env, jobject canvas) {

    WebViewData *data = (WebViewData *)malloc(sizeof(WebViewData));
    assert(data != NULL && "Failed to allocate WebViewData");

    data->containerView = nil;
    data->webView = nil;

    // Cocoa 对象必须在主线程创建
    dispatch_sync(dispatch_get_main_queue(), ^{
        // 1. 创建容器 NSView（layer-backed）
        NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
        assert(container != nil && "Failed to create container NSView");

        [container setWantsLayer:YES];
        assert(container.layer != nil && "Container view has no layer");

        // 2. 创建 WKWebView
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        assert(config != nil && "Failed to create WKWebViewConfiguration");

        config.preferences.javaScriptEnabled = YES;

        WKWebView *web = [[WKWebView alloc] initWithFrame:NSZeroRect
                                            configuration:config];
        assert(web != nil && "Failed to create WKWebView");

        [config release];

        [web setWantsLayer:YES];
        assert(web.layer != nil && "WKWebView has no layer");

        // 3. 加载页面
        NSURL *url = [NSURL URLWithString:@"https://www.baidu.com"];
        assert(url != nil && "Invalid URL");

        NSURLRequest *req = [NSURLRequest requestWithURL:url];
        [web loadRequest:req];

        // 4. 视图层级：container -> webView
        [container addSubview:web];

        // 5. 保存到结构体（注意 retain 语义）
        data->containerView = container;
        data->webView = web;
    });

    return (jlong)data;
}


extern "C" JNIEXPORT jlong JNICALL
Java_top_kagg886_WebView_dispose(JNIEnv *env, jobject canvas, jlong handle) {

    WebViewData *data = (WebViewData *)handle;
    assert(data != NULL && "WebViewData is null");

    dispatch_async(dispatch_get_main_queue(), ^{
        [data->webView removeFromSuperview];
        [data->webView release];
        [data->containerView release];
    });

    free(data);
    return 0;
}


#ifdef __cplusplus
}
#endif
