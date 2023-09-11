import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/custom_typedefs.dart';
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
// TODO: Define constants for all error codes.
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
  String get description =>
      // We don't have to ensure that _initializeSQLite is called here because
      // this SQLite API does not require it.
      sqlite3_errstr(value).cast<Utf8>().toDartString();

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

/// Initializes the SQLite library and must be called before most other SQLite
/// functions.
///
/// This function becomes a no-op after it is called once.
void _initializeSQLite() {
  final resultCode = sqlite3_initialize();
  if (resultCode != SQLITE_OK) {
    throw SQLiteException(
      'Failed to initialize the SQLite library.',
      ErrorCode(resultCode),
    );
  }
}

abstract interface class Aggregator {
  void onRow(List<Value> arguments);
  Object? finalize();
}

abstract interface class WindowAggregator implements Aggregator {
  Object? get currentValue;
  void onRemoveRow(List<Value> arguments);
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
    _initializeSQLite();

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

  static final _aggregators = <int, Aggregator>{};
  static final _windowAggregators = <int, WindowAggregator>{};

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
    } catch (error) {
      statement.reset();
      rethrow;
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

  void createScalarFunction(
    String name,
    Object? Function(List<Value> arguments) handler, {
    int? argumentCount,
    bool deterministic = false,
    bool directOnly = false,
    bool innocuous = false,
  }) {
    _createFunction(
      name: name,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      innocuous: innocuous,
      func: (context, argc, argv) {
        _callResultFunctionHandler(
          name: name,
          context: context,
          handler: () {
            assert(argumentCount == null || argc == argumentCount);

            final values = [
              for (var i = 0; i < argc; i++) Value._(argv[i], this)
            ];

            return handler(values);
          },
        );
      },
    );
  }

  void createAggregateFunction(
    String name,
    Aggregator Function() createAggregator, {
    int? argumentCount,
    bool deterministic = false,
    bool directOnly = false,
    bool innocuous = false,
  }) {
    _createFunction(
      name: name,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      innocuous: innocuous,
      step: (context, argc, argv) {
        _callFunctionHandler(
          name: name,
          context: context,
          handler: () {
            assert(argumentCount == null || argc == argumentCount);

            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 8 * 8 /* 64 bits */)
                    .cast<Int64>();
            if (aggregatorIdPointer == nullptr) {
              throw SQLiteException(
                'Failed to allocate memory for aggregate context.',
                ErrorCode(SQLITE_NOMEM),
              );
            }

            final aggregator = _aggregators.putIfAbsent(
              aggregatorIdPointer.value,
              createAggregator,
            );

            final values = [
              for (var i = 0; i < argc; i++) Value._(argv[i], this)
            ];

            aggregator.onRow(values);
          },
        );
      },
      final_: (context) {
        _callResultFunctionHandler(
          name: name,
          context: context,
          handler: () {
            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 0).cast<Int64>();
            return _aggregators.remove(aggregatorIdPointer.value)!.finalize();
          },
        );
      },
    );
  }

  void createWindowFunction(
    String name,
    WindowAggregator Function() createAggregator, {
    int? argumentCount,
    bool deterministic = false,
    bool directOnly = false,
    bool innocuous = false,
  }) {
    _createFunction(
      name: name,
      argumentCount: argumentCount,
      deterministic: deterministic,
      directOnly: directOnly,
      innocuous: innocuous,
      step: (context, argc, argv) {
        _callFunctionHandler(
          name: name,
          context: context,
          handler: () {
            assert(argumentCount == null || argc == argumentCount);

            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 8 * 8 /* 64 bits */)
                    .cast<Int64>();
            if (aggregatorIdPointer == nullptr) {
              throw SQLiteException(
                'Failed to allocate memory for aggregate context.',
                ErrorCode(SQLITE_NOMEM),
              );
            }

            final aggregator = _windowAggregators.putIfAbsent(
              aggregatorIdPointer.value,
              createAggregator,
            );

            final values = [
              for (var i = 0; i < argc; i++) Value._(argv[i], this)
            ];

            aggregator.onRow(values);
          },
        );
      },
      final_: (context) {
        _callResultFunctionHandler(
          name: name,
          context: context,
          handler: () {
            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 0).cast<Int64>();
            return _windowAggregators
                .remove(aggregatorIdPointer.value)!
                .finalize();
          },
        );
      },
      value: (context) {
        _callResultFunctionHandler(
          name: name,
          context: context,
          handler: () {
            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 0).cast<Int64>();
            return _windowAggregators[aggregatorIdPointer.value]!.currentValue;
          },
        );
      },
      inverse: (context, argc, argv) {
        _callFunctionHandler(
          name: name,
          context: context,
          handler: () {
            assert(argumentCount == null || argc == argumentCount);

            final aggregatorIdPointer =
                sqlite3_aggregate_context(context, 0).cast<Int64>();

            final aggregator = _windowAggregators[aggregatorIdPointer.value]!;

            final values = [
              for (var i = 0; i < argc; i++) Value._(argv[i], this)
            ];

            aggregator.onRemoveRow(values);
          },
        );
      },
    );
  }

  @pragma('vm:prefer-inline')
  void _createFunction({
    required String name,
    required int? argumentCount,
    required bool deterministic,
    required bool directOnly,
    required bool innocuous,
    sqlite3_func_callback? func,
    sqlite3_step_callback? step,
    sqlite3_final_callback? final_,
    sqlite3_value_callback? value,
    sqlite3_inverse_callback? inverse,
  }) {
    assert(
      func == null ||
          (step == null && final_ == null && value == null && inverse == null),
    );
    assert((step == null) == (final_ == null));
    assert((value == null) == (inverse == null));
    assert(value == null || step != null);

    argumentCount ??= -1;

    var flags = SQLITE_UTF8;
    if (deterministic) {
      flags |= SQLITE_DETERMINISTIC;
    }
    if (directOnly) {
      flags |= SQLITE_DIRECTONLY;
    }
    if (innocuous) {
      flags |= SQLITE_INNOCUOUS;
    }

    final callables = <NativeCallable>[];

    NativeCallable<sqlite3_func_callback_native>? funcCallable;
    if (func != null) {
      funcCallable = NativeCallable.isolateLocal(func);
      callables.add(funcCallable);
    }

    NativeCallable<sqlite3_step_callback_native>? stepCallable;
    if (step != null) {
      stepCallable = NativeCallable.isolateLocal(step);
      callables.add(stepCallable);
    }

    NativeCallable<sqlite3_final_callback_native>? finalCallable;
    if (final_ != null) {
      finalCallable = NativeCallable.isolateLocal(final_);
      callables.add(finalCallable);
    }

    NativeCallable<sqlite3_value_callback_native>? valueCallable;
    if (value != null) {
      valueCallable = NativeCallable.isolateLocal(value);
      callables.add(valueCallable);
    }

    NativeCallable<sqlite3_inverse_callback_native>? inverseCallable;
    if (inverse != null) {
      inverseCallable = NativeCallable.isolateLocal(inverse);
      callables.add(inverseCallable);
    }

    void destructor(Pointer<Void> _) {
      for (var callable in callables) {
        callable.close();
      }
    }

    final destructorCallable =
        NativeCallable<sqlite3_destructor_native>.isolateLocal(destructor);
    callables.add(destructorCallable);

    using((arena) {
      final namePointer = name.toNativeUtf8(allocator: arena).cast<Char>();

      if (func != null) {
        _checkResult(sqlite3_create_function_v2(
          /* db */ _pointer,
          /* zFunctionName */ namePointer,
          /* nArg */ argumentCount!,
          /* eTextRep */ flags,
          /* xApp */ nullptr,
          /* xFunc */ funcCallable!.nativeFunction,
          /* xStep */ nullptr,
          /* xFinal */ nullptr,
          /* xDestroy */ destructorCallable.nativeFunction,
        ));
      } else {
        _checkResult(sqlite3_create_window_function(
          /* db */ _pointer,
          /* zFunctionName */ namePointer,
          /* nArg */ argumentCount!,
          /* eTextRep */ flags,
          /* xApp */ nullptr,
          /* xStep */ stepCallable!.nativeFunction,
          /* xFinal */ finalCallable!.nativeFunction,
          /* xValue */ valueCallable?.nativeFunction ?? nullptr,
          /* xInverse */ inverseCallable?.nativeFunction ?? nullptr,
          /* xDestroy */ destructorCallable.nativeFunction,
        ));
      }
    });
  }

  @pragma('vm:prefer-inline')
  void _checkResult(int resultCode) {
    if (resultCode == SQLITE_OK) {
      return;
    }

    throw SQLiteException(
      sqlite3_errmsg(_pointer).cast<Utf8>().toDartString(),
      ErrorCode(resultCode),
    );
  }

  @pragma('vm:prefer-inline')
  void _callResultFunctionHandler({
    required String name,
    required Pointer<sqlite3_context> context,
    required Object? Function() handler,
  }) {
    _callFunctionHandler(
      name: name,
      context: context,
      handler: () {
        switch (handler()) {
          case null:
            sqlite3_result_null(context);
          case final int result:
            sqlite3_result_int64(context, result);
          case final double result:
            sqlite3_result_double(context, result);
          case final String result:
            final encoded = utf8.encode(result);
            final memory = malloc<Uint8>(encoded.length);
            memory.asTypedList(encoded.length).setAll(0, encoded);
            sqlite3_result_text(
              context,
              memory.cast(),
              encoded.length,
              malloc.nativeFree,
            );
          case final Uint8List result:
            final memory = malloc<Uint8>(result.length);
            memory.asTypedList(result.length).setAll(0, result);
            sqlite3_result_blob(
              context,
              memory.cast(),
              result.length,
              malloc.nativeFree,
            );
          case Value(:final _pointer):
            sqlite3_result_value(context, _pointer);
          case final result:
            // TODO: Provide mechanism to log this type of error.
            throw SQLiteException(
              'Function "$name" returned value of unsupported type: $result',
              ErrorCode(SQLITE_INTERNAL),
            );
        }
      },
    );
  }
}

@pragma('vm:prefer-inline')
void _callFunctionHandler({
  required String name,
  required Pointer<sqlite3_context> context,
  required void Function() handler,
}) {
  try {
    try {
      handler();
    } on SQLiteException {
      rethrow;
    } on OutOfMemoryError {
      throw SQLiteException(
        'Function "$name" encountered an OutOfMemoryError.',
        ErrorCode(SQLITE_NOMEM),
      );
    } catch (error, stackTrace) {
      // TODO: Provide mechanism to log this type of error.
      throw SQLiteException(
        'Function "$name" threw an error of unsupported type: $error\n'
        '$stackTrace',
        ErrorCode(SQLITE_INTERNAL),
      );
    }
  } on SQLiteException catch (error) {
    if (error.errorCode.value == SQLITE_NOMEM) {
      // TODO: Log this error, since we cannot propagate the error message.
      // But maybe not since we are already OOM?
      sqlite3_result_error_nomem(context);
    } else {
      using((arena) {
        sqlite3_result_error(
          context,
          error.message.toNativeUtf8(allocator: arena).cast(),
          -1,
        );
        sqlite3_result_error_code(context, error.errorCode.value);
      });
    }
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
  final _namedParameterIndices = <String, int>{};

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

  /// Binds multiple values to parameters.
  ///
  /// This method is equivalent to calling [bindValue] for each entry in
  /// [values].
  void bindValues(Map<Object, Object?> values) => values.forEach(bindValue);

  /// Binds a value to a parameter.
  ///
  /// {@template Statement.bindValue}
  /// The [indexOrName] can be either an integer or a string. If it is an
  /// integer, it is the index of the parameter to bind. If it is a string, it
  /// is the name of the parameter to bind.
  ///
  /// Throws an [ArgumentError] if [indexOrName] is not an integer or a string,
  /// or is not a valid index or name for a parameter.
  /// {@endtemplate}
  ///
  /// If [value] is null, [bindNull] is called.
  /// If [value] is an integer, [bindInteger] is called.
  /// If [value] is a floating-point number, [bindFloat] is called.
  /// If [value] is a string, [bindText] is called.
  /// If [value] is a blob, [bindBlob] is called.
  ///
  /// Throws an [ArgumentError] if [value] is not null and is not one of the
  /// supported types.
  void bindValue(Object indexOrName, Object? value) {
    switch (value) {
      case null:
        bindNull(indexOrName);
      case final int value:
        bindInteger(indexOrName, value);
      case final double value:
        bindFloat(indexOrName, value);
      case final String value:
        bindText(indexOrName, value);
      case final Uint8List value:
        bindBlob(indexOrName, value);
      default:
        throw ArgumentError.value(
          value,
          'value',
          'is not of a type supported by SQLite',
        );
    }
  }

  /// Binds null to a parameter.
  ///
  /// {@macro Statement.bindValue}
  void bindNull(Object indexOrName) {
    _db._checkResult(sqlite3_bind_null(
      _pointer,
      _indexForParameter(indexOrName),
    ));
  }

  /// Binds an integer number to a parameter.
  ///
  /// {@macro Statement.bindValue}
  void bindInteger(Object indexOrName, int value) {
    _db._checkResult(sqlite3_bind_int64(
      _pointer,
      _indexForParameter(indexOrName),
      value,
    ));
  }

  /// Binds a floating-point number to a parameter.
  ///
  /// {@macro Statement.bindValue}
  void bindFloat(Object indexOrName, double value) {
    _db._checkResult(sqlite3_bind_double(
      _pointer,
      _indexForParameter(indexOrName),
      value,
    ));
  }

  /// Binds a string to a parameter.
  ///
  /// {@macro Statement.bindValue}
  void bindText(Object indexOrName, String value) {
    final index = _indexForParameter(indexOrName);
    final encoded = utf8.encode(value);
    final memory = malloc<Uint8>(encoded.length);
    memory.asTypedList(encoded.length).setAll(0, encoded);

    _db._checkResult(sqlite3_bind_text(
      _pointer,
      index,
      memory.cast(),
      encoded.length,
      malloc.nativeFree,
    ));
  }

  /// Binds a blob to a parameter.
  ///
  /// {@macro Statement.bindValue}
  void bindBlob(Object indexOrName, Uint8List value) {
    final index = _indexForParameter(indexOrName);
    final memory = malloc<Uint8>(value.length);
    memory.asTypedList(value.length).setAll(0, value);

    _db._checkResult(sqlite3_bind_blob(
      _pointer,
      index,
      memory.cast(),
      value.length,
      malloc.nativeFree,
    ));
  }

  int _indexForParameter(Object indexOrName) {
    return switch (indexOrName) {
      final int index => index,
      final String name => _indexForNamedParameter(name),
      _ => throw ArgumentError.value(
          indexOrName,
          'indexOrName',
          'is not of a supported type for a parameter',
        ),
    };
  }

  int _indexForNamedParameter(String name) {
    return _namedParameterIndices.putIfAbsent(name, () {
      return using((arena) {
        final index = sqlite3_bind_parameter_index(
          _pointer,
          name.toNativeUtf8(allocator: arena).cast(),
        );

        if (index == 0) {
          throw ArgumentError.value(
            name,
            'indexOrName',
            'is not a known parameter name',
          );
        }

        return index;
      });
    });
  }

  /// Returns of the name assigned to the column at the given [index] in the
  /// result set.
  String columnName(int index) {
    var pointer = sqlite3_column_name(_pointer, index);
    if (pointer == nullptr) {
      // If the pointer is null, memory allocation failed.
      throw SQLiteException(
        'Unable to get the name of the column at index $index.',
        ErrorCode(SQLITE_NOMEM),
      );
    }
    return pointer.cast<Utf8>().toDartString();
  }

  /// Returns the [Datatype] of the value in the column at the given [index].
  Datatype type(int index) =>
      Datatype._fromCode(sqlite3_column_type(_pointer, index));

  /// Returns whether the value in the column at the given [index] is null.
  bool isNull(int index) => sqlite3_column_type(_pointer, index) == SQLITE_NULL;

  /// Reads a column value as an integer.
  ///
  /// If the value is not an integer, it is converted to an integer.
  int nonNullableInteger(int index) => sqlite3_column_int64(_pointer, index);

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

  /// Reads all column values without converting them and returns them as a
  /// list.
  List<Object?> valuesList() =>
      [for (var i = 0; i < columnCount; i++) value(i)];

  /// Reads all column values without converting them, and returns them as a
  /// map from result set column names to values.
  Map<String, Object?> valuesMap() =>
      {for (var i = 0; i < columnCount; i++) columnName(i): value(i)};

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

/// A dynamically typed SQLite value.
class Value {
  Value._(this._pointer, this._db);

  final Pointer<sqlite3_value> _pointer;
  final Database _db;

  /// Returns the [Datatype] of this value.
  Datatype get type => Datatype._fromCode(sqlite3_value_type(_pointer));

  /// Returns whether this value is null.
  bool get isNull => sqlite3_value_type(_pointer) == SQLITE_NULL;

  /// Reads this value as an integer.
  ///
  /// If the value is not an integer, it is converted to an integer.
  int get nonNullableInteger => sqlite3_value_int64(_pointer);

  /// Reads this value as an integer, or null if the value is null.
  ///
  /// If the value is not an integer, it is converted to an integer.
  int? get integer {
    // This method is optimized for the common case where the value is not null
    // and not zero.
    final value = nonNullableInteger;
    if (value == 0 && isNull) {
      return null;
    }
    return value;
  }

  /// Reads this value as a floating-point number.
  ///
  /// If the value is not a floating-point number, it is converted to a
  /// floating-point number.
  double get nonNullableFloat => sqlite3_value_double(_pointer);

  /// Reads this value as a floating-point number, or null if the value is
  /// null.
  ///
  /// If the value is not a floating-point number, it is converted to a
  /// floating-point number.
  double? get float {
    // This method is optimized for the common case where the value is not null
    // and not zero.
    final value = nonNullableFloat;
    if (value == 0 && isNull) {
      return null;
    }
    return value;
  }

  /// Reads this value as a string, or null if the value is null.
  ///
  /// If the value is not a string, it is converted to a string.
  String? get text {
    final data = sqlite3_value_text(_pointer).cast<Utf8>();
    if (data == nullptr) {
      // Check if out-of-memory error occurred.
      _db._checkResult(sqlite3_errcode(_db._pointer));
      return null;
    }
    final length = sqlite3_value_bytes(_pointer);
    return data.toDartString(length: length);
  }

  /// Reads this value as a blob, or null if the value is null.
  ///
  /// If the value is not a blob, it is converted to a blob.
  Uint8List? get blob {
    final data = sqlite3_value_blob(_pointer).cast<Uint8>();
    if (data == nullptr) {
      // Check if out-of-memory error occurred.
      _db._checkResult(sqlite3_errcode(_db._pointer));
      return null;
    }
    final length = sqlite3_value_bytes(_pointer);
    return Uint8List.fromList(data.asTypedList(length));
  }

  /// Reads this value without converting it.
  Object? get value {
    var code = sqlite3_value_type(_pointer);
    switch (code) {
      case SQLITE_INTEGER:
        return nonNullableInteger;
      case SQLITE_FLOAT:
        return nonNullableFloat;
      case SQLITE_TEXT:
        return text;
      case SQLITE_BLOB:
        return blob;
      case SQLITE_NULL:
        return null;
    }
    throw UnimplementedError('Unknown datatype code: $code');
  }
}
