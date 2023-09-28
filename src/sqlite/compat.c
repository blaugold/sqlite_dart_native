#include <sqlite3.h>

char *read_sqlite3_temp_directory() { return sqlite3_temp_directory; }

void write_sqlite3_temp_directory(char *value) {
  sqlite3_temp_directory = value;
}
