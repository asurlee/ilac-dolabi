# Derleme sırasında Android ayarlarını otomatik yapar:
#  - Kamera + bildirim izinleri
#  - Zamanlanmış bildirim alıcıları (telefon yeniden başlasa da çalışsın)
#  - Desugaring (flutter_local_notifications bunu zorunlu tutuyor)
# Bu dosyayı elle düzenlemene gerek yok.

import pathlib

# ---------------------------------------------------------------- 1) Manifest
m = pathlib.Path('android/app/src/main/AndroidManifest.xml')
x = m.read_text()

izinler = (
    '    <uses-permission android:name="android.permission.CAMERA"/>\n'
    '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n'
    '    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>\n'
    '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n'
)
if 'android.permission.CAMERA' not in x:
    x = x.replace('<application', izinler + '    <application', 1)

alicilar = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
    </application>'''
if 'ScheduledNotificationReceiver' not in x:
    x = x.replace('</application>', alicilar, 1)

m.write_text(x)
print('--- AndroidManifest.xml ---')
print(x)

# ------------------------------------------------------- 2) app/build.gradle
kts = pathlib.Path('android/app/build.gradle.kts')
gry = pathlib.Path('android/app/build.gradle')

if kts.exists():
    t = kts.read_text()
    t = t.replace('flutter.minSdkVersion', '23')
    t = t.replace('JavaVersion.VERSION_11', 'JavaVersion.VERSION_17')
    t = t.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    if 'isCoreLibraryDesugaringEnabled' not in t:
        if 'compileOptions {' in t:
            t = t.replace(
                'compileOptions {',
                'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
        else:
            t = t.replace(
                'android {',
                'android {\n    compileOptions {\n'
                '        isCoreLibraryDesugaringEnabled = true\n'
                '        sourceCompatibility = JavaVersion.VERSION_17\n'
                '        targetCompatibility = JavaVersion.VERSION_17\n    }', 1)
    if 'multiDexEnabled' not in t:
        t = t.replace('defaultConfig {',
                      'defaultConfig {\n        multiDexEnabled = true', 1)
    if 'coreLibraryDesugaring(' not in t:
        t += ('\n\ndependencies {\n'
              '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n')
    kts.write_text(t)
    print('--- build.gradle.kts ---')
    print(t)

elif gry.exists():
    t = gry.read_text()
    t = t.replace('flutter.minSdkVersion', '23')
    t = t.replace('JavaVersion.VERSION_11', 'JavaVersion.VERSION_17')
    t = t.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    if 'coreLibraryDesugaringEnabled' not in t:
        t = t.replace('compileOptions {',
                      'compileOptions {\n        coreLibraryDesugaringEnabled true', 1)
    if 'multiDexEnabled' not in t:
        t = t.replace('defaultConfig {',
                      'defaultConfig {\n        multiDexEnabled true', 1)
    if 'coreLibraryDesugaring ' not in t:
        t += ("\n\ndependencies {\n"
              "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n")
    gry.write_text(t)
    print('--- build.gradle ---')
    print(t)
else:
    raise SystemExit('build.gradle bulunamadı!')
