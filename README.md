## Dart SQLite API using native assets

This package implements a Dart SQLite API using the upcoming native assets
support.

### Native assets experiment

Currently, you need to enable the native assets experiment. For example, here is
how to run tests:

```shell
dart --enable-experiment=native-assets test
```

VS Code is configured to run tests with native assets enabled.

### FFI bindings

To generate the FFI bindings, run:

```shell
dart --enable-experiment=native-assets run ffigen
```