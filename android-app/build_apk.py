"""Build BaytaarRouter.apk with Gradle (Google's push library needs it).

    python build_apk.py

Steps: turn google-services.json (from the Firebase console, saved next to
this file) into the settings Firebase reads, build the release APK with the
Gradle and Android SDK already on E:, then align and sign it with
release.keystore (the password is read from release.keystore.password.txt
and never printed). Same package name and key as the earlier app, so it
installs over it.
"""
import glob, json, os, shutil, subprocess, sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = r'E:\android\sdk'
BT = os.path.join(SDK, 'build-tools', '35.0.0')
JDK = r'E:\android\jdk21'
GRADLE_HOME = r'E:\android\gradle-home'
PACKAGE = 'com.baytaar.router'

env = dict(os.environ, JAVA_HOME=JDK, GRADLE_USER_HOME=GRADLE_HOME, ANDROID_HOME=SDK,
           PATH=os.path.join(JDK, 'bin') + os.pathsep + os.environ.get('PATH', ''))


def run(*cmd, quiet=True):
    r = subprocess.run([str(c) for c in cmd], env=env, cwd=HERE, capture_output=quiet, text=True)
    if r.returncode != 0:
        if quiet: sys.stdout.write((r.stdout or '')[-6000:] + (r.stderr or '')[-6000:])
        sys.exit('failed: ' + os.path.basename(str(cmd[0])))
    return r.stdout or ''


# 1. Firebase settings (what Google's own Gradle plugin would generate)
res = os.path.join(HERE, 'build', 'firebase-res', 'values')
shutil.rmtree(os.path.dirname(res), ignore_errors=True)
os.makedirs(res)
gs = os.path.join(HERE, 'google-services.json')
if os.path.isfile(gs):
    g = json.load(open(gs, encoding='utf-8'))
    pi = g['project_info']
    cl = [c for c in g['client'] if c['client_info']['android_client_info']['package_name'] == PACKAGE]
    if not cl: sys.exit('google-services.json has no Android app for ' + PACKAGE)
    vals = {
        'google_app_id': cl[0]['client_info']['mobilesdk_app_id'],
        'gcm_defaultSenderId': pi['project_number'],
        'google_api_key': cl[0]['api_key'][0]['current_key'],
        'project_id': pi['project_id'],
    }
    if pi.get('storage_bucket'): vals['google_storage_bucket'] = pi['storage_bucket']
    with open(os.path.join(res, 'firebase.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n')
        for k, v in vals.items():
            f.write('    <string name="%s" translatable="false">%s</string>\n' % (k, escape(str(v))))
        f.write('</resources>\n')
    print('Firebase project:', pi['project_id'])
else:
    print('WARNING: no google-services.json here, so this build cannot get pushes '
          '(it falls back to watching the website itself).')
    with open(os.path.join(res, 'firebase.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources/>\n')

# 2. Gradle
gradle = glob.glob(os.path.join(GRADLE_HOME, 'wrapper', 'dists', 'gradle-8.14.3-bin', '*', 'gradle-8.14.3', 'bin', 'gradle.bat'))
if not gradle: sys.exit('Gradle 8.14.3 not found under ' + GRADLE_HOME)
run(gradle[0], '--no-daemon', '--console=plain', '-q', 'assembleRelease')
out = os.path.join(HERE, 'build', 'outputs', 'apk', 'release', 'BaytaarRouter-release-unsigned.apk')
if not os.path.isfile(out):
    found = glob.glob(os.path.join(HERE, 'build', 'outputs', 'apk', 'release', '*.apk'))
    if not found: sys.exit('Gradle made no APK')
    out = found[0]

# 3. align and sign
aligned = os.path.join(HERE, 'build', 'aligned.apk')
run(os.path.join(BT, 'zipalign.exe'), '-p', '-f', '4', out, aligned)
apk = os.path.join(HERE, 'BaytaarRouter.apk')
run(os.path.join(BT, 'apksigner.bat'), 'sign', '--ks', 'release.keystore',
    '--ks-pass', 'file:release.keystore.password.txt', '--out', apk, aligned)
print(run(os.path.join(BT, 'apksigner.bat'), 'verify', '--print-certs', apk).splitlines()[0])
print('built', apk, os.path.getsize(apk), 'bytes')
