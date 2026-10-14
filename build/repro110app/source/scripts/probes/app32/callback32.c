#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

static unsigned callbacks;
static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_WINDOWPOSCHANGING) { ++callbacks; return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

typedef BOOL (WINAPI *set_position_fn)(HWND, HWND, INT, INT, INT, INT, UINT);
static set_position_fn set_position;

/* Call the leaf win32u syscall directly: a user32 same-thread SendMessage
 * optimization could bypass the native callback dispatcher under test. */
static BOOL callback_with_ebp(HWND window, ULONG nonpointer)
{
    ULONG_PTR result = (ULONG_PTR)set_position;
    __asm__ volatile (
        "push %%ebp\n\t"
        "mov %%edx, %%ebp\n\t"
        "and $31, %%edx\n\t"
        "push $0x14\n\tpush $64\n\tpush $64\n\tpush $0\n\t"
        "push %%edx\n\tpush $0\n\tpush %%ecx\n\t"
        "call *%%eax\n\t"
        "pop %%ebp\n\t"
        : "+a" (result), "+c" (window), "+d" (nonpointer)
        :
        : "memory", "cc");
    return (BOOL)result;
}

static void emit(const char *text)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, (DWORD)lstrlenA(text), &written, NULL);
}

int main(void)
{
    WNDCLASSW wc = {0};
    HWND window;
    const ULONG values[] = {0x1006e, 0, 0xfffffffc};
    unsigned i;
    char line[192];
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpfnWndProc = procedure;
    wc.lpszClassName = L"APP32CallbackNonpointer";
    set_position = (set_position_fn)GetProcAddress(LoadLibraryW(L"win32u.dll"), "NtUserSetWindowPos");
    if (!set_position) return 5;
    if (!RegisterClassW(&wc)) return 2;
    window = CreateWindowW(wc.lpszClassName, L"APP32 callback gate", 0, 0, 0, 64, 64,
                           NULL, NULL, wc.hInstance, NULL);
    if (!window) return 3;
    for (i = 0; i < sizeof(values) / sizeof(values[0]); ++i)
    {
        BOOL result;
        unsigned before = callbacks;
        snprintf(line, sizeof(line), "BEGIN callback-ebp value=%08lx\n", (unsigned long)values[i]);
        emit(line);
        result = callback_with_ebp(window, values[i]);
        snprintf(line, sizeof(line), "CHECK callback-ebp-%08lx %s result=%08lx callbacks=%u\n",
                 (unsigned long)values[i], result && callbacks > before ? "PASS" : "FAIL",
                 (unsigned long)result, callbacks);
        emit(line);
        if (!result || callbacks <= before) return 4;
    }
    DestroyWindow(window);
    emit("RESULT PASS checks=3\n");
    return 0;
}
