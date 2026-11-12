package ai.stridelabs.slauth

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.browser.customtabs.CustomTabsClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * The Android half of `androidAuthTabBrowser` (lib/src/auth_tab.dart): which
 * browser flutter_web_auth_2 would open for a sign-in, and whether it opens
 * there as an Auth Tab.
 *
 * Why the question matters: flutter_web_auth_2 5.1.x always calls
 * `AuthTabIntent.launch`, and on a browser without Auth Tab that quietly opens
 * a plain Custom Tab, where an https (App Link) callback never comes back to
 * the app. A sign-in may only use its https redirect when this says yes.
 *
 * The browser is chosen exactly as flutter_web_auth_2 5.1.0 chooses it
 * (`FlutterWebAuth2Plugin.findTargetBrowserPackageName` and
 * `AuthenticationManagementActivity.shouldUseAuthTabs`); the package's
 * pubspec holds the plugin below 5.2.0 so that an upgrade re-checks this copy.
 * Auth Tab support is the browser's declared category only
 * (`CustomTabsClient.isAuthTabSupported`), never a version guess: a false
 * "no" costs a consent screen, a false "yes" a sign-in that never returns.
 */
class StridelabsSlauthPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        if (call.method != "authTabBrowser") {
            result.notImplemented()
            return
        }
        val ctx = context
        if (ctx == null) {
            result.error("NO_CONTEXT", "The plugin is not attached to an engine", null)
            return
        }
        try {
            val order = call.argument<List<String>>("customTabsPackageOrder") ?: emptyList()
            val preferEphemeral = call.argument<Boolean>("preferEphemeral") ?: false
            val pkg = targetBrowser(ctx, order)
            val version = pkg?.let { installedVersion(ctx, it) }
            val authTab = pkg != null &&
                CustomTabsClient.isAuthTabSupported(ctx, pkg) &&
                launchesAuthTab(pkg, version, preferEphemeral)
            val sdkInt = Build.VERSION.SDK_INT
            Log.d(TAG, "Auth Tab check: browser=$pkg version=$version authTab=$authTab sdk=$sdkInt")
            result.success(
                mapOf(
                    "package" to pkg,
                    "version" to version,
                    "authTab" to authTab,
                    "sdkInt" to sdkInt,
                ),
            )
        } catch (e: Exception) {
            result.error("AUTH_TAB_CHECK_FAILED", e.toString(), null)
        }
    }

    companion object {
        private const val CHANNEL = "stridelabs_slauth/auth_tab"
        private const val TAG = "stridelabs_slauth"

        private const val CHROME_STABLE = "com.android.chrome"
        private const val CHROME_BETA = "com.chrome.beta"
        private const val CHROME_DEV = "com.chrome.dev"
        private const val MICROSOFT_EDGE = "com.microsoft.emmx"
        private const val FIREFOX = "org.mozilla.firefox"
        private const val SAMSUNG_INTERNET = "com.sec.android.app.sbrowser"

        /**
         * flutter_web_auth_2 5.1.0's `findTargetBrowserPackageName`: the first
         * of `customTabsPackageOrder` that offers Custom Tabs, else the default
         * browser if it does, else the first installed browser that does (its
         * preferred ones first), else null (no browser to ask: not an Auth Tab).
         */
        private fun targetBrowser(ctx: Context, order: List<String>): String? {
            order.map { it.trim() }
                .filter { it.isNotEmpty() }
                .firstOrNull { offersCustomTabs(ctx, it) }
                ?.let { return it }
            CustomTabsClient.getPackageName(ctx, emptyList<String>())?.let { return it }
            return installedBrowsers(ctx).firstOrNull { offersCustomTabs(ctx, it) }
        }

        private fun offersCustomTabs(ctx: Context, pkg: String): Boolean =
            CustomTabsClient.getPackageName(ctx, arrayListOf(pkg), true) == pkg

        /** flutter_web_auth_2 5.1.0's `getInstalledBrowsers`. */
        private fun installedBrowsers(ctx: Context): List<String> {
            val preferred = listOf(
                CHROME_STABLE, CHROME_BETA, SAMSUNG_INTERNET, MICROSOFT_EDGE, FIREFOX, CHROME_DEV,
            )
            val handlers = try {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://"))
                ctx.packageManager
                    .queryIntentActivities(intent, PackageManager.MATCH_ALL)
                    .map { it.activityInfo.packageName }
            } catch (_: Exception) {
                emptyList()
            }
            val (known, others) = handlers.partition { it in preferred }
            return known.sortedBy { preferred.indexOf(it) } + others
        }

        /**
         * flutter_web_auth_2 5.1.0's `shouldUseAuthTabs`: an ephemeral sign-in
         * on a known browser older than these versions opens a Custom Tab even
         * when the browser has Auth Tab.
         */
        private fun launchesAuthTab(pkg: String, version: String?, preferEphemeral: Boolean): Boolean {
            if (!preferEphemeral) return true
            val major = version?.substringBefore(".")?.toIntOrNull() ?: 0
            return when (pkg) {
                CHROME_STABLE, CHROME_BETA, CHROME_DEV -> major >= 141
                MICROSOFT_EDGE -> major >= 141
                SAMSUNG_INTERNET -> major >= 28
                FIREFOX -> major >= 143
                else -> true
            }
        }

        private fun installedVersion(ctx: Context, pkg: String): String? = try {
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                ctx.packageManager.getPackageInfo(pkg, 0)
            }
            info.versionName
        } catch (_: Exception) {
            null
        }
    }
}
