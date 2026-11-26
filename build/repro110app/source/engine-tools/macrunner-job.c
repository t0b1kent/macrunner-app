#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>

enum process_kind { user_process, wine_service, launcher_helper };

static enum process_kind process_kind(const wchar_t *name)
{
    static const wchar_t *wine_services[] = {
        L"conhost.exe", L"explorer.exe", L"plugplay.exe", L"rpcss.exe",
        L"services.exe", L"svchost.exe", L"winedevice.exe",
    };
    static const wchar_t *launcher_helpers[] = { L"UplayService.exe", L"UplayWebCore.exe" };
    for (size_t i = 0; i < sizeof(wine_services) / sizeof(wine_services[0]); ++i)
        if (!_wcsicmp(name, wine_services[i])) return wine_service;
    for (size_t i = 0; i < sizeof(launcher_helpers) / sizeof(launcher_helpers[0]); ++i)
        if (!_wcsicmp(name, launcher_helpers[i])) return launcher_helper;
    return user_process;
}

/* Toolhelp sees the Windows processes in this wineserver. An incomplete
 * snapshot or an unrecognized executable keeps the program alive. */
static BOOL background_only(HANDLE job, unsigned *helpers)
{
    enum { max_job_processes = 512 };
    struct {
        DWORD assigned, listed;
        ULONG_PTR ids[max_job_processes];
    } members;
    if (job && (!QueryInformationJobObject(job, JobObjectBasicProcessIdList, &members, sizeof(members), NULL)
                || members.assigned != members.listed || members.listed > max_job_processes))
        return FALSE;

    HANDLE list = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (list == INVALID_HANDLE_VALUE) return FALSE;
    PROCESSENTRY32W entry = {sizeof(entry)};
    BOOL valid = Process32FirstW(list, &entry);
    unsigned seen = 0;
    *helpers = 0;
    for (BOOL more = valid; more; more = Process32NextW(list, &entry)) {
        if (entry.th32ProcessID == GetCurrentProcessId()) continue;
        if (job) {
            DWORD i = 0;
            while (i < members.listed && members.ids[i] != entry.th32ProcessID) ++i;
            if (i == members.listed) continue;
        }
        ++seen;
        enum process_kind kind = process_kind(entry.szExeFile);
        if (kind == user_process) {
            valid = FALSE;
            break;
        }
        if (kind == launcher_helper) ++*helpers;
    }
    BOOL complete = valid && GetLastError() == ERROR_NO_MORE_FILES && (!job || seen == members.listed);
    CloseHandle(list);
    return complete;
}

/* A program tree is a job, not the lifetime of the persistent Wine session. */
static BOOL append(wchar_t *out, size_t *used, wchar_t c)
{
    if (*used >= 32766) return FALSE;
    out[(*used)++] = c; out[*used] = 0; return TRUE;
}
static BOOL quote(wchar_t *out, size_t *used, const wchar_t *arg)
{
    if (!append(out, used, L'"')) return FALSE;
    while (*arg) {
        size_t slash = 0;
        while (*arg == L'\\') { slash++; arg++; }
        if (!*arg || *arg == L'"') slash *= 2;
        while (slash--) if (!append(out, used, L'\\')) return FALSE;
        if (!*arg) break;
        if (*arg == L'"' && !append(out, used, L'\\')) return FALSE;
        if (!append(out, used, *arg++)) return FALSE;
    }
    return append(out, used, L'"');
}
static BOOL inherit_standard_handle(DWORD kind, HANDLE *child)
{
    HANDLE current = GetStdHandle(kind);
    *child = NULL;
    if (!current || current == INVALID_HANDLE_VALUE) return TRUE;
    return DuplicateHandle(GetCurrentProcess(), current, GetCurrentProcess(),
                           child, 0, TRUE, DUPLICATE_SAME_ACCESS);
}
static int configure_directdraw(const wchar_t *exe, const wchar_t *mode)
{
    const wchar_t value[] = L"native,builtin";
    const wchar_t marker[] = L"MacRunnerManagedDirectDraw";
    wchar_t path[MAX_PATH + 64], current[32] = {0};
    DWORD bytes = sizeof(current), owned = 0, owned_bytes = sizeof(owned);
    BOOL enable = !wcscmp(mode, L"on");
    if ((!enable && wcscmp(mode, L"off")) || !*exe || wcslen(exe) >= MAX_PATH ||
        wcspbrk(exe, L"\\/:\r\n"))
        return 64;
    swprintf(path, sizeof(path) / sizeof(path[0]),
             L"Software\\Wine\\AppDefaults\\%ls\\DllOverrides", exe);

    HKEY key;
    LSTATUS status = enable
        ? RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0,
                         KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &key, NULL)
        : RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &key);
    if (!enable && status == ERROR_FILE_NOT_FOUND) return 0;
    if (status) return 1;

    RegGetValueW(key, NULL, marker, RRF_RT_REG_DWORD, NULL, &owned, &owned_bytes);
    status = RegGetValueW(key, NULL, L"ddraw", RRF_RT_REG_SZ, NULL, current, &bytes);
    int result = 0;
    if (enable) {
        if (status == ERROR_FILE_NOT_FOUND) {
            owned = 1;
            if (RegSetValueExW(key, marker, 0, REG_DWORD, (const BYTE *)&owned, sizeof(owned)) ||
                RegSetValueExW(key, L"ddraw", 0, REG_SZ, (const BYTE *)value, sizeof(value)))
                result = 1;
        } else if (status || _wcsicmp(current, value)) {
            result = 2; /* Preserve a different user override. */
        }
    } else if (owned == 1) {
        if (!status && !_wcsicmp(current, value) && RegDeleteValueW(key, L"ddraw")) result = 1;
        if (!result && RegDeleteValueW(key, marker)) result = 1;
    }
    RegCloseKey(key);
    return result;
}
int wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && !wcscmp(argv[1], L"--ready")) { puts("MACRUNNER_SESSION_READY"); return 0; }
    if (argc == 4 && !wcscmp(argv[1], L"--configure-directdraw")) return configure_directdraw(argv[2], argv[3]);
    if (argc == 2 && !wcscmp(argv[1], L"--probe-background")) {
        unsigned helpers;
        if (!background_only(NULL, &helpers)) return 1;
        printf("MACRUNNER_BACKGROUND_ONLY %u\n", helpers);
        fflush(stdout);
        return 0;
    }
    if (argc < 2) return 64;
    wchar_t command[32768] = {0}; size_t used = 0;
    for (int i = 1; i < argc; i++) {
        if (i > 1 && !append(command, &used, L' ')) return 65;
        if (!quote(command, &used, argv[i])) return 65;
    }
    HANDLE job = CreateJobObjectW(NULL, NULL), port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit = {0};
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT association = {0};
    STARTUPINFOW si = {sizeof(si)}; PROCESS_INFORMATION pi = {0}; DWORD code = 66;
    HANDLE standard[3] = {NULL, NULL, NULL};
    if (!job || !port) goto done;
    limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    association.CompletionKey = job; association.CompletionPort = port;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit, sizeof(limit)) ||
        !SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, &association, sizeof(association))) goto done;
    /* The GUI job launcher has no console. A console child would otherwise
     * allocate its own console and replace the application's redirected streams.
     * Give the child explicit inheritable copies; never change or close ours. */
    if (!inherit_standard_handle(STD_INPUT_HANDLE, &standard[0]) ||
        !inherit_standard_handle(STD_OUTPUT_HANDLE, &standard[1]) ||
        !inherit_standard_handle(STD_ERROR_HANDLE, &standard[2])) { code = 73; goto done; }
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = standard[0]; si.hStdOutput = standard[1]; si.hStdError = standard[2];
    if (!CreateProcessW(argv[1], command, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) { code = 67; goto done; }
    if (!AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 68); code = 68; goto done; }
    if (ResumeThread(pi.hThread) == (DWORD)-1) { code = 69; goto done; }
    CloseHandle(pi.hThread); pi.hThread = NULL;
    /* The root process must exit before a helper can be treated as a tail. */
    if (WaitForSingleObject(pi.hProcess, INFINITE) != WAIT_OBJECT_0) { code = 70; goto done; }
    ULONGLONG idle_since = 0;
    ULONGLONG next_sample = GetTickCount64() + 2000;
    for (;;) {
        ULONGLONG now = GetTickCount64();
        if (now >= next_sample) {
            unsigned helpers;
            if (background_only(job, &helpers)) {
                if (!idle_since) idle_since = now;
                else if (now - idle_since >= 5000 && TerminateJobObject(job, 0)) {
                    puts("MACRUNNER_BACKGROUND_JOB_CLOSED");
                    idle_since = 0;
                }
            } else idle_since = 0;
            next_sample = now + 2000;
        }
        DWORD message = 0; ULONG_PTR key = 0; LPOVERLAPPED overlapped = NULL;
        if (!GetQueuedCompletionStatus(port, &message, &key, &overlapped, (DWORD)(next_sample - now))) {
            if (GetLastError() != WAIT_TIMEOUT) { code = 70; goto done; }
            continue;
        }
        if (key == (ULONG_PTR)job && message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = {0};
            if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &info, sizeof(info), NULL)) { code = 71; goto done; }
            if (info.ActiveProcesses == 0) break;
        }
    }
    if (!GetExitCodeProcess(pi.hProcess, &code)) code = 72;
    puts("MACRUNNER_PROGRAM_TREE_EMPTY"); fflush(stdout);
done:
    for (int i = 0; i < 3; i++) if (standard[i]) CloseHandle(standard[i]);
    if (pi.hThread) CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (job) CloseHandle(job);
    if (port) CloseHandle(port);
    return (int)code;
}
