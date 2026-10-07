#define COBJMACROS
#include <windows.h>
#include <ddraw.h>
#include <stdio.h>
#include <stdarg.h>

static void emit(const char *format,...) {
    char buffer[512];va_list args;va_start(args,format);
    int count=vsnprintf(buffer,sizeof(buffer),format,args);va_end(args);
    DWORD written=0;if(count>0) WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),buffer,(DWORD)(count<(int)sizeof(buffer)?count:(int)sizeof(buffer)-1),&written,NULL);
}
#define printf emit

/* Same DirectDraw boundary as Heroes WINGRAPH.CPP:164. Hidden owned window,
 * no foreground activation, physical mode change or synthetic input. */
static int failures;
static void check(const char *name,HRESULT result) {
    printf("DDRAW_CHECK name=%s result=%s hr=%08lx\n",name,result==DD_OK?"PASS":"FAIL",(unsigned long)result);
    if(result!=DD_OK) failures++;
}
static LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    return DefWindowProcW(window,message,wp,lp);
}
int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);DWORD began=GetTickCount();
    WNDCLASSW cls={0};cls.lpfnWndProc=procedure;cls.hInstance=GetModuleHandleW(NULL);cls.lpszClassName=L"APP32DDrawGate";
    RegisterClassW(&cls);
    HWND window=CreateWindowW(cls.lpszClassName,L"APP32 DirectDraw gate",WS_POPUP,0,0,800,600,NULL,NULL,cls.hInstance,NULL);
    IDirectDraw *draw=NULL;IDirectDrawSurface *surface=NULL;HRESULT hr=DirectDrawCreate(NULL,&draw,NULL);
    check("DirectDrawCreate",hr);if(hr!=DD_OK) goto done;
    hr=IDirectDraw_SetCooperativeLevel(draw,window,DDSCL_EXCLUSIVE|DDSCL_FULLSCREEN);
    check("SetCooperativeLevel",hr);if(hr!=DD_OK) goto done;
    hr=IDirectDraw_SetDisplayMode(draw,800,600,16);
    check("SetDisplayMode800x600x16",hr);if(hr!=DD_OK) goto done;
    DDSURFACEDESC desc={0};desc.dwSize=sizeof(desc);desc.dwFlags=DDSD_CAPS;desc.ddsCaps.dwCaps=DDSCAPS_PRIMARYSURFACE;
    hr=IDirectDraw_CreateSurface(draw,&desc,&surface,NULL);
    check("CreatePrimarySurface",hr);if(hr!=DD_OK) goto done;
    DDBLTFX effect={0};effect.dwSize=sizeof(effect);effect.dwFillColor=0x07e0;
    hr=IDirectDrawSurface_Blt(surface,NULL,NULL,NULL,DDBLT_COLORFILL|DDBLT_WAIT,&effect);
    check("BltColorFill",hr);
done:
    if(surface) IDirectDrawSurface_Release(surface);
    if(draw) {IDirectDraw_RestoreDisplayMode(draw);IDirectDraw_SetCooperativeLevel(draw,window,DDSCL_NORMAL);IDirectDraw_Release(draw);}
    if(window) DestroyWindow(window);
    printf("DDRAW_RESULT failures=%d elapsed_ms=%lu result=%s\n",failures,(unsigned long)(GetTickCount()-began),failures?"FAIL":"PASS");
    return failures?1:0;
}
