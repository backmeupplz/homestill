package com.borodutch.homestill

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class ContrastTest {
    private fun ratio(a: Color, b: Color) = (maxOf(a.luminance(), b.luminance()) + 0.05f) / (minOf(a.luminance(), b.luminance()) + 0.05f)

    @Test fun bulbIconsStandOutFromTheirTile() {
        val dark = Color(0xFF2B2D33) to Color(0xFFE3E2E9)  // tile, text in dark mode
        val light = Color(0xFFE7E8EE) to Color(0xFF1A1B20) // same in light mode
        for ((bg, ink) in listOf(dark, light)) for (c in listOf(Color.Blue, Color.Yellow, Color(0xFFFFB300), Color(0xFFFFE4C8), Color.Red))
            assertTrue("$c on $bg", ratio(legible(c, bg, ink), bg) >= 3f)
        assertEquals(Color.Yellow, legible(Color.Yellow, dark.first, dark.second)) // already fine: untouched
    }
}
