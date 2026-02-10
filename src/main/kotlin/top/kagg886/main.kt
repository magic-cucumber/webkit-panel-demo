package top.kagg886

import top.kagg886.wvbridge.WebView
import java.awt.Dimension
import java.awt.GridBagConstraints
import java.awt.GridBagLayout
import java.awt.Insets
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

    // --- 新增：地址栏输入框 ---
    val urlField = JTextField("https://www.google.com").apply {
        preferredSize = Dimension(600, 30)
    }

    // 监听回车键
    urlField.addActionListener {
        val url = urlField.text
        webView.loadUrl(url)
    }

    // --- 布局配置 ---
    val gbc = GridBagConstraints().apply {
        fill = GridBagConstraints.HORIZONTAL
        insets = Insets(10, 10, 10, 10) // 设置边距
    }

    // 添加输入框 (第 0 行)
    gbc.gridy = 0
    gbc.weightx = 1.0
    gbc.weighty = 0.0
    frame.add(urlField, gbc)

    // 添加 WebView (第 1 行)
    gbc.gridy = 1
    gbc.weighty = 1.0 // 占据剩余垂直空间
    gbc.fill = GridBagConstraints.BOTH
    frame.add(webView, gbc)

    // --- 菜单逻辑 (保持不变) ---
    val menuBar = JMenuBar()
    val menu = JMenu("操作")
    val toggleItem = JMenuItem("删除 WebView")
    var isPresent = true

    toggleItem.addActionListener {
        if (isPresent) {
            frame.remove(webView)
            toggleItem.text = "显示 WebView"
        } else {
            gbc.gridy = 1 // 确保重新添加时位置正确
            frame.add(webView, gbc)
            toggleItem.text = "删除 WebView"
        }
        isPresent = !isPresent
        frame.revalidate()
        frame.repaint()
    }

    menu.add(toggleItem)
    menuBar.add(menu)
    frame.jMenuBar = menuBar

    // 窗口缩放监听 (可选：如果你希望 WebView 比例固定)
    frame.addComponentListener(object : ComponentAdapter() {
        override fun componentResized(e: ComponentEvent?) {
            // GridBagLayout 会自动处理基础缩放，这里可以根据需要调整
            frame.revalidate()
        }
    })

    frame.isVisible = true
}
