package com.jashnm.omniflow_app

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * A message an automation shows on the whole screen, which stays until it
 * is tapped away. Started from a full-screen notification (or at once when
 * OmniFlow is on screen), so it also shows on a locked phone. Not exported:
 * only this app's own intents reach it.
 */
class MessageActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        show(intent)
    }

    /** A newer message replaces the one on screen. */
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        show(intent)
    }

    private fun show(intent: android.content.Intent) {
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val text = intent.getStringExtra(EXTRA_TEXT)
        val pad = dp(24)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
            setBackgroundColor(Color.parseColor("#0B0F14"))
        }
        column.addView(
            TextView(this).apply {
                this.text = title
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 32f)
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                isFocusable = true
            },
        )
        if (!text.isNullOrBlank()) {
            column.addView(
                TextView(this).apply {
                    this.text = text
                    setTextColor(Color.parseColor("#D0D7DE"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                    gravity = Gravity.CENTER
                    setPadding(0, dp(16), 0, 0)
                },
            )
        }
        column.addView(
            Button(this).apply {
                this.text = "OK"
                contentDescription = "OK, close the message"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                minimumHeight = dp(64)
                minimumWidth = dp(160)
                setOnClickListener { finish() }
            },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(32)
                gravity = Gravity.CENTER_HORIZONTAL
            },
        )
        setContentView(
            ScrollView(this).apply {
                isFillViewport = true
                setBackgroundColor(Color.parseColor("#0B0F14"))
                addView(column)
            },
        )
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
    }
}
