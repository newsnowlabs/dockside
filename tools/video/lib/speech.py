#!/usr/bin/env python3
"""Measures how long each caption's speech takes in a voice, so a recording can leave exactly that.

    node dry-run.js videos/NAME.js | speech.py <outdir> <voice>

Renders each distinct spoken text (into <outdir>/voice-cache, which the build reuses) and
writes <outdir>/speech.json, the text's seconds including the small allowance the build
adds. The recording gives each caption that long, so no caption's slot is guessed from its
word count.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build  # noqa: E402


def main():
    out, engine = sys.argv[1:3]
    texts = sorted({c['speak'] for c in json.load(sys.stdin)['captions']})
    lengths = {text: build.seconds(build.synthesise(engine, text, f'{out}/voice-cache')) + 0.1 for text in texts}
    with open(f'{out}/speech.json', 'w') as f:
        json.dump(lengths, f, indent=2)
    print(f'{len(texts)} spoken texts measured in {engine}', file=sys.stderr)


if __name__ == '__main__':
    main()
