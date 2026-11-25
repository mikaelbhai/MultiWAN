package com.baytaar.router;

import android.app.job.JobParameters;
import android.app.job.JobService;

/**
 * Runs every 15 minutes: keeps this phone's push address known to the website,
 * and on phones without Google push brings the alert service back if Android
 * stopped it.
 */
public class WatchdogJob extends JobService {
    @Override
    public boolean onStartJob(final JobParameters p) {
        if (!Alerts.enabled(this) || Alerts.token(this).isEmpty()) return false;
        if (!Alerts.pushDue(this)) {
            if (!Alerts.push(this) && !AlertService.running) Alerts.start(this);
            return false;
        }
        new Thread(() -> {
            Alerts.setupPush(this);
            Alerts.start(this);
            jobFinished(p, false);
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters p) { return false; }
}
