# Third-party notices

This project's MIT license covers the project source and original assets to the
extent the contributors hold those rights. It does not replace the licenses of
the Python runtime, its libraries, or separately installed Canon software.

## Project origin

The R6 Mark III workflow builds on
[EdwinjJ1/canon-lut-lab](https://github.com/EdwinjJ1/canon-lut-lab), reviewed at
commit `ed07e82ceb696ba272d33562515095daf2c184fb`.

Its MIT license and the notice `Copyright (c) 2026 EdwinjJ1 and contributors`
are retained in [LICENSE](LICENSE). The added application and R6 III work are
credited to Jie-su and contributors. Changes include the R6 III full33
workflow, desktop interface, offline previews, connection monitoring, packaging,
and original application icon.

## Research reference

[LvClFER/Lut-to-Canon-Picture-Style](https://github.com/LvClFER/Lut-to-Canon-Picture-Style),
reviewed at commit `3318ba3e3549463bc0fd889234f6eace7ea08f64`, was a research
reference for full33 layout, quantization, and the distinction between normal
parameter compilation and dense-table output replacement.

No top-level license was found in that reviewed revision. This acknowledgment
does not relicense that repository or grant permission to redistribute it.
Its source files, media, sample presets, and application are not vendored in
this release. Do not infer that material from that project is covered by our
MIT license.

## Bundled Python runtime

The macOS release includes a minimized Python.org CPython **3.13.3** runtime.
Python uses the PSF License Version 2 together with its retained historical
license terms. Python's incorporated software also has separate notices.

Full upstream texts are included in:

- [Python-3.13.3-LICENSE.txt](licenses/Python-3.13.3-LICENSE.txt)
- [Python-3.13.3-History-and-License.rst](licenses/Python-3.13.3-History-and-License.rst)

The latter is the unmodified license document shipped with the Python.org
installation. It includes incorporated-software notices such as Expat,
libmpdec, zlib, and OpenSSL, plus notices for components that may be absent from
this minimized runtime. It is not a statement that every listed component is
bundled.

### Runtime changes made for this distribution

The Python interpreter, extension modules, and copied shared libraries were
reduced from universal2 to arm64 where applicable. Mach-O dependency paths and
install names were changed to load the app's private runtime relative to the
executable. The packaged standard library excludes third-party site-packages,
tests, Tkinter, IDLE, and other unused build or example material. Executables
were locally signed for the application bundle. The application sets a private
Python home and module path. The Python language implementation's source was
not edited.

These binary packaging changes also apply to copied OpenSSL and ncurses shared
libraries where applicable. They do not change the libraries' own licenses.

## Runtime libraries

| Component | Included form / purpose | License and notices |
| --- | --- | --- |
| OpenSSL 3.0.16 | Private `libssl.3.dylib` and `libcrypto.3.dylib`, used by Python extension modules | Apache License 2.0; [full license](licenses/OpenSSL-3.0.16-LICENSE.txt) |
| ncurses 6.5, release 20240427 | Private ncurses, panel, form, and menu shared libraries from the Python.org distribution | ncurses permissive license; [unaltered COPYING](licenses/ncurses-6.5-COPYING.txt) |
| SQLite 3.49.1 | Included in Python's `_sqlite3` extension | Public domain; [SQLite's copyright statement](https://www.sqlite.org/copyright.html) |
| liblzma from XZ Utils 5.2.3 | Included in Python's `_lzma` extension | liblzma is public domain in that version; [upstream licensing summary](licenses/XZ-5.2.3-COPYING.txt). The GPL terms for XZ command-line tools and scripts are not the license of the liblzma code included here. |
| libmpdec 4.0.0 | Included in Python's `_decimal` extension | BSD-style notice reproduced in the complete Python license document |
| Expat and other software incorporated into CPython | Python extension modules and standard library | Notices reproduced in the complete Python license document |

System libraries such as Apple's libffi, libbz2, libz, libedit, and macOS
frameworks are loaded from the operating system rather than copied into this
release. Their inclusion in a dependency list does not mean that this project
redistributes them.

Versions above describe the Python.org 3.13.3 runtime used for this release.
Developers who substitute another runtime must update the notices to match
what they actually distribute. Source URLs and SHA-256 values for copied
license texts are recorded in [licenses/SOURCES.json](licenses/SOURCES.json).

## Canon software and user data are external

Canon EOS Utility, Picture Style Editor, EDSDK, EdsCFParse, DppCore, MLib, and
their proprietary code are **not distributed** in the repository or release.
The application locates the user's own local Canon installation. The project
license grants no rights to Canon software or its trademarks; users obtain
those products separately under Canon's terms.

Private camera snapshots, descriptors captured from the development camera,
personal photographs, third-party CUBE files, and local test payloads are not
part of the public release. User-supplied LUTs, PF3 files, and photographs
remain subject to their own rights and terms.

Canon and other product names identify compatibility and research context.
This project is independent and is not endorsed by Canon or other camera
manufacturers.

