import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/sqlite_bindings.dart';

/// An exception that is thrown when an SQLite operation fails.
class SQLiteException implements Exception {
  SQLiteException(this.message, this.errorCode);

  /// A message describing the exception.
  final String message;

  /// The SQLite error code.
  final ErrorCode errorCode;

  @override
  String toString() => 'SQLiteException($message, code: $errorCode)';
}

/// An error code returned by SQLite that describes the cause of a failure.
class ErrorCode {
  /// Creates an [ErrorCode] from the given integer [value].
  const ErrorCode(this.value)
      : assert(
          value != SQLITE_OK && value != SQLITE_ROW && value != SQLITE_DONE,
        );

  /// The integer value that is returned by SQLite.
  final int value;

  /// Whether this is a primary error code.
  bool get isPrimaryCode => !isExtendedCode;

  /// Whether this is an extended error code.
  bool get isExtendedCode => value > 0xFF;

  /// The corresponding primary error code for this error code.
  ///
  /// Returns this error code if it is already a primary error code.
  ErrorCode get primaryCode {
    final primaryCode = value & 0xFF;
    return primaryCode == value ? this : ErrorCode(primaryCode);
  }

  /// A description of this error code.
  String get description => sqlite3_errstr(value).cast<Utf8>().toDartString();

  @override
  bool operator ==(Object other) => other is ErrorCode && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() {
    var result = 'ErrorCode(';

    final primary = primaryCode;
    result += '${primary.value}: ${primary.description}';

    if (isExtendedCode) {
      result += ' | $value: $description';
    }

    result += ')';

    return result;
  }
}

/// An SQLite database.
///
/// You need to [close] a database when you are done with it in order to release
/// the resources it uses.
class Database {
  /// Opens the database at the given [path].
  ///
  /// If the database does not exist, it will be created.
  factory Database(String path) {
    return using((arena) {
      final dbPtr = arena.allocate<Pointer<sqlite3>>(1);
      final resultCode =
          sqlite3_open(path.toNativeUtf8(allocator: arena).cast(), dbPtr);
      final db = Database._(dbPtr.value);

      try {
        db._checkResult(resultCode);
        return db;
      } catch (_) {
        db.close();
        rethrow;
      }
    });
  }

  /// Opens an in-memory database.
  factory Database.memory() => Database(':memory:');

  Database._(this._pointer);

  final Pointer<sqlite3> _pointer;

  /// Closes the database.
  void close() => _checkResult(sqlite3_close(_pointer));

  /// Prepares and returns an SQL statement.
  ///
  /// The statement can be executed multiple times with different parameters.
  ///
  /// You need to call [Statement.finalize] when you are done with the statement
  /// in order to release the resources it uses.
  Statement prepareStatement(String sql) => Statement._prepare(this, sql);

  /// Executes the given SQL statement without returning any data.
  void exec(String sql) => execMap(sql, (_) {});

  /// Executes the given SQL statement and creates a list of results by calling
  /// [fn] for each row.
  List<T> execMap<T>(String sql, T Function(Statement) fn) {
    final statement = prepareStatement(sql);
    try {
      return statement.map(fn);
    } finally {
      statement.finalize();
    }
  }

  /// Runs an integrity check on the database.
  ///
  /// Returns null if the integrity check was successful, or a list of error
  /// messages otherwise.
  List<String>? integrityCheck() {
    final rows =
        execMap('PRAGMA integrity_check;', (statement) => statement.text(0)!);
    return rows.first == 'ok' ? null : rows;
  }

  void _checkResult(int resultCode) {
    if (resultCode == SQLITE_OK) {
      return;
    }

    throw SQLiteException(
      sqlite3_errmsg(_pointer).cast<Utf8>().toDartString(),
      ErrorCode(resultCode),
    );
  }
}

/// A prepared SQL statement.
///
/// Use [Database.prepareStatement] to create a statement.
class Statement {
  factory Statement._prepare(Database db, String sql) {
    return using((arena) {
      final statementPtr = arena.allocate<Pointer<sqlite3_stmt>>(1);

      db._checkResult(sqlite3_prepare_v2(
        db._pointer,
        sql.toNativeUtf8(allocator: arena).cast(),
        -1,
        statementPtr,
        nullptr,
      ));

      return Statement._(db, statementPtr.value);
    });
  }

  Statement._(this._db, this._pointer);

  final Database _db;
  final Pointer<sqlite3_stmt> _pointer;

  /// The number of columns in each row of the result set.
  late final columnCount = sqlite3_column_count(_pointer);

  /// The number of values in the current row of the result set.
  int get dataCount => sqlite3_data_count(_pointer);

  /// Moves to the next row of the result set.
  ///
  /// Call this method before reading the values of a row. If it returns true,
  /// the columns of a row can now be read. If it returns false, there are no
  /// more rows.
  bool step() {
    final resultCode = sqlite3_step(_pointer);
    if (resultCode == SQLITE_ROW) {
      return true;
    } else if (resultCode == SQLITE_DONE) {
      return false;
    }

    _db._checkResult(resultCode);

    // Unreachable because checkSqliteResult will always throw in this case.
    return false;
  }

  /// Releases the resources used by this statement.
  ///
  /// After calling this method, the statement can no longer be used.
  void finalize() => _db._checkResult(sqlite3_finalize(_pointer));

  /// Resets this statement so that it can be executed again.
  void reset() => _db._checkResult(sqlite3_reset(_pointer));

  /// Returns the [Datatype] of the value in the column at the given [index].
  Datatype type(int index) =>
      Datatype._fromCode(sqlite3_column_type(_pointer, index));

  /// Returns whether the value in the column at the given [index] is null.
  bool isNull(int index) => sqlite3_column_type(_pointer, index) == SQLITE_NULL;

  /// Reads a column value as an integer.
  ///
  /// If the value is not an integer, it is converted to an integer.
  int nonNullableInteger(int index) => sqlite3_column_int(_pointer, index);

  /// Reads a column value as an integer, or null if the value is null.
  ///
  /// If the value is not an integer, it is converted to an integer.
  int? integer(int index) {
    // This method is optimized for the common case where the value is not null
    // and not zero.
    final value = nonNullableInteger(index);
    if (value == 0 && isNull(index)) {
      return null;
    }
    return value;
  }

  /// Reads a column value as a floating-point number.
  ///
  /// If the value is not a floating-point number, it is converted to a
  /// floating-point number.
  double nonNullableFloat(int index) => sqlite3_column_double(_pointer, index);

  /// Reads a column value as a floating-point number, or null if the value is
  /// null.
  ///
  /// If the value is not a floating-point number, it is converted to a
  /// floating-point number.
  double? float(int index) {
    // This method is optimized for the common case where the value is not null
    // and not zero.
    final value = nonNullableFloat(index);
    if (value == 0 && isNull(index)) {
      return null;
    }
    return value;
  }

  /// Reads a column value as a string, or null if the value is null.
  ///
  /// If the value is not a string, it is converted to a string.
  String? text(int index) {
    final data = sqlite3_column_text(_pointer, index).cast<Utf8>();
    if (data == nullptr) {
      // Check if out-of-memory error occurred.
      _db._checkResult(sqlite3_errcode(_db._pointer));
      return null;
    }
    final length = sqlite3_column_bytes(_pointer, index);
    return data.toDartString(length: length);
  }

  /// Reads a column value as a blob, or null if the value is null.
  ///
  /// If the value is not a blob, it is converted to a blob.
  Uint8List? blob(int index) {
    final data = sqlite3_column_blob(_pointer, index).cast<Uint8>();
    if (data == nullptr) {
      // Check if out-of-memory error occurred.
      _db._checkResult(sqlite3_errcode(_db._pointer));
      return null;
    }
    final length = sqlite3_column_bytes(_pointer, index);
    return Uint8List.fromList(data.asTypedList(length));
  }

  /// Reads a column value without converting it.
  Object? value(int index) {
    var code = sqlite3_column_type(_pointer, index);
    switch (code) {
      case SQLITE_INTEGER:
        return nonNullableInteger(index);
      case SQLITE_FLOAT:
        return nonNullableFloat(index);
      case SQLITE_TEXT:
        return text(index);
      case SQLITE_BLOB:
        return blob(index);
      case SQLITE_NULL:
        return null;
    }
    throw UnimplementedError('Unknown datatype code: $code');
  }

  /// Reads all column values without converting them.
  List<Object?> values() => List.generate(columnCount, value);

  /// Creates a list of all the results in the result set by calling [fn] for
  /// each row.
  List<T> map<T>(T Function(Statement) fn) {
    final result = <T>[];
    while (step()) {
      result.add(fn(this));
    }
    return result;
  }
}

/// A SQLite datatype.
enum Datatype {
  /// The value is a signed integer, stored in 0, 1, 2, 3, 4, 6, or 8 bytes
  /// depending on the magnitude of the value.
  integer,

  /// The value is a floating point value, stored as an 8-byte IEEE floating
  /// point number.
  float,

  /// The value is a text string, stored using the database encoding
  /// (UTF-8, UTF-16BE or UTF-16LE).
  text,

  /// The value is a blob of data, stored exactly as it was input.
  blob,

  /// The value is a NULL value.
  null_;

  static Datatype _fromCode(int code) {
    switch (code) {
      case SQLITE_INTEGER:
        return integer;
      case SQLITE_FLOAT:
        return float;
      case SQLITE_TEXT:
        return text;
      case SQLITE_BLOB:
        return blob;
      case SQLITE_NULL:
        return null_;
    }
    throw UnimplementedError('Unknown datatype type: $code');
  }
}
