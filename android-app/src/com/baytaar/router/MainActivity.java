package com.baytaar.router;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

/**
 * The Baytaar website (mikaelbhai.com/router) in a full-screen window, plus
 * what a website cannot do: outage alerts that arrive while the app is
 * closed. The page talks to the app through window.BaytaarApp.
 */
public class MainActivity extends Activity {
    private static final String HOST = "mikaelbhai.com";
    private static final String HOME = Alerts.BASE;
    private static final int FILE_REQ = 5;
    private static final int NOTIF_REQ = 6;

    private WebView web;
    private ValueCallback<Uri[]> fileCb;
    private final Handler ui = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Alerts.channels(this);
        Alerts.scheduleWatchdog(this);
        getWindow().setStatusBarColor(Color.parseColor("#0b1220"));

        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#eef2f8"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setUserAgentString(s.getUserAgentString() + " BaytaarRouterApp/3");
        CookieManager.getInstance().setAcceptCookie(true);
        web.addJavascriptInterface(new Bridge(), "BaytaarApp");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if (ours(u)) return false;
                // anything else opens in the phone's browser
                try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) { }
                return true;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                CookieManager.getInstance().flush();
                syncAlerts();
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (!r.isForMainFrame()) return;
                String page = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>"
                        + "<body style='background:#eef2f8;color:#16233b;font-family:sans-serif;display:flex;"
                        + "align-items:center;justify-content:center;height:100vh;margin:0'>"
                        + "<div style='text-align:center;padding:24px'><h2>Can't reach the Baytaar website</h2>"
                        + "<p style='color:#52627c'>Check this phone's internet connection.</p>"
                        + "<p><a style='color:#2563eb;font-size:18px' href='" + HOME + "'>Try again</a></p>"
                        + "</div></body></html>";
                v.loadDataWithBaseURL(HOME, page, "text/html", "utf-8", HOME);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb, FileChooserParams p) {
                if (fileCb != null) fileCb.onReceiveValue(null);
                fileCb = cb;
                try {
                    startActivityForResult(p.createIntent(), FILE_REQ);
                } catch (Exception e) {
                    fileCb = null;
                    return false;
                }
                return true;
            }
        });

        web.setDownloadListener((url, agent, disposition, mime, length) -> download(url, disposition, mime));

        setContentView(web);
        if (state != null) web.restoreState(state); else web.loadUrl(HOME);

        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                && !Alerts.prefs(this).getBoolean("asked_notif", false)) {
            Alerts.prefs(this).edit().putBoolean("asked_notif", true).apply();
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIF_REQ);
        }
    }

    private static boolean ours(Uri u) {
        String h = u.getHost();
        return "https".equals(u.getScheme()) && h != null && (h.equals(HOST) || h.equals("www." + HOST));
    }

    @Override
    protected void onResume() {
        super.onResume();
        Alerts.start(this);
        refreshCard();
    }

    @Override
    protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        web.saveState(out);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else super.onBackPressed();
    }

    @Override
    protected void onActivityResult(int req, int result, Intent data) {
        if (req == FILE_REQ && fileCb != null) {
            fileCb.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result, data));
            fileCb = null;
            return;
        }
        super.onActivityResult(req, result, data);
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
        refreshCard();
    }

    /** Signed in on the website but no alert key yet: get one, then start alerts. */
    private void syncAlerts() {
        final String cookie = CookieManager.getInstance().getCookie(HOME);
        final boolean signedIn = cookie != null && cookie.contains("bt_session=");
        new Thread(() -> {
            if (signedIn && Alerts.enabled(this) && Alerts.token(this).isEmpty()) Alerts.register(this, cookie);
            if (Alerts.enabled(this) && !Alerts.token(this).isEmpty() && Alerts.pushDue(this)) {
                // Google push when this phone has it; otherwise the app keeps watching itself
                if (!Alerts.setupPush(this) && !Alerts.push(this)) ui.post(this::askBatteryOnce);
            }
            Alerts.start(this);
            ui.postDelayed(this::refreshCard, 1200);
        }).start();
    }

    private void refreshCard() {
        if (web != null) web.evaluateJavascript("window.btAppState && window.btAppState()", null);
    }

    /** Android stops background apps to save battery; alerts need an exception. */
    private void askBatteryOnce() {
        if (Alerts.batteryOk(this) || Alerts.prefs(this).getBoolean("asked_battery", false) || isFinishing()) return;
        Alerts.prefs(this).edit().putBoolean("asked_battery", true).apply();
        new AlertDialog.Builder(this)
                .setTitle("Keep outage alerts running")
                .setMessage("So you hear about outages straight away, even when the app is closed, "
                        + "let Baytaar Router run in the background. On the next screen choose Allow.")
                .setPositiveButton("Continue", (d, w) -> openBatterySettings())
                .setNegativeButton("Not now", null)
                .show();
    }

    private void openBatterySettings() {
        try {
            startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + getPackageName())));
        } catch (Exception e) {
            try { startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)); } catch (Exception ignored) { }
        }
    }

    private void download(String url, String disposition, String mime) {
        if (!URLUtil.isHttpsUrl(url)) {
            Toast.makeText(this, "This file can't be saved from the app.", Toast.LENGTH_LONG).show();
            return;
        }
        try {
            String name = URLUtil.guessFileName(url, disposition, mime);
            DownloadManager.Request r = new DownloadManager.Request(Uri.parse(url));
            String cookie = CookieManager.getInstance().getCookie(url);
            if (cookie != null) r.addRequestHeader("Cookie", cookie);
            r.setMimeType(mime);
            r.setTitle(name);
            r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
            getSystemService(DownloadManager.class).enqueue(r);
            Toast.makeText(this, "Saving " + name + " to Downloads", Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            Toast.makeText(this, "Could not save the file.", Toast.LENGTH_LONG).show();
        }
    }

    private void toast(String msg) {
        ui.post(() -> Toast.makeText(this, msg, Toast.LENGTH_LONG).show());
    }

    /** What the website page can ask the app (window.BaytaarApp). */
    private class Bridge {
        @JavascriptInterface
        public String state() {
            JSONObject j = new JSONObject();
            try {
                j.put("alerts", Alerts.enabled(MainActivity.this));
                j.put("ready", !Alerts.token(MainActivity.this).isEmpty());
                boolean push = Alerts.push(MainActivity.this);
                j.put("push", push);
                j.put("running", push || AlertService.running);
                j.put("battery", push || Alerts.batteryOk(MainActivity.this));
                j.put("notif", Alerts.notificationsOk(MainActivity.this));
                j.put("version", 3);
            } catch (Exception ignored) { }
            return j.toString();
        }

        @JavascriptInterface
        public void setAlerts(boolean on) {
            Alerts.prefs(MainActivity.this).edit().putBoolean("enabled", on).apply();
            if (on) ui.post(MainActivity.this::syncAlerts);
            else Alerts.stop(MainActivity.this);
        }

        @JavascriptInterface
        public void test() {
            final String tok = Alerts.token(MainActivity.this);
            if (tok.isEmpty()) { toast("Alerts are not set up yet. Sign in first."); return; }
            new Thread(() -> {
                try {
                    JSONObject b = new JSONObject();
                    b.put("token", tok);
                    Alerts.Reply r = Alerts.post("alerts.php/test", b, null, 20000);
                    toast(r.code == 200 ? "Test alert sent. It should arrive in a few seconds." : "Could not send a test alert.");
                } catch (Exception e) {
                    toast("Could not reach the website.");
                }
            }).start();
        }

        @JavascriptInterface
        public void fixBattery() { ui.post(MainActivity.this::openBatterySettings); }

        @JavascriptInterface
        public void fixNotifications() {
            ui.post(() -> {
                if (Build.VERSION.SDK_INT >= 33
                        && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
                    requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIF_REQ);
                    return;
                }
                try {
                    startActivity(new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, getPackageName()));
                } catch (Exception ignored) { }
            });
        }

        @JavascriptInterface
        public void signedIn() { ui.post(MainActivity.this::syncAlerts); }

        /** Signing out of the app stops its alerts. */
        @JavascriptInterface
        public void signedOut() {
            final String tok = Alerts.token(MainActivity.this);
            Alerts.prefs(MainActivity.this).edit().remove("token").remove("last").remove("push")
                    .remove("push_sync").apply();
            Alerts.stop(MainActivity.this);
            if (tok.isEmpty()) return;
            new Thread(() -> {
                try {
                    JSONObject b = new JSONObject();
                    b.put("token", tok);
                    Alerts.post("alerts.php/unregister", b, null, 15000);
                } catch (Exception ignored) { }
            }).start();
        }
    }
}
