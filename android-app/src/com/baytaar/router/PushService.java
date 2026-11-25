package com.baytaar.router;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.util.Map;

/**
 * Outage alerts pushed by the website through Google. Android wakes the app
 * for each one, so nothing has to run in the background in between.
 */
public class PushService extends FirebaseMessagingService {
    @Override
    public void onMessageReceived(RemoteMessage m) {
        if (!Alerts.enabled(this)) return;
        Map<String, String> d = m.getData();
        String title = d.get("title");
        if (title == null || title.isEmpty()) return;
        long id = parse(d.get("id"), System.currentTimeMillis());
        long ts = parse(d.get("ts"), System.currentTimeMillis() / 1000);
        Alerts.show(this, 1000 + (int) (id % 100000), title, d.containsKey("body") ? d.get("body") : "", ts * 1000);
    }

    /** Google gave this phone a new push address: tell the website. */
    @Override
    public void onNewToken(String fcm) {
        Alerts.prefs(this).edit().putString("fcm_pending", fcm).apply();
        if (!Alerts.token(this).isEmpty()) Alerts.sendPushToken(this, fcm);
    }

    private static long parse(String s, long dflt) {
        try { return Long.parseLong(s); } catch (Exception e) { return dflt; }
    }
}
