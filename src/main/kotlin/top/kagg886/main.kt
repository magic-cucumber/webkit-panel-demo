package top.kagg886

import javax.swing.JFrame
import javax.swing.SwingUtilities

import java.awt.GridBagLayout
import java.awt.Dimension
import java.awt.GridBagConstraints



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

    // 1. 设置布局管理器为 GridBagLayout
    frame.layout = GridBagLayout()

    val webView = WebView()

    // 2. 配置 GridBagConstraints 来实现居中和比例
    val gbc = GridBagConstraints().apply {
        gridx = 0
        gridy = 0
        anchor = GridBagConstraints.CENTER // 居中
    }

    // 3. 监听父容器大小变化，动态调整 WebView 大小
    frame.addComponentListener(object : java.awt.event.ComponentAdapter() {
        override fun componentResized(e: java.awt.event.ComponentEvent?) {
            val parentWidth = frame.contentPane.width
            val parentHeight = frame.contentPane.height

            // 计算 80% 的宽高
            val targetWidth = (parentWidth * 0.8).toInt()
            val targetHeight = (parentHeight * 0.8).toInt()

            // 强制更新组件大小
            webView.preferredSize = Dimension(targetWidth, targetHeight)
            frame.revalidate() // 重新计算布局
        }
    })

    frame.add(webView, gbc)
    frame.isVisible = true
}
