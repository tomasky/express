/*
 * Tiny native stub for the benchmark server: reads an optional `BENCH_PORT`
 * environment variable (the package cannot read the environment from pure
 * MoonBit yet). Returns 0 when unset or unparsable, so the MoonBit side falls
 * back to its default port.
 */
#include <moonbit.h>
#include <stdlib.h>

int32_t bench_env_port(void) {
  const char *value = getenv("BENCH_PORT");
  if (value == NULL) {
    return 0;
  }
  int port = atoi(value);
  if (port <= 0 || port > 65535) {
    return 0;
  }
  return (int32_t)port;
}
