package com.baytaar.router;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts outage alerts again after the phone restarts or the app updates. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        String a = i.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(a) && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) return;
        Alerts.scheduleWatchdog(c);
        Alerts.start(c);
    }
}
