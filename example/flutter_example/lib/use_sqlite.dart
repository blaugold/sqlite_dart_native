import 'package:sqlite_dart_native/sqlite_dart_native.dart';

void useSqlite() {
  final db = Database.memory();
  try {
    db.exec('create table test (id integer primary key, name text not null)');

    final statement = db.prepareStatement('select * from sqlite_master');
    try {
      while (statement.step()) {
        // ignore: avoid_print
        print(statement.valuesMap());
      }
    } finally {
      statement.finalize();
    }
  } finally {
    db.close();
  }
}
