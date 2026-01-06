package top.kagg886

import java.awt.Canvas
import java.awt.Graphics

/**
 * ================================================
 * Author:     886kagg
 * Created on: 2026/1/6 13:37
 * ================================================
 */
class WebView : Canvas(), AutoCloseable {
    companion object {
        init {
            System.load("/Users/886kagg/IdeaProjects/webkit-panel-demo/native/build/lib/libwvbridge.dylib")
        }
    }

    private val handle by lazy {
        create()
    }

    override fun paint(g: Graphics?) = paint0(g, handle)
    override fun close() = dispose(handle)

    private external fun paint0(g: Graphics?, handle: Long)
    private external fun create(): Long
    private external fun dispose(handle: Long)

}
