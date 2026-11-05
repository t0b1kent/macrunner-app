/* DIAGNOSTIC_ONLY: separate Wine device initialization from COM registration.
 * Never invokes DllRegisterServer, DllInstall, or wineboot -u.
 * Modes: ole; display; spool; printers. Each later mode includes preceding work.
 */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <winspool.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    const char *mode = argc == 2 ? argv[1] : "ole";
    if (strcmp(mode, "ole") && strcmp(mode, "display") && strcmp(mode, "spool") && strcmp(mode, "printers")) return 2;
    printf("DEVICE_REFRESH start mode=%s direct_registration_calls=0\n", mode);
    fflush(stdout);
    HRESULT hr = OleInitialize(NULL);
    printf("DEVICE_REFRESH OleInitialize=0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 3;
    int result = 0;
    if (strcmp(mode, "ole")) {
        DWORD count = 0;
        DISPLAY_DEVICEW device;
        for (;;) {
            ZeroMemory(&device, sizeof(device));
            device.cb = sizeof(device);
            SetLastError(ERROR_SUCCESS);
            if (!EnumDisplayDevicesW(NULL, count, &device, 0)) {
                DWORD error = GetLastError();
                if (!count) {
                    printf("DEVICE_REFRESH no display adapters error=%lu\n", error);
                    OleUninitialize();
                    return 8; /* Conservatively use the full-update fallback. */
                }
                break;
            }
            printf("DEVICE_REFRESH display=%lu flags=0x%08lx\n", count, device.StateFlags);
            ++count;
        }
        printf("DEVICE_REFRESH displays=%lu\n", count);
    }
    if (!strcmp(mode, "spool") || !strcmp(mode, "printers")) {
        typedef BOOL (WINAPI *enum_printers_fn)(DWORD, LPWSTR, DWORD, LPBYTE, DWORD, LPDWORD, LPDWORD);
        HMODULE spool = LoadLibraryW(L"winspool.drv");
        enum_printers_fn enumerate = spool ? (enum_printers_fn)GetProcAddress(spool, "EnumPrintersW") : NULL;
        if (!enumerate) {
            printf("DEVICE_REFRESH printer loader error=%lu\n", GetLastError());
            if (spool) FreeLibrary(spool);
            OleUninitialize();
            return 7;
        }
        if (!strcmp(mode, "printers")) {
        DWORD needed = 0, count = 0;
        SetLastError(ERROR_SUCCESS);
        BOOL ok = enumerate(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 4,
                               NULL, 0, &needed, &count);
        DWORD error = GetLastError();
        if (!ok && error != ERROR_INSUFFICIENT_BUFFER) {
            printf("DEVICE_REFRESH EnumPrinters error=%lu\n", error);
            result = 4;
        } else if (needed) {
            BYTE *buffer = HeapAlloc(GetProcessHeap(), 0, needed);
            if (!buffer) result = 5;
            else {
                ok = enumerate(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 4,
                                   buffer, needed, &needed, &count);
                if (!ok) { printf("DEVICE_REFRESH EnumPrinters error=%lu\n", GetLastError()); result = 6; }
                HeapFree(GetProcessHeap(), 0, buffer);
            }
        }
        printf("DEVICE_REFRESH printers=%lu\n", count);
        } else printf("DEVICE_REFRESH printer discovery loaded\n");
        FreeLibrary(spool);
    }
    OleUninitialize();
    printf("DEVICE_REFRESH END status=%d direct_registration_calls=0\n", result);
    return result;
}
