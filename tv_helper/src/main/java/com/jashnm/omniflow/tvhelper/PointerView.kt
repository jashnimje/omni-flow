package com.jashnm.omniflow.tvhelper

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.view.View

/** A classic arrow pointer, white with a dark edge, its tip at (0, 0). */
class PointerView(context: Context) : View(context) {

    private val scale = context.resources.displayMetrics.density * 1.6f

    private val arrow = Path().apply {
        val points = listOf(
            0f to 0f,
            0f to 17f,
            4f to 13f,
            7f to 20f,
            9.5f to 19f,
            6.5f to 12f,
            12f to 12f,
        )
        moveTo(points[0].first * scale, points[0].second * scale)
        for ((x, y) in points.drop(1)) lineTo(x * scale, y * scale)
        close()
    }

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = 0xFFFFFFFF.toInt()
    }

    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = scale
        strokeJoin = Paint.Join.ROUND
        color = 0xFF111111.toInt()
    }

    val widthPx = (14 * scale).toInt()
    val heightPx = (22 * scale).toInt()

    override fun onDraw(canvas: Canvas) {
        canvas.save()
        // Half the edge inside the window, so the tip's edge is not cut.
        canvas.translate(edge.strokeWidth / 2, edge.strokeWidth / 2)
        canvas.drawPath(arrow, fill)
        canvas.drawPath(arrow, edge)
        canvas.restore()
    }
}
