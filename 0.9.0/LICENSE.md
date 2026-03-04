MIT License

Copyright (c) 2026 Paul Swonger (smokeluce)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Third-Party Components

### CHDMAN

This repository includes a redistributed binary of `chdman.exe`, a utility
developed by the MAME team as part of the MAME project.

- **Source:** https://www.mamedev.org/
- **License:** GNU General Public License, version 2 (GPL-2.0)
- **License text:** https://github.com/mamedev/mame/blob/master/COPYING

UltraCHD does not modify, link to, or incorporate any MAME or CHDMAN source
code. `chdman.exe` is included as a standalone executable dependency and
invoked as a separate process at runtime. It remains the exclusive work of the
MAME team and is subject to the terms of the GPL-2.0 license independently of
this project.

Users who redistribute UltraCHD in any form should be aware that `chdman.exe`
carries its own license obligations under GPL-2.0.
