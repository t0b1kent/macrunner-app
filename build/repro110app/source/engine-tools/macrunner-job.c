#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

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
int wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && !wcscmp(argv[1], L"--ready")) { puts("MACRUNNER_SESSION_READY"); return 0; }
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
    for (;;) {
        DWORD message = 0; ULONG_PTR key = 0; LPOVERLAPPED overlapped = NULL;
        if (!GetQueuedCompletionStatus(port, &message, &key, &overlapped, INFINITE)) { code = 70; goto done; }
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
