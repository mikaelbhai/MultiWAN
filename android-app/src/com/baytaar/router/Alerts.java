package com.baytaar.router;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.PowerManager;

import com.google.android.gms.tasks.Tasks;
import com.google.firebase.messaging.FirebaseMessaging;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.TimeUnit;

/** Shared pieces for outage alerts: settings, the website calls, channels. */
final class Alerts {
    static final String BASE = "https://mikaelbhai.com/router/";
    static final String CH_ALERT = "outages";
    static final String CH_WATCH = "watching";

    private Alerts() { }

    static SharedPreferences prefs(Context c) { return c.getSharedPreferences("alerts", Context.MODE_PRIVATE); }
    static boolean enabled(Context c) { return prefs(c).getBoolean("enabled", true); }
    static String token(Context c) { return prefs(c).getString("token", ""); }
    /** Alerts arrive by Google push (true) or by this phone waiting on the website (false). */
    static boolean push(Context c) { return prefs(c).getBoolean("push", false); }

    static void channels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        NotificationChannel a = new NotificationChannel(CH_ALERT, "Outage alerts", NotificationManager.IMPORTANCE_HIGH);
        a.setDescription("A line went down or came back, a power cut, the router went offline");
        a.enableVibration(true);
        a.enableLights(true);
        nm.createNotificationChannel(a);
        if (push(c)) nm.deleteNotificationChannel(CH_WATCH);
    }

    /** Only phones without Google push need the quiet "watching" notification. */
    static void watchChannel(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        NotificationChannel w = new NotificationChannel(CH_WATCH, "Watching for outages", NotificationManager.IMPORTANCE_MIN);
        w.setDescription("The quiet notification that keeps outage alerts running");
        w.setShowBadge(false);
        nm.createNotificationChannel(w);
    }

    static final class Reply {
        final int code; final String body;
        Reply(int code, String body) { this.code = code; this.body = body; }
        JSONObject json() { try { return new JSONObject(body); } catch (Exception e) { return new JSONObject(); } }
    }

    /** POST a JSON body to the website. */
    static Reply post(String path, JSONObject body, String cookie, int readTimeoutMs) throws IOException {
        HttpURLConnection h = (HttpURLConnection) new URL(BASE + path).openConnection();
        h.setConnectTimeout(15000);
        h.setReadTimeout(readTimeoutMs);
        h.setRequestMethod("POST");
        h.setDoOutput(true);
        h.setRequestProperty("Content-Type", "application/json");
        h.setRequestProperty("User-Agent", "BaytaarRouter-Android");
        if (cookie != null) h.setRequestProperty("Cookie", cookie);
        byte[] b = body.toString().getBytes("UTF-8");
        h.setFixedLengthStreamingMode(b.length);
        try (OutputStream o = h.getOutputStream()) { o.write(b); }
        int code = h.getResponseCode();
        InputStream in = code >= 400 ? h.getErrorStream() : h.getInputStream();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        if (in != null) {
            try (InputStream i = in) {
                byte[] buf = new byte[8192];
                for (int n; (n = i.read(buf)) > 0; ) out.write(buf, 0, n);
            }
        }
        return new Reply(code, out.toString("UTF-8"));
    }

    /** Swap the website sign-in (cookie) for this phone's own alert key. */
    static boolean register(Context c, String cookie) {
        try {
            JSONObject b = new JSONObject();
            b.put("label", Build.MANUFACTURER + " " + Build.MODEL);
            Reply r = post("alerts.php/register", b, cookie, 20000);
            if (r.code != 200) return false;
            JSONObject j = r.json();
            String tok = j.optString("token", "");
            if (tok.length() != 64) return false;
            prefs(c).edit().putString("token", tok).putString("email", j.optString("email", ""))
                    .putLong("last", j.optLong("last", -1)).apply();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Tell the website this phone's Google push address. */
    static boolean sendPushToken(Context c, String fcm) {
        try {
            JSONObject b = new JSONObject();
            b.put("token", token(c));
            b.put("fcm", fcm);
            Reply r = post("alerts.php/push", b, null, 20000);
            if (r.code != 200) {
                if (r.code == 503 || r.code == 400) prefs(c).edit().putBoolean("push", false).apply();
                return false;
            }
            prefs(c).edit().putBoolean("push", true).putString("fcm", fcm).remove("fcm_pending")
                    .putLong("push_sync", System.currentTimeMillis()).apply();
            stop(c);
            c.getSystemService(NotificationManager.class).deleteNotificationChannel(CH_WATCH);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Get this phone's Google push address and hand it to the website. Blocks: call off the main thread. */
    static boolean setupPush(Context c) {
        if (token(c).isEmpty()) return false;
        try {
            String fcm = Tasks.await(FirebaseMessaging.getInstance().getToken(), 30, TimeUnit.SECONDS);
            return fcm != null && !fcm.isEmpty() && sendPushToken(c, fcm);
        } catch (Exception e) {
            return false;   // no Google Play on this phone, or no internet right now
        }
    }

    /** Time to (re)send the push address: never sent, Google changed it, or once a day. */
    static boolean pushDue(Context c) {
        SharedPreferences p = prefs(c);
        long every = p.getBoolean("push", false) ? 24 * 3600 * 1000L : 6 * 3600 * 1000L;
        return p.contains("fcm_pending") || System.currentTimeMillis() - p.getLong("push_sync", 0) > every;
    }

    static void start(Context c) {
        if (!enabled(c) || token(c).isEmpty()) return;
        if (push(c)) { stop(c); return; }   // Google wakes the app for each alert
        try { c.startForegroundService(new Intent(c, AlertService.class)); } catch (Exception ignored) { }
    }

    static void stop(Context c) { c.stopService(new Intent(c, AlertService.class)); }

    static void show(Context c, int id, String title, String body, long when) {
        channels(c);
        Intent i = new Intent(c, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent open = PendingIntent.getActivity(c, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(c, CH_ALERT)
                .setSmallIcon(R.drawable.ic_stat)
                .setColor(0xFF0A84FF)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new Notification.BigTextStyle().bigText(body))
                .setWhen(when)
                .setShowWhen(true)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setContentIntent(open)
                .build();
        c.getSystemService(NotificationManager.class).notify(id, n);
    }

    static boolean batteryOk(Context c) {
        PowerManager pm = c.getSystemService(PowerManager.class);
        return pm != null && pm.isIgnoringBatteryOptimizations(c.getPackageName());
    }

    static boolean notificationsOk(Context c) {
        return c.getSystemService(NotificationManager.class).areNotificationsEnabled();
    }

    /** Every 15 minutes: keep push registered, or restart the fallback alert service. */
    static void scheduleWatchdog(Context c) {
        JobScheduler js = c.getSystemService(JobScheduler.class);
        if (js == null || js.getPendingJob(7) != null) return;
        js.schedule(new JobInfo.Builder(7, new ComponentName(c, WatchdogJob.class))
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .build());
    }
}
