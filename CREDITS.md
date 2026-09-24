# Credits & acknowledgements

MacRunner brings together work from many people and projects. Their contributions deserve clear recognition.

## People and development tools

- **Jev** — special thanks.
- **Claude by Anthropic** — AI assistance during development.
- **Codex by OpenAI** — AI assistance during development, review, and validation.
- **The maintainers and contributors of the upstream projects below** — the foundations this work depends on.

These acknowledgements do not imply affiliation or endorsement.

## Core foundations

| Project | Contribution |
| --- | --- |
| [Wine](https://www.winehq.org/) | Windows API compatibility |
| [FEX](https://github.com/FEX-Emu/FEX) | x86/x86-64 translation technology used in the runtime work |
| [DXMT](https://github.com/3Shain/dxmt) | Direct3D 10/11 translation to Metal |
| [Sparkle](https://sparkle-project.org/) | The macOS update framework used by the application |
| [PLCrashReporter](https://github.com/microsoft/plcrashreporter) | Crash-reporting support |
| Swift, SwiftUI, and Apple's macOS/Metal technologies | The native interface and platform foundations |

## MacRunner DirectX 12 development

MacRunner's separate **DXMT-based DirectX 12 → Metal** development path includes shader and runtime integration and targeted graphics validation. **Elden Ring gameplay has been confirmed by the maintainer** in the tested configuration. The upstream DXMT foundation is credited above; the DirectX 12 integration is MacRunner development work.

Full in-game ray tracing remains in development, and compatibility is checked per game. [Graphics development status](RELEASE_STATUS.md#directx-12-development) · [Elden Ring results](TESTED_GAMES.md#elden-ring--tested--working).

## Supporting libraries

The bundled runtime's dependency inventory and accompanying notices identify the following supporting projects:

- **Media playback and codecs:** [dav1d](https://code.videolan.org/videolan/dav1d), [FFmpeg](https://ffmpeg.org/), [FLAC](https://xiph.org/flac/), [GStreamer](https://gstreamer.freedesktop.org/), [LAME](https://lame.sourceforge.io/), [libvpx](https://www.webmproject.org/code/), [mpg123](https://www.mpg123.de/), [Ogg/libogg](https://xiph.org/ogg/), [Opus](https://www.opus-codec.org/), [ORC](https://gstreamer.freedesktop.org/modules/orc.html), [SVT-AV1](https://gitlab.com/AOMediaCodec/SVT-AV1), [Theora](https://www.theora.org/), [VMAF/libvmaf](https://github.com/Netflix/vmaf), [Vorbis/libvorbis](https://xiph.org/vorbis/), [x264](https://www.videolan.org/developers/x264.html), and [x265](https://bitbucket.org/multicoreware/x265_git).
- **Graphics and imaging:** [FreeType](https://www.freetype.org/), [libjpeg-turbo](https://libjpeg-turbo.org/), [libpng](https://www.libpng.org/pub/png/libpng.html), and [SDL2](https://www.libsdl.org/).
- **Security and cryptography:** [GMP](https://gmplib.org/), [GnuTLS](https://gnutls.org/), [Nettle/Hogweed](https://www.lysator.liu.se/~nisse/nettle/), [OpenSSL](https://openssl-library.org/), [libtasn1](https://www.gnu.org/software/libtasn1/), and [p11-kit](https://p11-glue.github.io/p11-glue/p11-kit.html).
- **Platform utilities:** [GNU gettext/libintl](https://www.gnu.org/software/gettext/), [GLib/GObject/GModule/GIO](https://docs.gtk.org/glib/), [libidn2](https://www.gnu.org/software/libidn/#libidn2), [libunistring](https://www.gnu.org/software/libunistring/), [libusb](https://libusb.info/), and [PCRE2](https://www.pcre.org/).

Sparkle's notices additionally acknowledge **bsdiff, sais-lite, and the portable Ed25519 implementation by orlp**.

Thank you to their authors, maintainers, testers, and contributors, including the contributors to the dependencies they build on. Project names and trademarks belong to their respective owners.

This page is an acknowledgement, not a replacement for third-party license texts or a claim that distribution review is complete. License notices and any required source availability must be handled for the actual distributed components before a public binary release. Attribution will be updated as the bundled components change.

[Back to MacRunner](README.md) · [Release status](RELEASE_STATUS.md)
