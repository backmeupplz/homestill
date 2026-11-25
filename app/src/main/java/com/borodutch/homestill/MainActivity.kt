package com.borodutch.homestill

import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Ha.init(this)
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            // `badtoken`: a bogus access token (future expiry) to exercise auth_invalid → refresh → connected
            if (intent.hasExtra("badtoken")) { Ha.access = "x"; Ha.expiresAt = System.currentTimeMillis() + 1_800_000 }
            // `noservice`: never call a service, for looking at a real home
            if (intent.hasExtra("noservice")) Ha.readOnly = true
        }
        enableEdgeToEdge()
        setContent { HomestillTheme { Root() } }
    }

    override fun onStart() { super.onStart(); Ha.start() }
    override fun onStop() { super.onStop(); Ha.stop() }
}
