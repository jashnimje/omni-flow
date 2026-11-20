package com.jashnm.omniflow_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import org.json.JSONObject
import java.io.File

/**
 * The share sheet's "Add WiZ lights": the WiZ app's export link (text) or
 * its exported file (JSON). Exported, as the share sheet requires, but it
 * only hands what was shared to Add, From the WiZ app: it writes it to the
 * app's private files and opens that screen, where the person taps Add and
 * the engine checks it. Nothing is added from here.
 */
class WizShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent
        if (shared?.action != Intent.ACTION_SEND) return finish()
        val text = shared.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(MAX_TEXT)
        val stream = streamOf(shared)
        val app = applicationContext
        Thread {
            val body = text?.takeIf { it.isNotBlank() } ?: stream?.let { read(it) }
            runOnUiThread {
                if (body == null) {
                    Toast.makeText(app, "There is no WiZ link or file to add", Toast.LENGTH_LONG).show()
                } else {
                    File(app.filesDir, SHARED_FILE).writeText(
                        JSONObject().put("text", body).put("at", System.currentTimeMillis()).toString(),
                    )
                    startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(ROUTE), app, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                }
                finish()
            }
        }.start()
    }

    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    /** The shared file's text, or null when it cannot be read or is too large. */
    private fun read(uri: Uri): String? = try {
        contentResolver.openInputStream(uri)?.use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (out.size() <= MAX_BYTES) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
            }
            if (out.size() > MAX_BYTES) null else out.toString(Charsets.UTF_8.name())
        }
    } catch (e: Exception) {
        null
    }

    private companion object {
        // PhoneWizImportHands in lib/ui/add/wiz_import_page.dart reads it.
        const val SHARED_FILE = "wiz_share.json"
        const val ROUTE = "omniflow://open/add/wiz"
        const val MAX_TEXT = 10_000
        const val MAX_BYTES = 512 * 1024
    }
}
