#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <stdarg.h>

static void emit(const char *format,...) {
    char buffer[3072];va_list args;va_start(args,format);
    int count=vsnprintf(buffer,sizeof(buffer),format,args);va_end(args);
    DWORD written=0;if(count>0) WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),buffer,(DWORD)(count<(int)sizeof(buffer)?count:(int)sizeof(buffer)-1),&written,NULL);
}
#define printf emit

static unsigned failures,checks;
static DWORD owner_thread;
static unsigned cross_seen;
static DWORD inspect_delay=5000;
static const WCHAR dialog_caption[]=L"APP32 MessageBox 32-bit";
static const WCHAR dialog_body[]=L"APP32: 32-bit MessageBox text is visible.\nLatin text 12345. Русский текст: проверка шрифта.";
static void check(const char *name, BOOL condition) {
    checks++;if (!condition) failures++;
    printf("FAMILY_CHECK name=%s result=%s\n",name,condition?"PASS":"FAIL");
}
static LRESULT CALLBACK family_proc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    switch(message) {
    case WM_ASKCBFORMATNAME: lstrcpynW((WCHAR*)lp,L"APP32_CLIP",(int)wp);return 0;
    case WM_GETMINMAXINFO: ((MINMAXINFO*)lp)->ptMaxSize.x=32032;return 0;
    case WM_STYLECHANGING: ((STYLESTRUCT*)lp)->styleNew=0x320032;return 1;
    case WM_STYLECHANGED: return 0x32;
    case WM_SIZING: ((RECT*)lp)->right=32032;return 1;
    case WM_MOVING: ((RECT*)lp)->left=32032;return 1;
    }
    return DefWindowProcW(window,message,wp,lp);
}
static BOOL CALLBACK close_owned(HWND window,LPARAM unused) {
    (void)unused;PostMessageW(window,WM_CLOSE,0,0);return TRUE;
}
static void CALLBACK close_timer(HWND window,UINT msg,UINT_PTR id,DWORD time) {
    (void)window;(void)msg;(void)time;KillTimer(NULL,id);EnumThreadWindows(owner_thread,close_owned,0);
}
static BOOL CALLBACK inspect(HWND window,LPARAM unused) {
    (void)unused;WCHAR text[512]={0};char utf8[2048]={0};
    DWORD_PTR result=0;
    LRESULT delivered=SendMessageTimeoutW(window,WM_GETTEXT,512,(LPARAM)text,SMTO_ABORTIFHUNG,3000,&result);
    int length=(int)result;
    WideCharToMultiByte(CP_UTF8,0,text,-1,utf8,sizeof(utf8),NULL,NULL);
    printf("VISIBLE_TEXT_WM_GETTEXT hwnd=%p thread=%lu owner_thread=%lu delivered=%ld length=%d first=%04x,%04x text=%s\n",(void*)window,(unsigned long)GetCurrentThreadId(),(unsigned long)owner_thread,(long)delivered,length,text[0],text[1],utf8);
    unsigned bit=0;const char *name=NULL;
    WCHAR cls[64]={0};GetClassNameW(window,cls,64);
    if (!wcscmp(cls,L"#32770")) {bit=1;name="MessageBox_caption_cross_thread";}
    else if (GetDlgCtrlID(window)==IDOK) {bit=2;name="MessageBox_OK_cross_thread";}
    else if (GetDlgCtrlID(window)==0xffff) {bit=4;name="MessageBox_body_cross_thread";}
    if (bit) {
        cross_seen|=bit;
        const WCHAR *expected=bit==1?dialog_caption:(bit==4?dialog_body:NULL);
        BOOL valid=expected?(length==lstrlenW(expected) && !wcscmp(text,expected)):(length>0 && text[0]!=0);
        check(name,delivered!=0 && valid && GetCurrentThreadId()!=owner_thread);
    }
    return TRUE;
}
static BOOL CALLBACK inspect_dialog(HWND window,LPARAM unused) {
    (void)unused;WCHAR cls[64]={0};GetClassNameW(window,cls,64);
    if (!wcscmp(cls,L"#32770")) {inspect(window,0);EnumChildWindows(window,inspect,0);}
    return TRUE;
}
static DWORD WINAPI inspect_worker(void *unused) {
    (void)unused;
    printf("INSPECTOR_STARTED thread=%lu delay=%lu\n",(unsigned long)GetCurrentThreadId(),(unsigned long)inspect_delay);
    Sleep(inspect_delay);
    printf("INSPECTOR_ENUM_BEGIN thread=%lu\n",(unsigned long)GetCurrentThreadId());
    EnumThreadWindows(owner_thread,inspect_dialog,0);
    check("MessageBox_cross_thread_all_controls",cross_seen==7);
    return 0;
}
int main(int argc,char **argv) {
    BOOL gate=argc>1 && !strcmp(argv[1],"--gate-message");
    if(gate) inspect_delay=500;
    setvbuf(stdout,NULL,_IONBF,0);owner_thread=GetCurrentThreadId();
    printf("APP32_MESSAGE_FAMILY bits=%u\n",(unsigned)(8*sizeof(void*)));
    WNDCLASSW cls={0};cls.lpfnWndProc=family_proc;cls.hInstance=GetModuleHandleW(NULL);cls.lpszClassName=L"APP32MessageFamily";
    check("RegisterClassW",RegisterClassW(&cls)!=0);
    HWND window=CreateWindowW(cls.lpszClassName,L"initial",0,0,0,100,100,NULL,NULL,cls.hInstance,NULL);
    check("CreateWindowW",window!=NULL);
    WCHAR wide[64]={0};char narrow[64]={0};const WCHAR value[]=L"APP32: Русский 123";
    check("WM_SETTEXT_W",SetWindowTextW(window,value)!=0);
    check("WM_GETTEXT_W",GetWindowTextW(window,wide,64)==lstrlenW(value) && !wcscmp(wide,value));
    check("WM_GETTEXTLENGTH_W",GetWindowTextLengthW(window)==lstrlenW(value));
    wide[0]=0x5a5a;
    check("WM_GETTEXT_zero",SendMessageW(window,WM_GETTEXT,0,(LPARAM)wide)==0 && wide[0]==0x5a5a);
    check("WM_GETTEXT_one",SendMessageW(window,WM_GETTEXT,1,(LPARAM)wide)==0 && wide[0]==0);
    check("WM_SETTEXT_A",SetWindowTextA(window,"APP32 ASCII")!=0);
    check("WM_GETTEXT_A",GetWindowTextA(window,narrow,64)==11 && !strcmp(narrow,"APP32 ASCII"));
    check("WM_GETTEXTLENGTH_A",GetWindowTextLengthA(window)==11);
    const WCHAR direct[]=L"APP32 direct";
    check("SendMessage_SETTEXT",SendMessageW(window,WM_SETTEXT,0,(LPARAM)direct)!=0);
    memset(wide,0,sizeof(wide));
    check("SendMessage_GETTEXT",SendMessageW(window,WM_GETTEXT,64,(LPARAM)wide)==lstrlenW(direct) && !wcscmp(wide,direct));
    check("SendMessage_GETTEXTLENGTH",SendMessageW(window,WM_GETTEXTLENGTH,0,0)==lstrlenW(direct));
    check("DefWindowProc_SETTEXT",DefWindowProcW(window,WM_SETTEXT,0,(LPARAM)value)!=0);
    memset(wide,0,sizeof(wide));
    check("DefWindowProc_GETTEXT",DefWindowProcW(window,WM_GETTEXT,64,(LPARAM)wide)==lstrlenW(value) && !wcscmp(wide,value));
    check("DefWindowProc_GETTEXTLENGTH",DefWindowProcW(window,WM_GETTEXTLENGTH,0,0)==lstrlenW(value));
    wide[0]=0x5a5a;
    check("WM_ASKCBFORMATNAME",SendMessageW(window,WM_ASKCBFORMATNAME,7,(LPARAM)wide)==0 && !wcscmp(wide,L"APP32_"));
    MINMAXINFO minmax={0};
    check("WM_GETMINMAXINFO",SendMessageW(window,WM_GETMINMAXINFO,0,(LPARAM)&minmax)==0 && minmax.ptMaxSize.x==32032);
    STYLESTRUCT style={0};
    check("WM_STYLECHANGING",SendMessageW(window,WM_STYLECHANGING,(WPARAM)GWL_STYLE,(LPARAM)&style)==1 && style.styleNew==0x320032);
    check("WM_STYLECHANGED",SendMessageW(window,WM_STYLECHANGED,(WPARAM)GWL_STYLE,(LPARAM)&style)==0x32);
    RECT rect={0};
    check("WM_SIZING",SendMessageW(window,WM_SIZING,WMSZ_RIGHT,(LPARAM)&rect)==1 && rect.right==32032);
    check("WM_MOVING",SendMessageW(window,WM_MOVING,0,(LPARAM)&rect)==1 && rect.left==32032);
    check("WM_SETTEXT_null",SetWindowTextW(window,NULL)!=0);
    wide[0]=0x5a5a;
    check("WM_GETTEXT_empty",GetWindowTextW(window,wide,64)==0 && wide[0]==0);
    DestroyWindow(window);
    printf("FAMILY_RESULT checks=%u failures=%u result=%s\n",checks,failures,failures?"FAIL":"PASS");
    SetTimer(NULL,0,gate?3000:45000,close_timer);
    HANDLE worker=CreateThread(NULL,0,inspect_worker,NULL,0,NULL);
    DWORD create_error=GetLastError();
    if(!worker) ++failures;
    printf("INSPECTOR_CREATE handle=%p error=%lu\n",(void*)worker,(unsigned long)create_error);
    MessageBoxW(NULL,dialog_body,dialog_caption,MB_OK|MB_ICONERROR);
    DWORD waited=worker?WaitForSingleObject(worker,10000):WAIT_FAILED;
    DWORD exit_code=0;BOOL queried=worker?GetExitCodeThread(worker,&exit_code):FALSE;
    printf("INSPECTOR_WAIT result=%08lx queried=%u exit=%08lx cross_seen=%u\n",(unsigned long)waited,(unsigned)queried,(unsigned long)exit_code,cross_seen);
    if(waited!=WAIT_OBJECT_0 || !queried || exit_code!=0) ++failures;
    if(worker) CloseHandle(worker);
    printf("FAMILY_FINAL_RESULT checks=%u failures=%u result=%s\n",checks,failures,failures?"FAIL":"PASS");
    return failures?1:0;
}
