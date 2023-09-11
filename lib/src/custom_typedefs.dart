// ignore_for_file: camel_case_types

import 'dart:ffi' as ffi;

import 'package:sqlite_dart_native/src/sqlite_bindings.dart';

typedef sqlite3_destructor_native = ffi.Void Function(ffi.Pointer<ffi.Void>);

typedef sqlite3_func_callback_native = ffi.Void Function(
  ffi.Pointer<sqlite3_context>,
  ffi.Int,
  ffi.Pointer<ffi.Pointer<sqlite3_value>>,
);

typedef sqlite3_func_callback = void Function(
  ffi.Pointer<sqlite3_context> context,
  int argc,
  ffi.Pointer<ffi.Pointer<sqlite3_value>> argv,
);

typedef sqlite3_step_callback_native = ffi.Void Function(
  ffi.Pointer<sqlite3_context>,
  ffi.Int,
  ffi.Pointer<ffi.Pointer<sqlite3_value>>,
);

typedef sqlite3_step_callback = void Function(
  ffi.Pointer<sqlite3_context> context,
  int argc,
  ffi.Pointer<ffi.Pointer<sqlite3_value>> argv,
);

typedef sqlite3_final_callback_native = ffi.Void Function(
  ffi.Pointer<sqlite3_context>,
);

typedef sqlite3_final_callback = void Function(
  ffi.Pointer<sqlite3_context> context,
);

typedef sqlite3_value_callback_native = ffi.Void Function(
  ffi.Pointer<sqlite3_context>,
);

typedef sqlite3_value_callback = void Function(
  ffi.Pointer<sqlite3_context> context,
);

typedef sqlite3_inverse_callback_native = ffi.Void Function(
  ffi.Pointer<sqlite3_context>,
  ffi.Int,
  ffi.Pointer<ffi.Pointer<sqlite3_value>>,
);

typedef sqlite3_inverse_callback = void Function(
  ffi.Pointer<sqlite3_context> context,
  int argc,
  ffi.Pointer<ffi.Pointer<sqlite3_value>> argv,
);
