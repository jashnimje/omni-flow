import 'package:omniflow_engine/src/devices/adb/app_labels.dart';
import 'package:test/test.dart';

void main() {
  group('appLabelFor', () {
    test('a label the device gave wins', () {
      expect(appLabelFor('com.example.x', label: ' My App '), 'My App');
    });

    test('known packages read their real names', () {
      expect(appLabelFor('com.google.android.gms'), 'Google Play services');
      expect(appLabelFor('com.netflix.ninja'), 'Netflix');
      expect(appLabelFor('com.android.inputmethod.latin'), 'Keyboard');
    });

    test('others take the last word that names the app', () {
      expect(appLabelFor('com.jashnm.omniflow'), 'Omniflow');
      expect(appLabelFor('org.videolan.vlc'), 'Vlc');
      expect(appLabelFor('com.plexapp.android'), 'Plexapp');
      expect(appLabelFor('com.example.tv.launcher'), 'Example');
      expect(appLabelFor('android'), 'Android');
    });

    test('system packages read by their APK label, else as a system '
        'package, never as a word cut from the id', () {
      expect(appLabelFor('com.android.se'), 'Secure Element');
      expect(appLabelFor('com.android.dynsystem'), 'Dynamic System Updates');
      expect(
        appLabelFor('com.google.android.providers.media.module'),
        'Media picker',
      );
      expect(appLabelFor('com.android.externalstorage'), 'External Storage');
      expect(
        appLabelFor('com.android.imsserviceentitlement'),
        'System (com.android.imsserviceentitlement)',
      );
      expect(
        appLabelFor('com.android.localtransport'),
        'System (com.android.localtransport)',
      );
      expect(
        appLabelFor('com.google.android.ondevicepersonalization.services'),
        'Ondevicepersonalization',
      );
      expect(
        appLabelFor('com.google.android.apps'),
        'System (com.google.android.apps)',
      );
      expect(appLabelFor('com.android.chrome'), 'Chrome');
    });
  });

  test('parseActivityLabels keeps text labels and skips resource ones', () {
    const output =
        '      packageName=com.example.plain\n'
        '      labelRes=0x0 nonLocalizedLabel=Plain Name icon=0x0 banner=0x0\n'
        '        packageName=com.example.plain\n'
        '        labelRes=0x0 nonLocalizedLabel=Other icon=0x0 banner=0x0\n'
        '      packageName=com.example.res\n'
        '      labelRes=0x7f0f0019 nonLocalizedLabel=null icon=0x0 banner=0x0\n';
    expect(parseActivityLabels(output), {'com.example.plain': 'Plain Name'});
  });
}
