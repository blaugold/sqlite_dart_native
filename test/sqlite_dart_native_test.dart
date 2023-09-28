import 'dart:typed_data';

import 'package:sqlite_dart_native/sqlite_dart_native.dart';
import 'package:sqlite_dart_native/src/sqlite_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('integrity check', () {
    test('returns null for valid database', () {
      final db = Database.memory();
      addTearDown(db.close);
      expect(db.integrityCheck(), isNull);
    });
  });

  test('close database while statement is not finalized', () {
    final db = Database.memory();
    addTearDown(db.close);
    final statement = db.prepareStatement('SELECT 1');
    addTearDown(statement.finalize);
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
  });

  group('Database', () {
    group('createScalarFunction', () {
      test('smoke', () {
        final db = Database.memory();
        addTearDown(db.close);
        db.createScalarFunction(
          'test',
          argumentCount: 1,
          (arguments) => arguments[0],
        );
        final results = db.execForSingleColumn("SELECT test('Hello world!')");
        expect(results, ['Hello world!']);
      });
    });

    group('createAggregateFunction', () {
      test('sum', () {
        final db = Database.memory();
        addTearDown(db.close);
        db.createAggregateFunction(
          'sum',
          argumentCount: 1,
          SumAggregator.new,
        );
        db.exec('CREATE TABLE t(value INTEGER)');
        db.exec('INSERT INTO t VALUES (1), (2), (3)');
        final results = db.execForSingleColumn("SELECT sum(value) FROM t");
        expect(results, [6]);
      });
    });

    group('createWindowFunction', () {
      test('sum', () {
        final db = Database.memory();
        addTearDown(db.close);
        db.createWindowFunction(
          'sum',
          argumentCount: 1,
          SumAggregator.new,
        );
        db.exec('CREATE TABLE t(x, y)');
        db.exec(
          "INSERT INTO t VALUES "
          "('a', 4), ('b', 5), ('c', 3), ('d', 8), ('e', 1)",
        );
        final results = db.execForSingleColumn(
          '''
          SELECT
            sum(y) OVER (
              ORDER BY x
              ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
            )
          FROM t
          ORDER BY x
          ''',
        );
        expect(results, [9, 12, 16, 12, 9]);
      });
    });
  });

  group('Statement', () {
    test('columnName', () {
      final db = Database.memory();
      addTearDown(db.close);
      final statement = db.prepareStatement('SELECT 1 AS a');
      addTearDown(statement.finalize);
      expect(statement.columnName(0), 'a');
    });

    test('valuesList', () {
      final db = Database.memory();
      addTearDown(db.close);
      final results =
          db.execMap('SELECT 1 AS a', (statement) => statement.valuesList());
      expect(results.single, [1]);
    });

    test('valuesMap', () {
      final db = Database.memory();
      addTearDown(db.close);
      final results =
          db.execMap('SELECT 1 AS a', (statement) => statement.valuesMap());
      expect(results.single, {'a': 1});
    });

    group('bind', () {
      test('should thrown when providing unsupported parameter identifier', () {
        final db = Database.memory();
        addTearDown(db.close);
        final statement = db.prepareStatement('SELECT ?');
        addTearDown(statement.finalize);
        expect(
          () => statement.bindNull(0.0),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('should thrown when providing unsupported parameter value', () {
        final db = Database.memory();
        addTearDown(db.close);
        final statement = db.prepareStatement('SELECT ?');
        addTearDown(statement.finalize);
        expect(
          () => statement.bindValue(0, []),
          throwsA(isA<ArgumentError>()),
        );
      });

      for (final named in [true, false]) {
        group(named ? 'name' : 'positional', () {
          test('Null', () {
            bindParameterTest(
              named: named,
              bind: (statement, index) => statement.bindNull(index),
              valueMatcher: null,
            );
          });

          test('Integer', () {
            const value = 1;
            bindParameterTest(
              named: named,
              bind: (statement, index) => statement.bindInteger(index, value),
              valueMatcher: value,
            );
          });

          test('Float', () {
            const value = 1.0;
            bindParameterTest(
              named: named,
              bind: (statement, index) => statement.bindFloat(index, value),
              valueMatcher: value,
            );
          });

          test('Text', () {
            const value = 'text';
            bindParameterTest(
              named: named,
              bind: (statement, index) => statement.bindText(index, value),
              valueMatcher: value,
            );
          });

          test('Blob', () {
            final value = Uint8List.fromList([1, 2, 3]);
            bindParameterTest(
              named: named,
              bind: (statement, index) => statement.bindBlob(index, value),
              valueMatcher: value,
            );
          });

          final values = [
            null,
            1,
            1.0,
            'text',
            Uint8List.fromList([1, 2, 3])
          ];

          for (final value in values) {
            test('Value(${value.runtimeType})', () {
              bindParameterTest(
                named: named,
                bind: (statement, index) => statement.bindValue(index, value),
                valueMatcher: value,
              );
            });
          }

          for (final value in values) {
            test('Values(${value.runtimeType})', () {
              bindParameterTest(
                named: named,
                bind: (statement, index) =>
                    statement.bindValues({index: value}),
                valueMatcher: value,
              );
            });
          }
        });
      }
    });
  });
}

void bindParameterTest({
  required void Function(Statement statement, Object parameter) bind,
  required Object? valueMatcher,
  bool named = false,
}) {
  final db = Database.memory();
  addTearDown(db.close);
  final statement = db.prepareStatement('SELECT ${named ? '@a' : '?'}');
  addTearDown(statement.finalize);
  bind(statement, named ? '@a' : 1);
  expect(statement.step(), isTrue);
  expect(statement.value(0), valueMatcher);
}

class SumAggregator implements WindowAggregator {
  int _sum = 0;

  @override
  Object? get currentValue => _sum;

  @override
  void onRow(List<Value> arguments) {
    final value = arguments[0].integer;
    if (value == null) {
      throw SQLiteException(
        'Argument of "sum" function must be an integer.',
        ErrorCode(SQLITE_MISMATCH),
      );
    }
    _sum += value;
  }

  @override
  void onRemoveRow(List<Value> arguments) {
    // The arguments are guaranteed to be the same as for onRow,
    // so we don't have to check the type again.
    final value = arguments[0].nonNullableInteger;
    _sum -= value;
  }

  @override
  int finalize() => _sum;
}

extension on Database {
  List<Object?> execForSingleColumn(String sql) =>
      execMap(sql, (statement) => statement.value(0));
}
