# Narration voices

Narration is optional. With no voice the videos are silent and carry burned-in captions
only. With one, the build turns each caption into speech and mixes it into the MP4.

A voice is a directory here, `voices/<name>/`, holding an executable called `speak`:

    voices/<name>/speak <text-file> <output.wav>

`speak` reads one caption's text from `<text-file>` (UTF-8) and writes the spoken audio to
`<output.wav>`, at any sample rate, mono or stereo. It exits non-zero on failure. Anything
else the voice needs, such as a model or a virtualenv, lives in its directory and is found
by `speak` relative to itself.

Voice directories are **not committed**: models are large and carry their own licences, so
`voices/.gitignore` ignores everything except this file. Drop one in and select it:

    tools/video/record.sh --voice <name> welcome-short

or set `voice.engine` in `config.json`, or in a video's `options`. Only the build uses the voice, so a finished
recording can be re-voiced, or a new voice auditioned, without recording again:

    tools/video/record.sh --build-only --voice <name> welcome-short

`speak` runs once per distinct text: the build keeps each clip in the recording's
`voice-cache/`, named for the voice, the text and the voice's `settings.json` if it has
one. Changing a voice's settings therefore re-renders it, and an unchanged caption does
not. A video needs no change to be narrated, and can word its speech for the ear rather
than the eye with `say(caption, { speak: '…' })`.

## Example: a voice that wraps a command-line synthesiser

    #!/usr/bin/env bash
    # voices/example/speak
    set -euo pipefail
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    exec "$here/venv/bin/python" "$here/speak.py" "$1" "$2"

where `speak.py` loads a model and writes a wav. Kokoro (Apache-2.0 weights, runs on a
CPU) is a good fit: its `kokoro-onnx` package needs only `onnxruntime`, the model file and
the voices file, and it can blend voices, which gives a more expressive and distinctive
narrator than any one of them.
