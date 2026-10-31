#!/usr/bin/env python3
"""Turns a recording into the finished videos.

    build.py <outdir> <name> [--formats mp4,gif,webp] [--voice NAME]

<outdir> holds what record.sh left there: raw.mkv (the capture), t0 (the moment it
began), timeline.json (the video's captions and cut points) and meta.json (where the
page sits in the capture). The result is <name>.mp4 / .gif / .webp, with the captions
burned in, plus captions.srt and captions.vtt. Narration, when a voice is selected, is
mixed into the MP4 only.

Everything about timing is decided here, on the cut video, so a rebuild with another
voice, speed or wording needs no new take:

  1. The cuts are applied to the capture's timeline.
  2. Each caption's speech (a voice's clip, or else the video's reading-time estimate)
     is placed at the point the caption starts.
  3. The timing is checked. If any speech would run into the next caption, or past the
     end of the video, the build says so for every caption at once, with how far over each
     is and what to change, and stops before encoding. It never bends the picture to hide
     a problem: shorten the text, give the video more time after that say(), or move the
     cut. A clip may carry on across a cut: the cut is a jump in the picture, not in the
     voice, and the build lists where that happens.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(ROOT))
EPS = 1e-3


def load(path):
    with open(path) as f:
        return json.load(f)


def ffmpeg(outdir, *args):
    cmd = ['ffmpeg', '-v', 'error', '-y', *args]
    if subprocess.run(cmd, cwd=outdir).returncode != 0:
        sys.exit('ffmpeg failed: ' + ' '.join(cmd))


def seconds(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                       capture_output=True, text=True, check=True)
    return float(r.stdout)


# ── Speech ───────────────────────────────────────────────────────────────────

def synthesise(engine, text, cache):
    """The wav of `text` in the voice voices/<engine>/, rendered once per distinct text and settings."""
    voice = os.path.join(ROOT, 'voices', engine)
    command = os.path.join(voice, 'speak')
    if not os.access(command, os.X_OK):
        sys.exit(f"no voice '{engine}': {command} is missing or not executable (see voices/README.md)")
    settings = b''
    if os.path.exists(os.path.join(voice, 'settings.json')):
        with open(os.path.join(voice, 'settings.json'), 'rb') as f:
            settings = f.read()
    key = hashlib.sha1(command.encode() + b'\n' + settings + b'\n' + text.encode()).hexdigest()[:16]
    os.makedirs(cache, exist_ok=True)
    wav = os.path.join(cache, key + '.wav')
    if not os.path.exists(wav):
        txt = os.path.join(cache, key + '.txt')
        with open(txt, 'w') as f:
            f.write(text)
        if subprocess.run([command, txt, wav]).returncode != 0 or not os.path.exists(wav):
            sys.exit(f"the voice '{engine}' failed on: {text}")
    return wav


# ── The edit: the cuts ─────────────────────────────────────────────────

def merge(intervals):
    out = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


class Edit:
    """What is kept of the capture, in raw time (seconds since the capture began)."""

    def __init__(self, trim, end, cuts):
        self.trim, self.end = trim, end
        self.cuts = [c for c in merge(cuts) if c[1] - c[0] > EPS]

    def at(self, t):
        """Where raw time t falls in the finished video."""
        return t - self.trim - sum(min(b, t) - a for a, b in self.cuts if t > a)

    def kept(self):
        """The stretches of the capture that are kept, as (from, to) raw times, in order."""
        out, t = [], self.trim
        for a, b in self.cuts:
            if a > t + EPS:
                out.append((t, a))
            t = max(t, b)
        if self.end > t + EPS:
            out.append((t, self.end))
        return out


def check_timing(edit, captions, starts, lengths, gap):
    """Finds every place the speech does not fit; returns (problems, notes), as lists of text.

    Each clip needs its own length plus `gap` before the next caption's speech starts, and the
    last needs its length before the video ends. A caption's `lead` is how much sooner its own
    speech starts than the picture reaches it. A clip that carries across a cut is only noted.
    """
    problems, notes = [], []
    at = [edit.at(t) for t in starts]
    leads = [c.get('lead', 0) for c in captions]
    ends = [t - lead for t, lead in zip(at[1:], leads[1:])] + [edit.at(edit.end)]
    for i, caption in enumerate(captions):
        last = i == len(captions) - 1
        room = ends[i] - at[i] + leads[i]
        need = lengths[i] + (0 if last else gap)
        label = f'caption {i + 1} ("{caption["text"][:40]}")'
        if room < need - EPS:
            over = need - room
            where = 'before the video ends' if last else f'before caption {i + 2} starts'
            pause = '' if last else f', plus a {gap:.2f} s pause,'
            problems.append(f'{label}: the speech takes {lengths[i]:.1f} s{pause} but there are {room:.1f} s {where}, '
                            f'{over:.1f} s short. Shorten the text, or give the video {over:.1f} s more '
                            f'after this say(){"" if last else ", or end the cut before it sooner"}.')
        for x, _ in edit.cuts:
            seam = edit.at(x)
            if at[i] + 0.05 < seam < at[i] + lengths[i] - 0.05:
                notes.append(f'{label}: the narration carries across a cut at {seam:.1f} s')
    return problems, notes


# What of the browser window the video shows, above the page: nothing, its tab strip, or
# the tab strip and the toolbar with its address bar.
CHROME = ('none', 'tabs', 'full')
# Where a caption goes: in a band added under the page, or over the page at its bottom or top.
POSITIONS = ('band', 'bottom', 'top')

# ── Captions ─────────────────────────────────────────────────────────────────

def split_phrases(text, max_chars, min_chars, keep=()):
    """Breaks a caption into phrases that each fit one row.

    It breaks after punctuation, joins a short phrase to its neighbour, and splits one
    that is still too long at word boundaries into rows, each filled as far as it will go. A row is
    never broken inside a phrase listed in `keep`, unless nothing else is possible.
    """
    pieces = re.findall(r'[^,;:.!?…—]+[,;:.!?…—]*\s*', text) or [text]
    phrases = []
    for piece in pieces:
        piece = piece.strip()
        if not piece:
            continue
        if phrases and (len(phrases[-1]) < min_chars or len(piece) < min_chars) \
                and len(phrases[-1]) + 1 + len(piece) <= max_chars:
            phrases[-1] += ' ' + piece
        else:
            phrases.append(piece)
    return [row for phrase in phrases for row in split_row(phrase, max_chars, keep, min_chars)]


# Words a row break reads best before.
BREAK_BEFORE = {'with', 'and', 'or', 'but', 'for', 'to', 'in', 'of', 'on', 'by', 'from', 'that', 'which', 'so', 'then',
                'into', 'over', 'without', 'across', 'behind'}


# Words a row does not end on: they belong with what follows.
NO_END = BREAK_BEFORE | {'the', 'a', 'an', 'its', 'your', 'their', 'our', 'my', 'his', 'her', 'this', 'these', 'those', 'each', 'every'}

# How many characters shorter a row may be, to let the next one begin with a connecting word.
CONNECTOR_BONUS = 10


def words_of(text):
    return [re.sub(r"^\W+|\W+$", '', w).lower() for w in text.split()]


def kept_inside(words, keep):
    """The word boundaries k (between words[k - 1] and words[k]) that fall inside a phrase in `keep`."""
    inside = set()
    plain = words_of(' '.join(words))
    for phrase in keep:
        target = words_of(phrase)
        for i in range(len(plain) - len(target) + 1):
            if plain[i:i + len(target)] == target:
                inside.update(range(i + 1, i + len(target)))
    return inside


def split_row(text, max_chars, keep=(), min_chars=0):
    """Splits text that is too long for one row, filling the first row as far as it will go.

    The first row ends at the word boundary that leaves it as long as `max_chars`
    allows, or up to CONNECTOR_BONUS characters shorter if that lets the next row begin
    with a connecting word. Neither row is left shorter than `min_chars`, and the break
    is never inside a phrase in `keep` or just after a word in NO_END. Where no boundary meets those, the second and
    then the first condition is given up. The rest of the text is split in the same way.
    """
    if len(text) <= max_chars:
        return [text]
    words = text.split()
    inside = kept_inside(words, keep) | {k for k in range(1, len(words)) if words[k - 1].lower() in NO_END}
    left = lambda k: len(' '.join(words[:k]))
    right = lambda k: len(' '.join(words[k:]))
    ks = range(1, len(words))
    for rules in (lambda k: k not in inside and min_chars <= left(k) <= max_chars and right(k) >= min_chars,
                  lambda k: k not in inside and left(k) <= max_chars,
                  lambda k: k not in inside,
                  lambda k: True):
        candidates = [k for k in ks if rules(k)]
        if candidates:
            break
    # A first row that fits scores by how much room it leaves; one that does not, by how far it overshoots.
    k = min(candidates, key=lambda k: (-left(k) - (CONNECTOR_BONUS if words[k].lower() in BREAK_BEFORE else 0))
            if left(k) <= max_chars else left(k))
    return [' '.join(words[:k])] + split_row(' '.join(words[k:]), max_chars, keep, min_chars)


def options(config, timeline, chrome=None, position=None):
    """The caption settings, browser chrome and title cards to build with.

    Settings come from config.json, then the video's own `captions`, `chrome` and `cards`
    (which reach here in the timeline), then the command line. The video's `captions.keep`
    adds to config.json's. Of the cards, a video may replace `start` or `end`, or set one
    to null for none.
    """
    requested = chrome
    video = timeline.get('options', {})
    cfg = dict(config['captions'], **video.get('captions', {}))
    cfg['keep'] = list(config['captions'].get('keep', [])) + list(video.get('captions', {}).get('keep', []))
    if position:
        cfg['position'] = position
    chrome = chrome or video.get('chrome') or config['chrome']
    if chrome not in CHROME or cfg['position'] not in POSITIONS:
        sys.exit(f"chrome is one of {', '.join(CHROME)}, and the caption position one of {', '.join(POSITIONS)}")
    # The address bar shows the server's host name, so only a name that is meant to be seen may
    # appear in it unless the command line asks for the bar outright.
    host = timeline.get('host', '')
    if chrome == 'full' and not requested and not any(host == d or host.endswith('.' + d) for d in config.get('publicDomains', [])):
        sys.exit(f"the address bar would show {host or 'the server'}, which config.json's publicDomains does not list as "
                 "public: record a server under one of those domains, or pass --chrome full to show it anyway")
    cards = dict(config.get('cards', {}), **video.get('cards', {}))
    if video.get('colorScheme', config.get('colorScheme')) == 'dark':
        cards.update(cards.get('dark', {}))
    return cfg, chrome, cards


def make_card(outdir, name, card, cards, size):
    """Renders a title card, the logo centred on the background, at `size` pixels, as <name>.png."""
    path = f'{outdir}/{name}.png'
    subprocess.run(['node', f'{HERE}/card.js', path, str(size[0]), str(size[1]), os.path.join(REPO, cards['logo']),
                    cards['background'], cards['ink'], card.get('text', '')], check=True)
    return path


def phrase_cues(caption, start, speech, end, cfg):
    """The caption as (from, to, text, style) cues, with phrases timed in proportion to the speech.

    A pause after punctuation counts for a little extra, as it does in speech. The last
    phrase stays up until `end`, when the next caption starts.
    """
    mode = caption.get('captions') or cfg['mode']
    if mode == 'none':
        return []
    if mode == 'block':
        return [(start, end, caption['text'], 'Block')]
    phrases = caption.get('phrases') or split_phrases(caption['text'], cfg['maxChars'], cfg['minChars'], cfg.get('keep', ()))
    weights = [len(p) + (6 if p[-1] in ',;:—' else 10 if p[-1] in '.!?…' else 0) for p in phrases]
    cues, t = [], start
    for phrase, weight in zip(phrases, weights):
        nxt = t + speech * weight / sum(weights)
        cues.append((t, nxt, phrase, 'Phrase'))
        t = nxt
    cues[-1] = (cues[-1][0], max(end, cues[-1][1]), cues[-1][2], 'Phrase')
    return cues


def stamp(t, sep):
    t = max(0.0, t)
    return '%02d:%02d:%02d%s%03d' % (t // 3600, t % 3600 // 60, t % 60, sep, round(t % 1 * 1000) % 1000)


def ass_time(t):
    t = max(0.0, t)
    return '%d:%02d:%05.2f' % (t // 3600, t % 3600 // 60, t % 60)


def ass_colour(rgb, opacity=1.0):
    r, g, b = rgb[0:2], rgb[2:4], rgb[4:6]
    return '&H%02X%s%s%s' % (round((1 - opacity) * 255), b, g, r)


def write_captions(outdir, cues, cfg, size, page_height):
    """Writes captions.srt, .vtt and .ass from (from, to, text, style) cues.

    `size` is the video's, and `page_height` the part of it above the caption band, which
    the captions are centred in when there is one. Caption sizes are fractions of the page.
    """
    width, height = size
    with open(f'{outdir}/captions.srt', 'w') as f:
        for i, (s, e, text, _) in enumerate(cues, 1):
            f.write(f'{i}\n{stamp(s, ",")} --> {stamp(e, ",")}\n{text}\n\n')
    with open(f'{outdir}/captions.vtt', 'w') as f:
        f.write('WEBVTT\n\n')
        for s, e, text, _ in cues:
            f.write(f'{stamp(s, ".")} --> {stamp(e, ".")}\n{text}\n\n')
    box = ass_colour(cfg['boxColour'], cfg['boxOpacity'])
    styles = ''
    for name, key in (('Block', 'blockSize'), ('Phrase', 'phraseSize')):
        fs = round(page_height * cfg[key])
        styles += (f"Style: {name},{cfg['font']},{fs},{ass_colour(cfg['textColour'])},&H000000FF,{box},{box},"
                   f"0,0,0,0,100,100,0,0,3,{round(fs * 0.35)},0,{8 if cfg['position'] == 'top' else 2},{round(width * 0.08)},{round(width * 0.08)},"
                   f"{round(page_height * 0.05)},1\n")
    with open(f'{outdir}/captions.ass', 'w') as f:
        f.write(f'''[Script Info]
ScriptType: v4.00+
PlayResX: {width}
PlayResY: {height}
WrapStyle: 0

[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
{styles}
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
''')
        # In the band, a caption is centred on it; over the page, the style places it.
        place = f'{{\\an5\\pos({width // 2},{(page_height + height) // 2})}}' if height > page_height else ''
        for s, e, text, style in cues:
            f.write(f'Dialogue: 0,{ass_time(s)},{ass_time(e)},{style},,0,0,0,,{place}{text}\n')


# ── Rendering ────────────────────────────────────────────────────────────────

def chrome_height(meta, chrome):
    """The height, in capture pixels, of the browser window shown above the page."""
    return {'none': 0, 'tabs': meta['tabs'], 'full': meta['top']}[chrome]


def band_height(meta, cfg, chrome):
    """The height, in capture pixels, of the strip under the page that holds the captions."""
    return round(cfg['bandHeight'] * (chrome_height(meta, chrome) + meta['height'])) if cfg['position'] == 'band' else 0


def master(outdir, edit, meta, fps, cfg, chrome, cards):
    """Cuts the capture to the page, with the cuts taken out, as master.mkv.

    The window's tab strip goes over the page when `chrome` is 'tabs', which drops the
    toolbar between them because its address bar shows the server's host name; 'full'
    keeps the toolbar too. Under the page goes a band for the captions, if they are to
    have one. `cards` holds the title cards the video fades in from and out to: 'start' and
    'end', each an (image, seconds) pair or None, and the 'fade' time in seconds.
    """
    kept = edit.kept()
    # One pass keeps the frames inside the kept ranges and numbers them afresh, so memory stays
    # constant however many cuts there are: splitting the capture into one trimmed branch for
    # each range would hold every later range's frames until the earlier ones had been read.
    inside = '+'.join(f'gte(t,{a:.4f})*lt(t,{b:.4f})' for a, b in kept)
    graph = [f"[0:v]setpts=PTS-STARTPTS,fps={fps},select='{inside}',setpts=N/({fps}*TB)[c]"]
    w, h, top = meta['width'], meta['height'], meta['top']
    if chrome == 'tabs':
        graph.append(f"[c]split[a][b];[a]crop={w}:{meta['tabs']}:0:0[tabs];[b]crop={w}:{h}:0:{top}[page];[tabs][page]vstack[v0]")
    else:
        graph.append(f"[c]crop={w}:{h + top if chrome == 'full' else h}:0:{0 if chrome == 'full' else top}[v0]")
    band = band_height(meta, cfg, chrome)
    graph.append(f"[v0]pad=iw:ih+{band}:0:0:color=0x{cfg['boxColour']}[body]" if band else '[v0]null[body]')

    inputs, index = ['-i', 'raw.mkv'], 1
    for name in ('start', 'end'):
        if cards[name]:
            image, seconds = cards[name]
            # The card is one frame, repeated as the cross-fade asks for it: a card read as
            # seconds of frames would sit in memory, at 12 MB a frame, until the cross-fade began.
            frames = max(1, round(seconds * fps))
            inputs += ['-framerate', str(fps), '-i', image]
            graph.append(f'[{index}:v]format=yuv444p,fps={fps},loop=loop={frames - 1}:size=1:start=0[{name}]')
            index += 1
    graph.append(f'[body]format=yuv444p,fps={fps}[v1]')
    last, at, fade = 'v1', 0.0, cards['fade']
    if cards['start']:
        at = cards['start'][1] - fade
        graph.append(f'[start][{last}]xfade=transition=fade:duration={fade}:offset={at:.3f}[v2]')
        last = 'v2'
    if cards['end']:
        graph.append(f'[{last}][end]xfade=transition=fade:duration={fade}:offset={at + edit.at(edit.end) - fade:.3f}[v3]')
        last = 'v3'
    ffmpeg(outdir, *inputs, '-filter_complex', ';'.join(graph), '-map', f'[{last}]', '-r', str(fps),
           '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '12', '-pix_fmt', 'yuv444p', 'master.mkv')


def narration(outdir, clips, length):
    """Mixes each (start, wav) in at its start; returns the file name."""
    inputs, parts = [], []
    for i, (start, wav) in enumerate(clips):
        inputs += ['-i', wav]
        ms = round(start * 1000)
        parts.append(f'[{i}:a]aresample=48000,aformat=channel_layouts=stereo,adelay={ms}|{ms}[a{i}]')
    mix = ''.join(f'[a{i}]' for i in range(len(clips)))
    graph = ';'.join(parts) + f';{mix}amix=inputs={len(clips)}:normalize=0,apad,atrim=0:{length:.3f}[out]'
    ffmpeg(outdir, *inputs, '-filter_complex', graph, '-map', '[out]', 'narration.wav')
    return 'narration.wav'


def encode(outdir, name, fmt, o, voice):
    pre = f"fps={o['fps']},scale={o['width']}:-2:flags=lanczos,subtitles=captions.ass"
    target = f'{name}.{fmt}'
    if fmt == 'mp4':
        audio = ['-i', voice, '-map', '0:v', '-map', '1:a', '-c:a', 'aac', '-b:a', '160k'] if voice else []
        ffmpeg(outdir, '-i', 'master.mkv', *audio, '-vf', pre, '-c:v', 'libx264', '-crf', str(o['crf']),
               '-pix_fmt', 'yuv420p', '-movflags', '+faststart', target)
    elif fmt == 'gif':
        # Two passes, so the palette is learned without holding the whole video in memory.
        ffmpeg(outdir, '-i', 'master.mkv', '-vf', f"{pre},palettegen=max_colors={o['colors']}:stats_mode=diff", 'palette.png')
        ffmpeg(outdir, '-i', 'master.mkv', '-i', 'palette.png', '-lavfi',
               f'{pre}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle', target)
    elif fmt == 'webp':
        ffmpeg(outdir, '-i', 'master.mkv', '-vf', pre, '-c:v', 'libwebp_anim', '-quality', str(o['quality']),
               '-compression_level', '6', '-loop', '0', target)
    else:
        sys.exit(f'unknown format {fmt}')
    size = os.path.getsize(f'{outdir}/{target}') / 1e6
    note = "  (over GitHub's 10 MB inline limit)" if fmt in ('gif', 'webp') and size > 10 else ''
    print(f'{outdir}/{target}  {size:.1f} MB{note}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir')
    ap.add_argument('name')
    ap.add_argument('--formats', default='mp4,gif,webp')
    ap.add_argument('--chrome', choices=CHROME, help="the browser window to show above the page (default: the video's, else config.json's)")
    ap.add_argument('--captions-position', choices=POSITIONS, help='where captions go (default: the video\'s, else config.json\'s)')
    ap.add_argument('--voice', help="a voice in voices/, or 'none' (default: the video's voice.engine, else config.json's)")
    a = ap.parse_args()
    out = os.path.abspath(a.outdir)

    config = load(f'{ROOT}/config.json')
    timeline, meta = load(f'{out}/timeline.json'), load(f'{out}/meta.json')
    with open(f'{out}/t0') as f:
        t0 = int(f.read()) / 1000

    def rel(ms):
        return ms / 1000 - t0

    caps = timeline['captions']
    if not caps:
        sys.exit('the video said nothing: there is no caption to time the finished video by')
    engine = a.voice or timeline.get('options', {}).get('voice', {}).get('engine') or config['voice']['engine']

    # The speech: each caption's clip, or the video's reading-time estimate when silent.
    clips = [synthesise(engine, c['speak'], f'{out}/voice-cache') for c in caps] if engine != 'none' else None
    lengths = [seconds(w) + 0.1 for w in clips] if clips else [c['seconds'] for c in caps]

    start = rel(timeline['start']) if timeline.get('start') else rel(caps[0]['start']) - config['lead']
    trim, end = max(0.0, start), rel(caps[-1]['end'])
    cuts = [[max(trim, rel(s['start'])), min(end, rel(s['end']))] for s in timeline['skips']
            if rel(s['end']) > trim and rel(s['start']) < end]
    edit = Edit(trim, end, cuts)
    starts = [rel(c['start']) for c in caps]
    problems, notes = check_timing(edit, caps, starts, lengths, config['speech']['gapSeconds'])
    if problems:
        print(f'{len(problems)} timing problem{"s" if len(problems) > 1 else ""}; nothing was rendered:', file=sys.stderr)
        for p in problems:
            print(f'  {p}', file=sys.stderr)
        sys.exit(1)

    # Where each caption lands in the finished video, once the start card has faded into it.
    cfg, chrome, card_cfg = options(config, timeline, a.chrome, a.captions_position)
    fade = card_cfg.get('fade', 0)
    shift = card_cfg['start']['seconds'] - fade if card_cfg.get('start') else 0.0
    at = [shift + edit.at(t) - c.get('lead', 0) for t, c in zip(starts, caps)]
    early = [i + 1 for i, t in enumerate(at) if t < 0]
    if early:
        sys.exit(f"caption {early[0]} leads the picture by more than the video has run when it starts: "
                 "lower its `lead`, or give the start card more time")
    content_end = shift + edit.at(end)
    length = content_end + (card_cfg['end']['seconds'] - fade if card_cfg.get('end') else 0.0)
    cues = []
    for i, c in enumerate(caps):
        cues += phrase_cues(c, at[i], lengths[i], at[i + 1] if i + 1 < len(caps) else content_end, cfg)
    # The finished video's size at 1920 wide: the browser window shown and the page, then the caption band.
    scale = 1920 / meta['width']
    band = band_height(meta, cfg, chrome)
    page_h = round((chrome_height(meta, chrome) + meta['height']) * scale)
    write_captions(out, cues, cfg, (1920, page_h + round(band * scale)), page_h)

    size = (meta['width'], chrome_height(meta, chrome) + meta['height'] + band)
    cards = {'fade': fade}
    for name in ('start', 'end'):
        card = card_cfg.get(name)
        cards[name] = (make_card(out, f'card-{name}', card, card_cfg, size), card['seconds']) if card else None
    master(out, edit, meta, config['fps'], cfg, chrome, cards)
    voice = narration(out, list(zip(at, clips)), length) if clips else None
    for fmt in a.formats.split(','):
        encode(out, a.name, fmt, config['outputs'][fmt], voice)

    for n in notes:
        print(n)
    print(f'{length:.1f} s, {len(caps)} captions, {sum(b - a for a, b in edit.cuts):.1f} s cut')


if __name__ == '__main__':
    main()
