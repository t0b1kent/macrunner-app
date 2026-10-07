#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

typedef LONG (NTAPI *query_volume_fn)(HANDLE, void *, void *, ULONG, ULONG);
struct io_status { union { LONG status; void *pointer; } u; ULONG_PTR information; };
struct device_information { ULONG type, characteristics; };

static void emit(const char *text)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, (DWORD)lstrlenA(text), &written, NULL);
}

int main(void)
{
    const char *letters = "RSTUVWXYFGHIJKLMNOPQ";
    char root[] = "R:\\", data[] = "R:\\DIABDAT.MPQ", line[256];
    HANDLE file, directory;
    DWORD got = 0;
    DWORD serial = 0, maximum = 0, flags = 0;
    char label[64] = {0}, filesystem[64] = {0};
    BOOL volume_ok;
    unsigned char header[4] = {0};
    unsigned i;
    query_volume_fn query = (query_volume_fn)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryVolumeInformationFile");
    struct io_status io = {0};
    struct device_information device = {0};
    LONG status;
    for (i = 0; letters[i]; ++i)
    {
        root[0] = data[0] = letters[i];
        if (GetDriveTypeA(root) != DRIVE_CDROM) continue;
        file = CreateFileA(data, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) continue;
        ReadFile(file, header, sizeof(header), &got, NULL);
        CloseHandle(file);
        if (got == sizeof(header) && header[0] == 'M' && header[1] == 'P' && header[2] == 'Q' && header[3] == 0x1a) break;
    }
    if (!letters[i]) { emit("CHECK cdrom-type-and-mpq FAIL\nRESULT FAIL checks=0\n"); return 1; }
    snprintf(line, sizeof(line), "CHECK cdrom-drive-type PASS drive=%c type=%u\n", root[0], GetDriveTypeA(root));
    emit(line);
    emit("CHECK cdrom-mpq-read PASS bytes=4 signature=MPQ1a\n");
    volume_ok = GetVolumeInformationA(root, label, sizeof(label), &serial, &maximum,
                                      &flags, filesystem, sizeof(filesystem));
    snprintf(line, sizeof(line), "CHECK cdrom-volume-information %s label=%s serial=%08lx filesystem=%s flags=%08lx\n",
             volume_ok ? "PASS" : "FAIL", label, (unsigned long)serial, filesystem, (unsigned long)flags);
    emit(line);
    /* Retain the distinct NT host-filesystem observation. The actual Diablo
     * PE call at 0x41af8e compares GetDriveTypeA to 5; it does not import this NT
     * call. Storm's GetVolumeInformationA call asks for neither label nor serial.
     * Curator 13:36 requires a Wine directory drive, not a mounted CD9660 image. */
    directory = CreateFileA(root, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (!query || directory == INVALID_HANDLE_VALUE)
    {
        snprintf(line, sizeof(line), "OBSERVATION nt-device-filesystem state=OPEN_FAILED error=%lu\n", GetLastError());
        emit(line);
        emit(volume_ok ? "RESULT PASS checks=3\n" : "RESULT FAIL checks=3\n");
        return volume_ok ? 0 : 2;
    }
    status = query(directory, &io, &device, sizeof(device), 4); /* FileFsDeviceInformation */
    CloseHandle(directory);
    snprintf(line, sizeof(line), "OBSERVATION nt-device-filesystem status=%08lx device_type=%08lx (separate from GetDriveType)\n",
             (unsigned long)status, (unsigned long)device.type);
    emit(line);
    emit(volume_ok ? "RESULT PASS checks=3\n" : "RESULT FAIL checks=3\n");
    return volume_ok ? 0 : 3;
}
