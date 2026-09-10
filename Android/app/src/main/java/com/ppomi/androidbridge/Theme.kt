package com.ppomi.androidbridge

import android.content.Context
import android.content.res.Configuration
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** Every color comes from the generated ThemeColors (agent/theme.json recipe); nothing is mixed here. */
internal data class PpomiPalette(
    val bg: Color, val surface: Color, val surface2: Color, val line: Color, val line2: Color,
    val fg: Color, val fg2: Color, val accent: Color, val accentSoft: Color, val accentFg: Color,
    val onAccent: Color, val bad: Color
) {
    val go get() = accent   // agent holds the screen
    val turn get() = fg     // person's turn
    val wait get() = line2
}

internal val LightPalette = ThemeColors.Light.run {
    PpomiPalette(bg = Color(BG), surface = Color(SURFACE), surface2 = Color(SURFACE_2), line = Color(LINE), line2 = Color(LINE_2),
        fg = Color(FG), fg2 = Color(FG_2), accent = Color(ACCENT), accentSoft = Color(ACCENT_SOFT), accentFg = Color(ACCENT_FG),
        onAccent = Color(ON_ACCENT), bad = Color(BAD))
}

internal val DarkPalette = ThemeColors.Dark.run {
    PpomiPalette(bg = Color(BG), surface = Color(SURFACE), surface2 = Color(SURFACE_2), line = Color(LINE), line2 = Color(LINE_2),
        fg = Color(FG), fg2 = Color(FG_2), accent = Color(ACCENT), accentSoft = Color(ACCENT_SOFT), accentFg = Color(ACCENT_FG),
        onAccent = Color(ON_ACCENT), bad = Color(BAD))
}

internal fun ppomiPalette(context: Context) =
    if (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) DarkPalette else LightPalette

private val LocalPalette = staticCompositionLocalOf { LightPalette }
internal val palette: PpomiPalette @Composable get() = LocalPalette.current

internal val Pretendard = FontFamily(listOf(FontWeight.Normal, FontWeight.Medium).map { Font(R.font.pretendard_variable, it) })

/** Six-step scale: 11, 12, 14 (body), 16, 21, 24 sp; weights 400/500 only. The two large steps get title leading and -0.01em tracking. */
private fun type(size: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(fontFamily = Pretendard, fontWeight = weight, fontSize = size.sp,
    lineHeight = (size * if (size >= 21) 1.25 else 1.5).sp, letterSpacing = if (size >= 21) (-0.01).em else 0.em)

/** Tabular figures for amounts, counts and dates: `Text(..., style = Tabular)`. */
internal val Tabular: TextStyle @Composable get() = LocalTextStyle.current.copy(fontFeatureSettings = "tnum")

private val PpomiTypography = Typography(
    displayLarge = type(24, FontWeight.Medium), displayMedium = type(24, FontWeight.Medium), displaySmall = type(24, FontWeight.Medium),
    headlineLarge = type(24, FontWeight.Medium), headlineMedium = type(21, FontWeight.Medium), headlineSmall = type(21, FontWeight.Medium),
    titleLarge = type(21, FontWeight.Medium), titleMedium = type(16, FontWeight.Medium), titleSmall = type(14, FontWeight.Medium),
    bodyLarge = type(14), bodyMedium = type(14), bodySmall = type(12),
    labelLarge = type(14, FontWeight.Medium), labelMedium = type(12, FontWeight.Medium), labelSmall = type(11, FontWeight.Medium))

private fun scheme(p: PpomiPalette, dark: Boolean) = (if (dark) darkColorScheme() else lightColorScheme()).copy(
    // primary is mostly a foreground in M3 (text buttons, outlines, labels): accentFg keeps it readable on light.
    primary = p.accentFg, onPrimary = if (dark) p.bg else p.onAccent,
    primaryContainer = p.accentSoft, onPrimaryContainer = p.fg, inversePrimary = p.accent,
    secondary = p.accentFg, onSecondary = if (dark) p.bg else p.onAccent,
    secondaryContainer = p.accentSoft, onSecondaryContainer = p.accentFg,
    tertiary = p.accentFg, onTertiary = if (dark) p.bg else p.onAccent,
    tertiaryContainer = p.accentSoft, onTertiaryContainer = p.fg,
    background = p.bg, onBackground = p.fg, surface = p.surface, onSurface = p.fg,
    surfaceVariant = p.surface2, onSurfaceVariant = p.fg2, surfaceTint = p.accent,
    surfaceContainerLowest = p.surface, surfaceContainerLow = p.surface, surfaceContainer = p.surface2,
    surfaceContainerHigh = p.surface2, surfaceContainerHighest = p.surface2, surfaceDim = p.bg, surfaceBright = p.surface,
    inverseSurface = p.fg, inverseOnSurface = p.bg, outline = p.line2, outlineVariant = p.line,
    error = p.bad, onError = p.surface, errorContainer = p.accentSoft, onErrorContainer = p.bad)

@Composable
internal fun PpomiTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val p = if (dark) DarkPalette else LightPalette
    CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme(p, dark), typography = PpomiTypography, content = content)
    }
}

/** Filled buttons match web `.primary` and Mac `.tint(.accent)`: accent fill, on-accent text. */
internal val accentButton: ButtonColors @Composable get() =
    ButtonDefaults.buttonColors(containerColor = palette.accent, contentColor = palette.onAccent)
