#!/usr/bin/env python3
"""Prints a video's captions and narration for reading through, from dry-run.js's JSON on stdin.

    node dry-run.js videos/NAME.js | script.py

For each say(): the caption as the viewer reads it, row by row as the build will show it;
the words the voice speaks when they differ; and an estimate of the speaking time.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build  # noqa: E402


def main():
    config = build.load(f'{build.ROOT}/config.json')
    speech = config['speech']
    video = json.load(sys.stdin)
    cap, _, _ = build.options(config, video, chrome='none')
    captions = video['captions']
    total = 0.0
    for i, c in enumerate(captions, 1):
        words = len(c['speak'].split())
        seconds = max(speech['minSeconds'], words / speech['wordsPerSecond'])
        total += seconds + speech['gapSeconds']
        mode = c['captions'] or cap['mode']
        rows = [c['text']] if mode == 'block' else (c['phrases'] or build.split_phrases(c['text'], cap['maxChars'], cap['minChars'], cap['keep']))
        print(f'{i:2}. ~{seconds:.0f}s  captions: {mode}')
        for row in ([] if mode == 'none' else rows):
            print(f'      | {row}')
        if c['speak'] != c['text']:
            print(f'      spoken: {c["speak"]}')
        print()
    print(f'{len(captions)} captions, about {total / 60:.1f} minutes of speech at the reading pace')


if __name__ == '__main__':
    main()
