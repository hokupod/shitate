# Third-Party Notices

Shi-tate is licensed under `AGPL-3.0-only`. This file records notices for
external components used to build or run the project.

## JUCE 9.0.0

JUCE is included as a git submodule pinned to commit
`f8f8864172464b9adf9eba6101e1f784838d1597`. The unmodified top-level license
from that checkout is included at [LICENSES/JUCE-LICENSE.md](LICENSES/JUCE-LICENSE.md).
The project uses JUCE under its AGPLv3 option. See the pinned source for the
complete dependency inventory.

## VST3 SDK

The following unmodified notice is copied from
`external/JUCE/modules/juce_audio_processors_headless/format_types/VST3_SDK/LICENSE.txt`
at the pinned JUCE commit:

```text
//-----------------------------------------------------------------------------
MIT License

Copyright (c) 2025, Steinberg Media Technologies GmbH

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

//---------------------------------------------------------------------------------
```

## BlackHole 2ch

BlackHole is a separate project. Shi-tate does not include or redistribute it;
users install it separately from its official distribution. Shi-tate interacts
with BlackHole only as a CoreAudio device.

## Third-party VST3 plug-ins

Shi-tate does not include or redistribute third-party VST3 plug-ins. Users are
responsible for obtaining them from their developers and complying with every
plug-in's licence terms.
