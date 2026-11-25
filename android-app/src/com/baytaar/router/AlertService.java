package com.baytaar.router;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * Waits on the website for outage alerts (one request open at a time, the
 * website answers the moment something happens or after 45 s) and shows each
 * one as a notification. Runs as a foreground service with a quiet
 * notification, so Android keeps it going.
 */
public class AlertService extends Service {
    static volatile boolean running;
    private volatile boolean run;
    private Thread worker;
    private String watchText = "";

    @Override
    public IBinder onBind(Intent i) { return null; }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Alerts.channels(this);
        Alerts.watchChannel(this);
        Notification n = watchNote("Watching for outages");
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(1, n);
        if (!Alerts.enabled(this) || Alerts.token(this).isEmpty() || Alerts.push(this)) {
            stopSelf();
            return START_NOT_STICKY;
        }
        running = true;
        if (worker == null || !worker.isAlive()) {
            run = true;
            worker = new Thread(this::loop, "alerts");
            worker.start();
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        run = false;
        running = false;
        if (worker != null) worker.interrupt();
        super.onDestroy();
    }

    private void loop() {
        int backoff = 5;
        while (run) {
            String tok = Alerts.token(this);
            if (tok.isEmpty() || !Alerts.enabled(this) || Alerts.push(this)) break;
            long last = Alerts.prefs(this).getLong("last", -1);   // -1: new, ask for the newest id
            try {
                JSONObject b = new JSONObject();
                b.put("token", tok);
                b.put("after", last);
                b.put("wait", 45);
                Alerts.Reply r = Alerts.post("alerts.php/poll", b, null, 90000);
                if (r.code == 401) {
                    Alerts.prefs(this).edit().remove("token").apply();
                    show(999, "Outage alerts stopped", "Open Baytaar Router and sign in again to keep getting alerts.", System.currentTimeMillis());
                    break;
                }
                if (r.code != 200) throw new IOException("HTTP " + r.code);
                JSONObject j = r.json();
                JSONArray a = j.optJSONArray("alerts");
                if (a != null) {
                    for (int i = 0; i < a.length(); i++) {
                        JSONObject x = a.getJSONObject(i);
                        show(1000 + (int) (x.optLong("id") % 100000), x.optString("title"), x.optString("body"),
                                x.optLong("ts", System.currentTimeMillis() / 1000) * 1000);
                    }
                }
                Alerts.prefs(this).edit().putLong("last", j.optLong("last", last)).apply();
                watch(j.optJSONArray("routers"));
                backoff = 5;
            } catch (Exception e) {
                if (!run) break;
                setWatch("Reconnecting… (no internet on this phone?)");
                try { Thread.sleep(backoff * 1000L); } catch (InterruptedException ie) { break; }
                backoff = Math.min(backoff * 2, 60);
            }
        }
        running = false;
        stopSelf();
    }

    private void watch(JSONArray routers) {
        if (routers == null || routers.length() == 0) { setWatch("Watching for outages"); return; }
        StringBuilder s = new StringBuilder();
        SimpleDateFormat hm = new SimpleDateFormat("h:mm a", Locale.US);
        for (int i = 0; i < routers.length(); i++) {
            JSONObject r = routers.optJSONObject(i);
            if (r == null) continue;
            if (s.length() > 0) s.append(" · ");
            s.append(r.optString("name"));
            if (r.optBoolean("online")) s.append(": online");
            else s.append(": OFFLINE since ").append(hm.format(new Date(r.optLong("last_seen") * 1000)));
        }
        setWatch(s.toString());
    }

    private void setWatch(String text) {
        if (text.equals(watchText)) return;
        watchText = text;
        getSystemService(NotificationManager.class).notify(1, watchNote(text));
    }

    private PendingIntent openApp() {
        Intent i = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private Notification watchNote(String text) {
        return new Notification.Builder(this, Alerts.CH_WATCH)
                .setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Outage alerts are on")
                .setContentText(text)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(openApp())
                .build();
    }

    private void show(int id, String title, String body, long when) {
        Alerts.show(this, id, title, body, when);
    }
}
