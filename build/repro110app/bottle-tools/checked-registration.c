/* Observe every INF registration result; wineboot's exit code cannot attest it.
 * Built as native ARM64 and i386, matching wineboot's registration processes. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <setupapi.h>
#include <stdio.h>
#include <wchar.h>
#include <stdlib.h>

struct item {
    WCHAR file[512], args[2048], path[2048], expected_path[2048];
    DWORD timeout;
    BOOL exe, started, ended, skipped;
};
struct context {
    struct item *items;
    LONG count, starts, ends, skips, exes;
    BOOL failed;
};
static const WCHAR *basename(const WCHAR *path)
{
    const WCHAR *last = path;
    for (; *path; ++path) if (*path == L'\\' || *path == L'/') last = path + 1;
    return last;
}
static UINT CALLBACK observe(PVOID data, UINT note, UINT_PTR first, UINT_PTR registering)
{
    struct context *ctx = data;
    const SP_REGISTER_CONTROL_STATUSW *status = (void *)first;
    if (note != SPFILENOTIFY_STARTREGISTRATION && note != SPFILENOTIFY_ENDREGISTRATION) {
        ctx->failed = TRUE;
        return FILEOP_ABORT;
    }
    if (!status || status->cbSize != sizeof(*status) || !status->FileName || !registering) {
        ctx->failed = TRUE;
        return FILEOP_ABORT;
    }
    LONG index = note == SPFILENOTIFY_STARTREGISTRATION ? ctx->starts : ctx->starts - 1;
    if (index < 0 || index >= ctx->count) { ctx->failed = TRUE; return FILEOP_ABORT; }
    struct item *item = &ctx->items[index];
    if (_wcsicmp(item->file, basename(status->FileName)) || _wcsicmp(item->expected_path, status->FileName)) {
        ctx->failed = TRUE; return FILEOP_ABORT;
    }
    if (note == SPFILENOTIFY_STARTREGISTRATION) {
        if (item->started || wcslen(status->FileName) >= 2048) { ctx->failed = TRUE; return FILEOP_ABORT; }
        item->started = TRUE;
        wcscpy(item->path, status->FileName);
        ++ctx->starts;
        printf("CHECKED_REG START index=%ld file=%ls path=%ls\n", index, item->file, item->path);
        fflush(stdout);
        if (item->exe) { item->skipped = TRUE; ++ctx->skips; return FILEOP_SKIP; }
        return FILEOP_DOIT;
    }
    if (!item->started || item->ended || item->skipped || wcscmp(item->path, status->FileName)) {
        ctx->failed = TRUE;
        return FILEOP_ABORT;
    }
    item->ended = TRUE; ++ctx->ends;
    if (status->FailureCode != SPREG_SUCCESS || status->Win32Error != ERROR_SUCCESS) ctx->failed = TRUE;
    printf("CHECKED_REG END index=%ld failure=%lu error=%lu\n", index, status->FailureCode, status->Win32Error);
    fflush(stdout);
    return FILEOP_DOIT; /* SetupAPI ignores END's return; ctx.failed is authoritative. */
}

static BOOL run_exe(struct item *item)
{
    WCHAR command[4200];
    if (swprintf(command, 4200, L"\"%ls\" %ls", item->path, item->args) < 0) return FALSE;
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process;
    if (!CreateProcessW(item->path, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
        printf("CHECKED_REG EXE create_failed error=%lu\n", GetLastError()); return FALSE;
    }
    CloseHandle(process.hThread);
    DWORD waited = WaitForSingleObject(process.hProcess, item->timeout);
    DWORD exit_code = STILL_ACTIVE;
    BOOL exited = waited == WAIT_OBJECT_0 && GetExitCodeProcess(process.hProcess, &exit_code);
    if (waited != WAIT_OBJECT_0) {
        BOOL terminated = TerminateProcess(process.hProcess, 13);
        DWORD drained = WaitForSingleObject(process.hProcess, 5000);
        BOOL stopped = drained == WAIT_OBJECT_0 && GetExitCodeProcess(process.hProcess, &exit_code) && exit_code != STILL_ACTIVE;
        printf("CHECKED_REG EXE cleanup terminated=%d stopped=%d wait=%lu\n", terminated, stopped, drained);
    }
    CloseHandle(process.hProcess);
    printf("CHECKED_REG EXE file=%ls waited=%lu exit=%lu\n", item->file, waited, exit_code);
    fflush(stdout);
    return exited && exit_code == 0;
}

int wmain(int argc, WCHAR **argv)
{
    if (argc != 3) return 2;
    UINT error_line = 0;
    HINF inf = SetupOpenInfFileW(argv[1], NULL, INF_STYLE_WIN4, &error_line);
    if (inf == INVALID_HANDLE_VALUE) { printf("CHECKED_REG open error=%lu line=%u\n", GetLastError(), error_line); return 3; }
    if (!SetupOpenAppendInfFileW(argv[2], inf, &error_line)) { SetupCloseInfFile(inf); return 4; }
    struct context ctx = {0};
    ctx.count = SetupGetLineCountW(inf, L"RegisterDllsSection");
    if (ctx.count <= 0 || ctx.count > 4096) { SetupCloseInfFile(inf); return 5; }
    ctx.items = calloc(ctx.count, sizeof(*ctx.items));
    if (!ctx.items) { SetupCloseInfFile(inf); return 6; }
    LONG expected_exes = 0;
    for (LONG i = 0; i < ctx.count; ++i) {
        INFCONTEXT line;
        struct item *item = &ctx.items[i];
        if (!SetupGetLineByIndexW(inf, L"RegisterDllsSection", i, &line) ||
            !SetupGetStringFieldW(&line, 3, item->file, 512, NULL)) { ctx.failed = TRUE; break; }
        INT dirid = 0, flags = 0;
        WCHAR subdir[512], directory[1536];
        INFCONTEXT destination;
        INT mapped_dirid = 0;
        if (!SetupGetIntField(&line, 1, &dirid) || (dirid != 11 && dirid != 55) ||
            !SetupGetIntField(&line, 4, &flags) || flags != 1 ||
            !SetupGetStringFieldW(&line, 2, subdir, 512, NULL) || subdir[0] ||
            wcschr(item->file, L'\\') || wcschr(item->file, L'/') || wcschr(item->file, L':') ||
            !SetupFindFirstLineW(inf, L"DestinationDirs", dirid == 11 ? L"MacRunnerExpected11" : L"MacRunnerExpected55", &destination) ||
            !SetupGetIntField(&destination, 1, &mapped_dirid) || mapped_dirid != dirid ||
            !SetupGetTargetPathW(inf, NULL, dirid == 11 ? L"MacRunnerExpected11" : L"MacRunnerExpected55",
                                 directory, 1536, NULL)) { ctx.failed = TRUE; break; }
        if (swprintf(item->expected_path, 2048, L"%ls\\%ls", directory, item->file) < 0) { ctx.failed = TRUE; break; }
        const WCHAR *ext = wcsrchr(item->file, L'.');
        item->exe = ext && !_wcsicmp(ext, L".exe");
        if (!ext || (!item->exe && _wcsicmp(ext, L".dll") && _wcsicmp(ext, L".ax") && _wcsicmp(ext, L".drv"))) {
            ctx.failed = TRUE; break;
        }
        if (item->exe) {
            if (i != ctx.count - 1 || expected_exes) { ctx.failed = TRUE; break; }
            ++expected_exes;
            INT seconds = 60;
            if (SetupGetFieldCount(&line) >= 5 && !SetupGetIntField(&line, 5, &seconds)) { ctx.failed = TRUE; break; }
            if (seconds < 0 || seconds > 3600) { ctx.failed = TRUE; break; }
            item->timeout = (DWORD)seconds * 1000;
            if (SetupGetFieldCount(&line) >= 6) {
                if (!SetupGetStringFieldW(&line, 6, item->args, 2048, NULL)) { ctx.failed = TRUE; break; }
            } else wcscpy(item->args, L"/RegServer");
        }
    }
    printf("CHECKED_REG BEGIN bits=%u expected=%ld dll=%ld exe=%ld\n", (unsigned)(sizeof(void *) * 8), ctx.count, ctx.count - expected_exes, expected_exes);
    fflush(stdout);
    BOOL installed = FALSE;
    if (!ctx.failed) installed = SetupInstallFromInfSectionW(NULL, inf, L"MacRunnerCheckedRegistration",
        SPINST_REGSVR | SPINST_REGISTERCALLBACKAWARE, NULL, NULL, 0, observe, &ctx, NULL, NULL);
    if (!installed || ctx.starts != ctx.count || ctx.ends != ctx.count - expected_exes || ctx.skips != expected_exes) ctx.failed = TRUE;
    for (LONG i = 0; i < ctx.count; ++i) {
        struct item *item = &ctx.items[i];
        if (!item->started || (!item->exe && !item->ended)) ctx.failed = TRUE;
        if (!ctx.failed && item->exe) {
            if (run_exe(item)) ++ctx.exes;
            else ctx.failed = TRUE;
        }
    }
    if (ctx.exes != expected_exes) ctx.failed = TRUE;
    printf("CHECKED_REG RESULT success=%d starts=%ld ends=%ld skips=%ld exes=%ld\n", !ctx.failed, ctx.starts, ctx.ends, ctx.skips, ctx.exes);
    fflush(stdout);
    SetupCloseInfFile(inf); free(ctx.items);
    return ctx.failed ? 10 : 0;
}
