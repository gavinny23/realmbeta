package com.example.reality_merge

import android.app.Application
import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date

/// Diagnostic-only Application class. Installs the crash handler in
/// [attachBaseContext] rather than [onCreate] because that's the
/// earliest hook Android gives us — it runs before any ContentProvider
/// in the process initializes, including the one Play
/// Services/AdMob's SDK auto-registers to self-initialize before
/// Application.onCreate() even fires. A crash that happens with zero
/// UI ever shown (no splash, nothing) almost always originates there,
/// which is exactly the window a handler installed in onCreate would
/// already be too late to catch.
///
/// On an uncaught exception anywhere in the process, this writes the
/// full stack trace to a plain file in internal storage and then
/// re-throws to the previous (system) handler so the crash still
/// behaves exactly as it did before — this never suppresses or
/// changes a crash, it only records it. MainActivity checks for that
/// file on its next successful launch and shows it in a dialog you
/// can copy from, since there's no adb access on this device.
class ReamApplication : Application() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        installCrashHandler()
    }

    private fun installCrashHandler() {
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                File(filesDir, "last_crash.txt").writeText(
                    "Crashed at: ${Date()}\nThread: ${thread.name}\n\n$sw"
                )
            } catch (_: Throwable) {
                // The crash handler itself must never throw — that
                // would just replace one uncaught crash with another.
            }
            // Hand off to whatever Android's own default handler would
            // have done (log to system, kill the process) — this is
            // purely an extra recording step, not a replacement.
            previousHandler?.uncaughtException(thread, throwable)
        }
    }
}
