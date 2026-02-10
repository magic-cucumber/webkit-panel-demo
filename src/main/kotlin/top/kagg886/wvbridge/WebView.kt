package top.kagg886.wvbridge

import java.awt.Canvas
import java.awt.event.ComponentAdapter
import java.awt.event.ComponentEvent
import java.awt.event.HierarchyEvent
import java.util.function.Consumer
import javax.swing.SwingUtilities

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

    private var handle = 0L
    private val progressListener = mutableSetOf<Consumer<Float>>()

    init {
        addComponentListener(object : ComponentAdapter() {
            override fun componentResized(e: ComponentEvent) {
                if (handle == 0L) return
                println("addComponentListener - componentResized: width=$width, height=$height")
                update(handle, width, height, locationOnScreen.x, locationOnScreen.y)
            }

            override fun componentMoved(e: ComponentEvent) {
                if (handle == 0L) return
                println("addComponentListener - componentMoved: x=${locationOnScreen.x}, y=${locationOnScreen.y}")
                update(handle, width, height, locationOnScreen.x, locationOnScreen.y)
            }
        })

        addHierarchyListener { e ->
            if (e.changeFlags and HierarchyEvent.DISPLAYABILITY_CHANGED.toLong() != 0L && !isDisplayable) {
                close()
            }
        }
    }

    override fun addNotify() {
        super.addNotify()

        SwingUtilities.invokeLater {
            handle = initAndAttach()
            setProgressListener(handle) { progress ->
                progressListener.forEach {
                    it.accept(progress)
                }
            }
            SwingUtilities.invokeLater {
                update(handle, width, height, locationOnScreen.x, locationOnScreen.y)
                revalidate()
                repaint()
            }
        }
    }

    fun addProgressListener(consumer: Consumer<Float>): Unit {
        progressListener.add(consumer)
    }

    fun removeProgressListener(consumer: Consumer<Float>) {
        progressListener.remove(consumer)
    }

    fun loadUrl(url: String) = loadUrl(handle, url)

    override fun close() = close0(handle).apply {
        handle = 0
    }

    private external fun initAndAttach(): Long
    private external fun setProgressListener(webview: Long, consumer: Consumer<Float>)
    private external fun update(webview: Long, w: Int, h: Int, x: Int, y: Int)
    private external fun close0(webview: Long)


    private external fun loadUrl(webview: Long, url: String)
}
