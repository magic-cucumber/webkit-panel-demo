package top.kagg886

import javax.swing.JFrame
import javax.swing.SwingUtilities


/**
 * ================================================
 * Author:     886kagg
 * Created on: 2026/1/6 13:44
 * ================================================
 */

fun main() = SwingUtilities.invokeLater {
    val frame = JFrame("AWT 原生绘制 演示")

    frame.setSize(800, 600)
    frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE)
    frame.setLocationRelativeTo(null)
    frame.add(WebView())

    frame.isVisible = true
}
