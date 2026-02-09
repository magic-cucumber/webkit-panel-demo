package top.kagg886

import java.awt.Dimension
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import java.awt.event.ComponentAdapter
import java.awt.event.ComponentEvent
import javax.swing.*


/**
 * ================================================
 * Author:     886kagg
 * Created on: 2026/1/6 13:44
 * ================================================
 */

fun main() = SwingUtilities.invokeLater {
    val frame = JFrame("AWT 原生绘制 演示")
    frame.setSize(800, 600)
    frame.defaultCloseOperation = JFrame.EXIT_ON_CLOSE
    frame.layout = GridBagLayout()

    val webView = WebView()
    val gbc = GridBagConstraints().apply {
        gridx = 0
        gridy = 0
        anchor = GridBagConstraints.CENTER
    }

    // --- 新增菜单逻辑 ---
    val menuBar = JMenuBar()
    val menu = JMenu("操作")
    val toggleItem = JMenuItem("删除 WebView")

    var isPresent = false // 初始状态

    toggleItem.addActionListener {
        if (isPresent) {
            frame.remove(webView)
            toggleItem.text = "显示 WebView"
        } else {
            frame.add(webView, gbc)
            toggleItem.text = "删除 WebView"
        }

        isPresent = !isPresent

        // 关键：强制 AWT 重新计算布局并重绘界面
        frame.revalidate()
        frame.repaint()
    }

    menu.add(toggleItem)
    menuBar.add(menu)
    frame.jMenuBar = menuBar
    // ------------------

    // 初始添加
    frame.add(webView, gbc)
    isPresent = true

    frame.addComponentListener(object : ComponentAdapter() {
        override fun componentResized(e: ComponentEvent?) {
            val parentWidth = frame.contentPane.width
            val parentHeight = frame.contentPane.height
            val targetWidth = (parentWidth * 0.8).toInt()
            val targetHeight = (parentHeight * 0.8).toInt()

            webView.preferredSize = Dimension(targetWidth, targetHeight)
            frame.revalidate()
        }
    })

    frame.isVisible = true
}
