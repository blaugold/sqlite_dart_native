import 'package:sqlite_dart_native/sqlite_dart_native.dart';
import 'package:test/test.dart';

void main() {
  group('integrity check', () {
    test('returns null for valid database', () {
      final db = Database.memory();
      expect(db.integrityCheck(), isNull);
      db.close();
    });
  });

  test('close database while statement is not finalized', () {
    final db = Database.memory();
    final statement = db.prepareStatement('SELECT 1');
    expect(
      () => db.close(),
      throwsA(
        isA<SQLiteException>().having(
          (exception) => exception.errorCode,
          'errorCode',
          ErrorCode(5),
        ),
      ),
    );
    statement.finalize();
    db.close();
  });
}
