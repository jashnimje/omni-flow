import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniflow_app/ui/tv/tv_files.dart';

import 'fake_engine.dart';
import 'tv_fixtures.dart';

void main() {
  late FakeEngine engine;

  setUp(() => engine = tvEngine());

  Future<void> openFiles(WidgetTester tester, {FakePhoneFiles? files}) async {
    await pumpTv(tester, engine, files: files);
    await openTvTab(tester, 'Files');
  }

  List<String> shownNames(WidgetTester tester) => [
    for (final tile in tester.widgetList<ListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('files-list')),
        matching: find.byType(ListTile),
      ),
    ))
      ((tile.title! as Text).data!),
  ];

  test('paths join, split and refuse unusable names', () {
    expect(joinPath('/sdcard', 'a.txt'), '/sdcard/a.txt');
    expect(joinPath('/', 'sdcard'), '/sdcard');
    expect(parentOf('/sdcard/Download'), '/sdcard');
    expect(parentOf('/sdcard'), '/');
    expect(fileNameError('ok name.txt'), isNull);
    expect(fileNameError('a/b'), isNotNull);
    expect(fileNameError('a\nb'), isNotNull);
    expect(fileNameError('..'), isNotNull);
    expect(fileNameError('  '), isNotNull);
  });

  testWidgets('opens at /sdcard with folders first, sizes and dates', (
    tester,
  ) async {
    await openFiles(tester);
    expect(argsOf(engine, 'tv.files.list').first, {
      'id': tvId,
      'path': '/sdcard',
    });
    expect(shownNames(tester), ['Download', 'Movies', 'notes.txt']);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.textContaining('2025-11-'), findsOneWidget);
  });

  testWidgets('a folder opens, and the breadcrumb and Up go back', (
    tester,
  ) async {
    await openFiles(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.list').last['path'], '/sdcard/Download');
    expect(shownNames(tester), ['show.mkv']);
    await tester.tap(find.byKey(const ValueKey('crumb-/sdcard')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.list').last['path'], '/sdcard');
    await tester.tap(find.byKey(const ValueKey('files-up')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.list').last['path'], '/');
  });

  testWidgets('long press selects, copy then paste copies into the folder', (
    tester,
  ) async {
    await openFiles(tester);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('select-count'))).data,
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('select-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-paste')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.copy'), [
      {'id': tvId, 'from': '/sdcard/Movies', 'to': '/sdcard/Download/Movies'},
      {
        'id': tvId,
        'from': '/sdcard/notes.txt',
        'to': '/sdcard/Download/notes.txt',
      },
    ]);
    expect(find.byKey(const ValueKey('files-paste')), findsOneWidget);
  });

  testWidgets('a copy pasted beside its original gets a free name', (
    tester,
  ) async {
    await openFiles(tester);
    await tester.tap(find.byKey(const ValueKey('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-paste')));
    await tester.pumpAndSettle();
    expect(
      argsOf(engine, 'tv.files.copy').single['to'],
      '/sdcard/notes copy.txt',
    );
  });

  testWidgets('cut then paste moves, and the clipboard empties', (
    tester,
  ) async {
    await openFiles(tester);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-cut')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-paste')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.move').single, {
      'id': tvId,
      'from': '/sdcard/notes.txt',
      'to': '/sdcard/Movies',
    });
    expect(find.byKey(const ValueKey('files-paste')), findsNothing);
  });

  testWidgets('rename takes a valid new name', (tester) async {
    await openFiles(tester);
    await tester.tap(find.byKey(const ValueKey('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ask-text')), 'a/b');
    await tester.pump();
    expect(find.text('No slashes or line breaks'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ask-text')), 'todo.txt');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.rename').single, {
      'id': tvId,
      'path': '/sdcard/notes.txt',
      'name': 'todo.txt',
    });
  });

  testWidgets('new folder makes it in the open folder', (tester) async {
    await openFiles(tester);
    await tester.tap(find.byKey(const ValueKey('files-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ask-text')), 'omni');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-text-ok')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.mkdir').single, {
      'id': tvId,
      'path': '/sdcard/omni',
    });
  });

  testWidgets('delete asks first, Cancel keeps the files', (tester) async {
    await openFiles(tester);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete notes.txt?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.callsOf('tv.files.delete'), isEmpty);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 items?'), findsOneWidget);
    expect(find.textContaining('with everything in them'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.delete').single, {
      'id': tvId,
      'paths': ['/sdcard/Movies', '/sdcard/notes.txt'],
      'recursive': true,
    });
  });

  testWidgets('download saves files to the phone and skips folders', (
    tester,
  ) async {
    await openFiles(tester);
    await tester.longPress(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-download')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.download').single, {
      'id': tvId,
      'path': '/sdcard/notes.txt',
      'to': '/phone/Download/notes.txt',
    });
    expect(
      find.text(
        'Saved 1 item to /phone/Download. Folders are skipped. Open one to '
        'download its files',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a download onto an existing file asks before replacing it', (
    tester,
  ) async {
    Map<String, Object?> conflictUnlessOverwrite(Map<String, Object?> args) =>
        args['overwrite'] == true
        ? {'ok': true, 'files': 1, 'bytes': 2048}
        : {
            'ok': false,
            'error': {'type': 'conflict', 'message': 'exists'},
          };
    engine.answerers['tv.files.download'] = conflictUnlessOverwrite;
    await openFiles(tester);
    Future<void> download() async {
      await tester.tap(find.byKey(const ValueKey('entry-menu-notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('file-download')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await download();
    expect(find.text('Replace /phone/Download/notes.txt?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(engine.callsOf('tv.files.download'), hasLength(1));

    await download();
    await tester.tap(find.byKey(const ValueKey('confirm')));
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.download').last, {
      'id': tvId,
      'path': '/sdcard/notes.txt',
      'to': '/phone/Download/notes.txt',
      'overwrite': true,
    });
    expect(find.textContaining('Saved 1 item'), findsOneWidget);
  });

  testWidgets('without a Downloads folder nothing is downloaded', (
    tester,
  ) async {
    await openFiles(tester, files: FakePhoneFiles(downloads: null));
    await tester.tap(find.byKey(const ValueKey('entry-menu-notes.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-download')));
    await tester.pumpAndSettle();
    expect(engine.callsOf('tv.files.download'), isEmpty);
    expect(find.textContaining('no Downloads folder'), findsOneWidget);
  });

  testWidgets('upload sends picked files into the open folder with progress', (
    tester,
  ) async {
    final phone = FakePhoneFiles(
      files: [
        (name: 'a.jpg', path: '/cache/file_picker/1/a.jpg'),
        (name: 'b.mp4', path: '/cache/file_picker/1/b.mp4'),
      ],
    );
    engine.delay = const Duration(milliseconds: 50);
    await openFiles(tester, files: phone);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-upload')));
    await tester.pump();
    await tester.pump();
    engine.eventsOut.add({
      'event': 'tv.progress',
      'id': tvId,
      'op': 'upload',
      'done': 64 * 1024,
      'total': 128 * 1024,
    });
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('tv-progress-text'))).data,
      'Uploading  64 KB of 128 KB',
    );
    await tester.pumpAndSettle();
    expect(argsOf(engine, 'tv.files.upload'), [
      {
        'id': tvId,
        'from': '/cache/file_picker/1/a.jpg',
        'path': '/sdcard/Download/a.jpg',
      },
      {
        'id': tvId,
        'from': '/cache/file_picker/1/b.mp4',
        'path': '/sdcard/Download/b.mp4',
      },
    ]);
    expect(phone.cleanups, 1);
    expect(find.text('Uploaded 2 items'), findsOneWidget);
  });

  testWidgets('progress for another TV is ignored', (tester) async {
    await openFiles(tester);
    engine.eventsOut.add({
      'event': 'tv.progress',
      'id': 'other_tv',
      'op': 'upload',
      'done': 1,
      'total': 2,
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('tv-progress')), findsNothing);
  });

  testWidgets('a folder that cannot be read keeps the current listing', (
    tester,
  ) async {
    engine.answerers['tv.files.list'] = (args) => args['path'] == '/sdcard'
        ? {
            'ok': true,
            'path': '/sdcard',
            'entries': [
              {'name': 'Android', 'type': 'dir'},
            ],
          }
        : {
            'ok': false,
            'error': {'type': 'invalid', 'message': 'Permission denied'},
          };
    await openFiles(tester);
    await tester.tap(find.text('Android'));
    await tester.pumpAndSettle();
    expect(find.text('Permission denied'), findsOneWidget);
    expect(shownNames(tester), ['Android']);
  });
}
