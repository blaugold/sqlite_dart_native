import 'package:logging/logging.dart';
import 'package:native_assets_cli/native_assets_cli.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  final buildConfig = await BuildConfig.fromArgs(args);
  final buildOutput = BuildOutput();

  final cbuilder = CBuilder.library(
    name: 'sqlite',
    assetId: 'package:sqlite_dart_native/src/sqlite_bindings.dart',
    sources: [
      'src/sqlite/sqlite3.c',
    ],
    defines: {
      if (buildConfig.target.os == OS.windows)
        // Make all SQLite API symbols visible.
        'SQLITE_API': '__declspec(dllexport)',
    },
  );
  await cbuilder.run(
    buildConfig: buildConfig,
    buildOutput: buildOutput,
    logger: Logger('')..onRecord.listen((message) => print(message.message)),
  );

  await buildOutput.writeToFile(outDir: buildConfig.outDir);
}
