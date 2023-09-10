import 'package:logging/logging.dart';
import 'package:native_assets_cli/native_assets_cli.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:sqlite_dart_native/src/sqlite_bindings.dart';

void main(List<String> args) async {
  final buildConfig = await BuildConfig.fromArgs(args);
  final buildOutput = BuildOutput();

  final cbuilder = CBuilder.library(
    name: 'sqlite',
    assetId: 'package:sqlite_dart_native/src/sqlite_bindings.dart',
    sources: [
      'src/sqlite/sqlite3.c',
    ],
    // TODO: Make build options consumer configurable.
    defines: {
      if (buildConfig.targetOs == OS.windows)
        // Make all SQLite API symbols visible.
        'SQLITE_API': '__declspec(dllexport)',
      // Change the default to multi-threaded from serialized.
      // Dart is single-threaded, so serialization is not required for
      // individual SQLite objects. But there can be multipel Dart isolates,
      // so multi-threaded is required.
      // https://www.sqlite.org/threadsafe.html
      'SQLITE_THREADSAFE': SQLITE_CONFIG_MULTITHREAD.toString(),
      // Disable double-quoted string literals.
      'SQLITE_DQS': '0',
      // Disable memory usage statistics. Probably rarely used and disabling
      // it improves overall performance.
      'SQLITE_DEFAULT_MEMSTATUS': '0',
      // Use 'PRAGMA synchronous=NORMAL' as the default for WAL mode.
      'SQLITE_DEFAULT_WAL_SYNCHRONOUS': '1',
      // Don't support matching BLOBs with LIKE.
      'SQLITE_LIKE_DOESNT_MATCH_BLOBS': null,
      // Don't limit the depth of expression trees.
      'SQLITE_MAX_EXPR_DEPTH': '0',
      // Omit unused API to get declaration type of columns.
      'SQLITE_OMIT_DECLTYPE': null,
      // Omit deprecated features.
      'SQLITE_OMIT_DEPRECATED': null,
      // Omit support for discouraged shared cache feature.
      'SQLITE_OMIT_SHARED_CACHE': null,
      // Use `alloca` on platforms that support it.
      'SQLITE_USE_ALLOCA': null,
      // We initialize SQLite manually, so don't do it automatically.
      'SQLITE_OMIT_AUTOINIT': null,
      // We only use UTF-8, so don't there is no point including UTF-16 support.
      'SQLITE_OMIT_UTF16': null,
      if (buildConfig.buildMode == BuildMode.debug) ...{
        // Enable SQLite internal checks.
        'SQLITE_DEBUG': null,
        'SQLITE_MEMDEBUG': null,
        // Enable SQLite API usage checks.
        'SQLITE_ENABLE_API_ARMOR': null
      }
    },
  );
  await cbuilder.run(
    buildConfig: buildConfig,
    buildOutput: buildOutput,
    logger: Logger('')..onRecord.listen((message) => print(message.message)),
  );

  await buildOutput.writeToFile(outDir: buildConfig.outDir);
}
