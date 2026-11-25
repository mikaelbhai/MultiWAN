# the website calls these through window.BaytaarApp
-keepclassmembers class com.baytaar.router.MainActivity$Bridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
