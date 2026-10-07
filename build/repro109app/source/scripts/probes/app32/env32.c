#include <windows.h>
#include <stdio.h>
#include <string.h>

/* A parent variable is deliberately present in the gate controller. Only an
 * explicit app.env override may reach this Windows process. No user data. */
int main(int argc, char **argv)
{
    const char expected[] = "Z:\\acceptance path\\314159=x87";
    char value[512] = {0}, hex[1025] = {0}, line[1400];
    DWORD length, error, written;
    int want_present, ok, count, i;
    if (argc != 3 || strcmp(argv[1], "--gate-env")) return 2;
    want_present = !strcmp(argv[2], "present");
    SetLastError(0);
    length = GetEnvironmentVariableA("APP32_ACCEPTANCE_ENV_TEST", value, sizeof(value));
    error = GetLastError();
    ok = want_present ? length == strlen(expected) && !strcmp(value, expected)
                      : length == 0 && error == ERROR_ENVVAR_NOT_FOUND;
    for (i = 0; i < (int)length && i < (int)sizeof(value); ++i)
        sprintf(hex + 2*i, "%02x", (unsigned char)value[i]);
    count = snprintf(line, sizeof(line), "ENV_RESULT present=%d bytes=%lu value_hex=%s argv_extra=0 result=%s\n",
                     length != 0, (unsigned long)length, hex, ok ? "PASS" : "FAIL");
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, count, &written, NULL);
    return ok ? 0 : 1;
}
