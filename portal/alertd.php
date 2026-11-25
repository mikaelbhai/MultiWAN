<?php
// The outage watcher: every 10 seconds turns router events and silences into
// alerts and pushes them to phones. Runs in the background on the host
// (started by alertd_ensure()); only one copy runs at a time. It stops after
// a few hours so a fresh copy (with any new code) takes over.
if (PHP_SAPI !== 'cli') exit;
require __DIR__ . '/alerts_lib.php';

$lock = fopen(__DIR__ . '/alertd.lock', 'c');
if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) exit;   // already running
set_time_limit(0);
ignore_user_abort(true);

$until = time() + 6 * 3600;
$errors = 0;
// the code this copy started with: when either file changes, stop, and the next
// router upload starts a fresh copy that has the new code (no manual restart)
$codeTime = function (): int {
    clearstatcache();
    return max((int) @filemtime(__DIR__ . '/alertd.php'), (int) @filemtime(__DIR__ . '/alerts_lib.php'),
               (int) @filemtime(__DIR__ . '/lib.php'), (int) @filemtime(__DIR__ . '/activity_lib.php'));
};
$started = $codeTime();
while (time() < $until) {
    if ($codeTime() > $started) { alertd_log('code changed; restarting with the new version'); break; }
    touch(ALERTD_BEAT);
    try {
        watch_routers(all_routers());
        dispatch_pushes();
        $errors = 0;
    } catch (Throwable $t) {
        alertd_log('error: ' . $t->getMessage());
        if (++$errors > 30) break;
    }
    sleep(10);
}
@unlink(ALERTD_BEAT);   // the next upload starts a fresh copy at once
flock($lock, LOCK_UN);
