package top.kagg886

import java.awt.Canvas
import java.awt.Graphics
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

    override fun addNotify() {
        super.addNotify()
        SwingUtilities.invokeLater {
            handle = initAndAttach()
            println("init handle on 'addNotify', handle is $handle")
        }
    }

    override fun paint(g: Graphics?) {
        println("start paint!")
        paint0(g,handle)
    }


    override fun close() {

    }

    private external fun paint0(g: Graphics?, webview: Long)
    private external fun initAndAttach(): Long
}
