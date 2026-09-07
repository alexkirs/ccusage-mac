// CPU temperature on Apple Silicon from the SMC (no root): the hottest of the
// "Tp??" float keys, floored, which is exactly what Hot.app shows. Keys are
// discovered once by brute force (~0.8 s), then only those are re-read.
// Prints one integer °C per line every N seconds (`sensors 5`) or once.
// Built on demand by sensors.lua. Exits by SIGPIPE when Hammerspoon closes the pipe.
// ponytail: arm64 only; Intel SMC uses different keys and yields 0.
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
  uint32_t key;
  struct { uint8_t major, minor, build, reserved; uint16_t release; } vers;
  struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } pLimit;
  SMCKeyInfo keyInfo;
  uint8_t result, status, data8;
  uint32_t data32;
  uint8_t bytes[32];
} SMCParam;

static io_connect_t conn;
static kern_return_t call(SMCParam *in, SMCParam *out) {
  size_t sz = sizeof(SMCParam);
  return IOConnectCallStructMethod(conn, 2, in, sz, out, &sz);
}
static uint32_t str4(const char *s) { return (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]; }

// 1 and *v set when key exists and is a float.
static int readFlt(uint32_t key, float *v) {
  SMCParam in = {0}, out = {0};
  in.key = key; in.data8 = 9;                        // key info
  if (call(&in, &out) || out.result || out.keyInfo.dataType != str4("flt ")) return 0;
  in.keyInfo = out.keyInfo; in.data8 = 5;            // read
  if (call(&in, &out) || out.result) return 0;
  memcpy(v, out.bytes, 4);
  return 1;
}

int main(int argc, char **argv) {
  int interval = argc > 1 ? atoi(argv[1]) : 0;
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != KERN_SUCCESS) {
    fprintf(stderr, "no AppleSMC\n"); return 1;
  }
  static const char cs[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
  uint32_t keys[128]; int n = 0; float v;
  for (const char *a = cs; *a && n < 128; a++)
    for (const char *b = cs; *b && n < 128; b++) {
      char ks[4] = { 'T', 'p', *a, *b };
      uint32_t k = str4(ks);
      if (readFlt(k, &v) && v > 0 && v < 130) keys[n++] = k;
    }
  setvbuf(stdout, NULL, _IOLBF, 0);
  for (;;) {
    float best = 0;
    for (int i = 0; i < n; i++)
      if (readFlt(keys[i], &v) && v > best && v < 130) best = v;
    printf("%d\n", (int)floorf(best));
    if (!interval) break;
    sleep(interval);
  }
}
