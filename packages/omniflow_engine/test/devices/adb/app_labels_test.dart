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
