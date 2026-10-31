# Dockside videos

Scripted screen recordings of the Dockside web UI: the welcome video, and any
other instructional video. Each video is defined by a short JavaScript file that drives
a real browser through a real Dockside server the way a person would. One command makes
a **take** of it: it records the browser, adds captions and optional narration, cuts the
waiting, and writes MP4, GIF and WebP files. When the UI changes, take it again.

    tools/video/record.sh welcome-short

There are two videos defined. `welcome-short` is the quick tour, about two minutes and narrated: launch
two devtainers (a React/Next.js app and a Ghost blog), switch between them, open a devtainer's
website, IDE and SSH, and share them. `welcome-long` adds the account page and the admin
screens, and shows the browser's address bar. Both record a server of their own by default,
which `record.sh` starts for them (see "A server of its own"), because the Ghost profile needs a
Dockside server that supports its `dockerArgs`; `welcome-long` also needs one with nothing
else on it. To record in dark mode, or against another server, see "Recording setups".

## What it needs

Run `tools/video/install.sh` to see what is missing, and `install.sh --apt` to install
the Debian/Ubuntu packages (`ffmpeg`, `xvfb`, `chromium`, `fonts-liberation`) with
`sudo apt-get`. It also needs `node`, `python3` and `playwright-core`: run `npm install`
in this directory, or set `PLAYWRIGHT_CORE` to an existing copy of it.

The recording is made on a virtual display (Xvfb), so it works on a server with no
screen. A headed Chromium on that display, at device scale factor 2, renders text the way
a desktop browser does, which a headless browser's built-in video capture does not. The
browser uses an ordinary profile that allows third-party cookies, not Playwright's usual
throwaway one: the IDE shows its webviews in a frame on another origin, and a browser that
blocks third-party storage refuses that frame its service worker, so the IDE would report
an error.

## Recording a video

    record.sh [--target current|child] [--server NICKNAME] [--any-server]
              [--proxy URL | --no-proxy | --connect-to HOST] [--verify-cert]
              [--header 'Name: value'] [--voice NAME] [--formats mp4,gif,webp]
              [--color-scheme light|dark] [--chrome none|tabs|full]
              [--captions-position band|bottom|top]
              [--out DIR] [--build-only | --no-build | --script | --check] VIDEO

A video says where it records with its `target` option. `current`, the default, is the
Dockside in this container: the `dockside` CLI's current server, which the CLI must be
logged in to as an admin (`dockside server list`), browsed through the Playwright MCP
proxy. `child` is a server of its own, started if it is not running, reached directly at
its address with its certificate verified. `--target` chooses the other.

The recording creates a throwaway user, with the role the video's `demo.role` gives, and
signs in as them, so the UI starts from the first-run state and shows none of the server's
other devtainers. The user and every devtainer it launched are removed afterwards, even if
the take fails. The user's generated password is held in a mode-600 temporary file and is
never printed.

The user's account is filled in first: a name and email, an authorized SSH public key, an
SSH keypair, and a GitHub token. They are generated for the recording, never leave this
machine, and are discarded with the user, so the account page has something to show.

- `--target` records the video's other target, `current` or `child`.
- `--server` records another server the CLI is logged in to, instead of the target's.
- `--any-server` lets a video that needs a clean server (its `cleanServer` option) record
  one that is not. See "A server of its own".
- `--proxy` browses through an HTTP proxy. The default is the one named in the Playwright
  MCP config (`$PLAYWRIGHT_MCP_CONFIG`, or `~/.playwright/mcp-config.json`).
- `--no-proxy` browses directly.
- `--connect-to` browses directly, reaching the server's domain at an address or host name
  instead of through DNS, as the CLI's `--connect-to` does. Every host under the server's
  parent domain (`www-…`, `ide-…`) is reached there. Use it for a Dockside in a sibling
  container, which the proxy does not map.
- `--verify-cert` has the browser check the server's certificate, as a visitor's browser
  would, instead of accepting any. A trusted certificate then shows as secure in the
  address bar.
- `--header` adds a request header to every browser request, repeatably. A Dockside nested
  inside another needs the `X-Nest-Level` header that the outer one's nginx would add; the
  CLI sends the same header when it uses `--connect-to`.
- `--voice` narrates with a voice from [`voices/`](voices/README.md), instead of the video's
  `voice.engine` or, failing that, config.json's.
- `--color-scheme` records the page in `light` or `dark`, and the title cards to match. See
  "Colour schemes".
- `--chrome` and `--captions-position` choose how the video is framed. See "Framing".
- `--build-only` rebuilds the videos from the capture already in the output directory.
  Because the build decides all the timing, this is how to try another voice, another
  speed, new caption wording, or a different caption style, in a minute and with no new
  recording.
- `--no-build` records without building, to try a video.
- `--script` prints the video's captions and narration for reading through, and records
  nothing. See "Reviewing the words".
- `--check` works out where the video would record, starting the child server if the
  target needs it, and tests that the CLI can use the server, that the browser's route
  reaches it, and everything in "Checks before recording", without recording.

A take's output goes to `out/<video>/` (not committed; `--out DIR` chooses another directory,
which a second take of the same video, such as the dark one, needs so as not to replace the first):
`<video>.mp4`, `.gif` and `.webp`;
`captions.srt`, `.vtt` and `.ass`; `master.mkv`, the cut video the formats are made from;
and `raw.mkv`, the capture that `--build-only` reads. If a take fails, `failure.png`
shows its last screen.

## Recording setups

Where a video records, and how the browser reaches that server, are independent of its
colour. There are three setups.

**A server of its own, started by `record.sh`** is the default for both videos, and the one to
use when recording from any machine with Docker. `record.sh` starts the child server, which
is a Dockside in a sibling container next to this one (or next to the host, outside a
container), from `newsnowlabs/dockside:latest`, with only its administrator and the profiles
that image carries, and the browser connects to it directly. Nothing about the Dockside the
command is run in matters, except that it provides Docker and the `dockside` CLI.

    tools/video/record.sh welcome-short

To record an image not yet released, name it for that run (this replaces a running child
server of another image):

    VIDEO_CHILD_IMAGE=newsnowlabs/dockside:test tools/video/record.sh welcome-short

**The Dockside this command runs in** is `--target current`: the CLI's current server, which
the CLI must be logged in to as an admin. It suits running the command inside a Dockside
devtainer that runs Dockside itself, with the video's profiles installed and nothing else
the video should not show. The browser reaches that server one of three ways: through the
Playwright MCP proxy if its config names one, or by `--connect-to HOST` to reach the
server's own address directly, or by `--no-proxy`. A Dockside
nested in another may also need `--header 'X-Nest-Level: …'`.

    tools/video/record.sh --target current --connect-to 127.0.0.1 welcome-short

Run inside the Dockside's own container, the server answers on the loopback address, as the
CLI's own `--connect-to` takes it; from elsewhere, give the address it answers on. A Dockside that
lacks the video's profiles fails `--check` at once. A video with `cleanServer` refuses it
altogether unless `--any-server` says that server may be shown.

**Another server the CLI is logged in to** is `--server NICKNAME`, with `--connect-to` or
`--proxy` as that server needs.

In every setup `--check` runs first, and `record.sh` runs the same checks before it records,
stopping before it creates any user if the server, its profiles, the demo accounts or the
narration voice cannot reproduce the video.

## Colour schemes

A video records in `light`, unless its `colorScheme` option or config.json's says
otherwise. `--color-scheme dark` records the same video with the browser asking for a dark
page, which the Dockside client follows, and with the title cards in config.json's
`cards.dark` colours. Make the two takes into separate directories:

    tools/video/record.sh welcome-short
    tools/video/record.sh --color-scheme dark --out tools/video/out/welcome-short-dark welcome-short

The two takes are independent, so each leaves its own `<video>.mp4`, `.gif` and `.webp`.
The colour is a property of the capture, so `--build-only` keeps the capture's and refuses
`--color-scheme`.

## Narration

`welcome-short` is narrated with the `kokoro` voice, which is not committed (see
[`voices/README.md`](voices/README.md)). Where it is not installed, `record.sh` stops before
recording and says so. Pass `--voice none` to record a silent video, captioned in the same
words but timed by `speech.wordsPerSecond`, or install a voice of that name.

## A server of its own

A video that shows the admin screens lists whoever the server has, and one that shows the
address bar shows the server's host name. Neither belongs in a public video unless the
server is new and its name is meant to be seen. A video with `target: 'child'` records a
Dockside server of its own, with only its administrator and a certificate browsers trust
for `*.local.dockside.dev`. `record.sh` starts it with `child-server.sh` when it is not
running, finds its address, and leaves it running for the next recording; remove it with
`child-server.sh down`.

    tools/video/record.sh welcome-long

The server runs `newsnowlabs/dockside:latest`. To record a build that is not released, such
as the `test` image, name it for that run: `VIDEO_CHILD_IMAGE=newsnowlabs/dockside:test
record.sh welcome-long`, or `child-server.sh up --image newsnowlabs/dockside:test`, which
replaces a running server of another image. The default is `childServer.image` in
`config.json`.

A video whose admin screens would show users sets `cleanServer: true`, and `record.sh`
then refuses any server but the child one, unless `--any-server` says that server may be
shown. Separately, the build refuses to show an address bar for a host name not under one of
config.json's `publicDomains`, unless `--chrome full` is given outright.

## Writing a video

A video is defined in `videos/<name>.js`:

    module.exports = {
      options: { demo: { role: 'developer' } },
      async run({ page, login, begin, say, skip, click, type, glideTo, smoothScroll, sleep }) {
        await login();
        begin();
        await say('A caption, and the narration if a voice is selected.');
        await click(page, page.getByRole('button', { name: 'Launch' }));
      },
    };

`run` receives Playwright's `page` and `context`; the server's `url` and the
demo `user`; the parsed `config`; `login()`, which signs in; and these helpers (see
`lib/actions.js`):

- **Pointer.** `glideTo(page, locator)` and `click(page, locator)` move a visible cursor
  along an easing arc, so hover states fire on the way; a click shows a ripple. The
  pointer rests on its target for `pointer.dwellMs` before pressing, and holds the button
  down for `pointer.pressMs`, so the viewer sees what is clicked before the screen
  changes. An element that is off screen is first scrolled into view smoothly.
  `smoothScroll(page, dy)` scrolls with easing. Use these rather than Playwright's own
  `click`, `fill` and `scrollIntoView`, which act instantly and show no cursor.
- **Typing.** `type(page, locator, text)` clicks a field, replaces what it holds, and
  types at an uneven pace; `{ pace: 0.4 }` types faster, as for something done a second
  time. `tabType(page, text)` moves on to the next field with the Tab key and types
  there, which saves the pointer's journey between the fields of a form.
- **Start.** `begin()` marks where the video starts, once the first screen is ready to be
  seen; nothing before it is in the video. Without it the video starts a second before
  the first caption.
- **Captions.** `say(text)` shows a caption from now on, and has it spoken when a voice is
  selected. Write it as the narration, so the viewer reads what they hear. Word the speech
  separately with `say(caption, { speak: '…' })` only when a voice needs it: some words
  with two pronunciations are read the wrong way, such as "lives" in "each one lives in",
  and another word in `speak` avoids it. `say(text, { lead: 2.4 })` starts the speech and
  caption that many seconds before the picture reaches it, so a first caption can begin
  over the start card; the next caption comes that much sooner. `settle(beforeMs)` waits
  until the last caption has been read out, or until `beforeMs` before it has been, so an
  action that takes that long to take effect lands as the caption ends.
- **Waiting.** `appears(locator, ms)` waits up to `ms` for something and says whether it
  showed up, for things that may or may not appear (a dialog, say). Playwright's own
  `isVisible()` does not wait, whatever timeout it is given.
- **Cuts.** `skip(fn)` runs `fn` and removes the time it took from the video, and a moment
  more, because the screen shows a page a moment after the browser has drawn it. Use it around
  anything slow, such as an image pull, a launch, or a page that loads.
- **Tabs.** A link that opens a new tab does so in the recording, where the tab strip
  shows it. `openTab(page, locator)` clicks such a link and returns the new tab, in front,
  as a Playwright `page` to act on; the pointer stays where it was. `showTab(tab)` goes
  back to a tab. The pointer cannot enter the browser's tab strip, so `showTab(tab, { via: page,
  slot: n })` first glides it to the top edge of `page`, over the tab in position `n` of the
  strip, counting from 0 at the left. `closeTab(tab, then)` closes a tab and shows `then`. A video that stops
  or removes a devtainer should close its service tabs first, so the viewer sees them go
  before the services do. With `chrome: 'none'` there is no tab strip to show them in. A
  new tab's wait to reach its address and load is cut from the video. `preOpen(page,
  [{ link, ready }, …])` opens each link's address in a tab the video does not show, waits
  for its `ready(tab)`, and closes it, all in one cut, for a server that does work the first
  time it is asked, such as compiling a page, or asking the user to trust a folder: the video
  then opens the link when it is ready.
- **Dialogs.** `dialogTour(page, { ms, tab, button })` waits for a dialog, holds it for `ms`
  from its appearing to the press on `button`, and presses its tab number `tab` exactly
  halfway.

Prefer waiting for something to appear (`locator.waitFor()`) to a fixed `sleep()`, except
where the pause is the point: giving the viewer time to look. A `say()` waits until the
previous caption has been spoken, so cut dead time by giving the speech something to
accompany, not by removing the action it was timed against.

A video's `options` change config.json's settings for that video alone: `target` and
`cleanServer` (where it records), `requires` (the profile ids it launches devtainers from, `profiles`, and the id the launch form must start on, `firstProfile`), `colorScheme` (`light` or `dark`: the page's `prefers-color-scheme`, which the client's own theme follows, and the title cards then use `cards.dark`), `demo` (the user it signs in as, and whether a viewer to
share with, or a colleague to add as a developer, is made beforehand), `voice` (`engine`: the narration voice in `voices/`, or `none`), `chrome`, `captions` and `cards`. Later wins: `config.json`, then the video's `options`, then the
command line.

## Checks before recording

`record.sh` stops before it records, and before it creates any user, if the server cannot
reproduce the video: a profile that `demo.resources.profiles` gives the demo user, or that the
video `requires`, is absent or inactive on the server, or is not among the demo user's own;
the launch form would start on a profile other than the video's `requires.firstProfile`; a
role the demo user, viewer or colleague needs does not exist; or a user of one of those names
exists that is not a leftover of an earlier recording (a leftover has the display name
`config.json` gives it, and is replaced). `--check` runs these checks without recording.
A video may also assert what it needs from the page itself, before `begin()`, as
`welcome-short` does for its Launch buttons.

## Reviewing the words

    tools/video/record.sh --script welcome-short

prints every `say()` in order, with no server or browser: the caption as the build will
split it into rows, the words the voice will speak where they differ from the caption, and
roughly how long each takes to say. It runs the video against a stand-in page, so it
shows what is said, not what a live run does. To change the words, edit the `say()` calls
in `videos/<name>.js`; to change how captions are split, set `captions` in `config.json`
or pass `phrases` to a `say()`.

A caption is split first after punctuation. A piece still too long for a row (more than
`captions.maxChars`) is then split so that the first row is filled as far as it will go,
or a little short of that if the next row can then begin with a connecting word such as
"and" or "with". A row is never left shorter than `captions.minChars`, and never ends on
a word that belongs with the next, such as "the" or "with", if a boundary exists that
avoids it. The rest is split the same way.

To stop a noun phrase or a verb phrase being broken across rows, list it in the video's
`options.captions.keep` array, or in `captions.keep` in `config.json` for every video:

    options: { captions: { keep: ['development environments', 'access level'] } },

A listed phrase is only broken when no other boundary can make the row fit.

After a recording, `out/<video>/captions.srt` has each row with its time in the finished
video, and `voice-cache/` has each spoken clip as a WAV file to listen to on its own.

## Framing

What the video shows around the page, and where its captions go, can be set in
`config.json`, in a video's `options`, or on the command line.

- `chrome` is how much of the browser window is shown above the page: `none` for the page
  alone, `tabs` for the tab strip, which shows the page titles as they change, and `full`
  for the toolbar with its address bar as well. The address bar shows the server's host
  name, so `tabs` is the default.
- `captions.position` is `band`, a strip added under the page so a caption never covers
  part of the interface (`captions.bandHeight` is its height as a fraction of what is
  above it), or `bottom` or `top`, over the page. A multi-row `block` caption needs a
  taller band, or one of the others.
- `cards` are the title cards the video fades in from and out to: the Dockside logo,
  `start` and `end`, each with its length in seconds, or null for none.

Which of the window's rows are the tab strip depends on the browser: `window.tabStrip` in
`config.json` is the tab strip's height in CSS pixels as Chromium draws it.

## Timing and narration

A take only records events: when each caption starts, what to cut, and how long the
caption takes to say. A `say()` waits for the previous caption's time, so a video keeps a
natural pace while it records. With a voice selected, `record.sh` first renders every
caption's speech and gives each caption exactly as long as its clip, so no slot is a
guess; for a silent video the time is estimated from the word count at
`speech.wordsPerSecond`. Everything else is decided at build time, on the cut video:

1. The cuts are applied.
2. Each caption's speech, a voice's clip or else the reading-time estimate, is placed
   where its caption starts.
3. The timing is checked, and the build stops before encoding if any speech would run
   into the next caption, listing every one with how far over it is.

A clip is free to carry on across a cut: the cut is a jump in the picture, not in the
voice. The build lists where that happens.

## Configuration

`config.json` holds everything a video should not repeat: the demo user and role, the
window size and device scale factor, frame rate, the pointer's pauses, the size and
quality of each output format, the caption style, the title cards, the reading pace and
gap that pace a silent video's captions, the default voice, and the server
`child-server.sh` starts.

GitHub shows a GIF or WebP inline from a README only up to about 10 MB, and plays an MP4
only when it is uploaded as an attachment (drag it into a GitHub comment box to get a
URL). `build.py` says when an output is over that limit; lower that format's `width`,
`fps` or `colors` to shrink it. A video of a few minutes is better linked as an MP4 than
embedded as a GIF.

## How it fits together

    record.sh           start Xvfb and the capture; run the video; stop; build
    child-server.sh     start or remove a Dockside server of its own to record
    install.sh          check, and optionally install, the dependencies
    config.json         the settings above
    videos/*.js         one file per video
    voices/             optional narration voices (not committed)
    lib/run-video.js    start the browser, sign in, run a video, write its timeline
    lib/actions.js      the pointer, typing, tab, caption and cut helpers a video uses
    lib/settings.js     one setting, config.json's with the video's options laid over it
    lib/dry-run.js      what a video says, without a browser (for --script and the voice)
    lib/script.py       print that, as the build would caption it
    lib/speech.py       measure how long each caption takes in the voice
    lib/build.py        capture + timeline -> cut master -> captioned, narrated videos
    lib/card.js         render a title card
    lib/t0tee.py        note when the capture began, so the timeline lines up with it

A take records, against the wall clock, the video's captions and cuts. The capture records
frames. The capture's start time joins the two, and `build.py` does the rest.
