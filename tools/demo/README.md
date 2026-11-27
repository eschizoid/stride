# The stride demo video

A narrated 2-minute video for the README: Claude reads stride's numbers in a
real terminal, steers the stride window through the bus, reads back what the
window shows, and edits next week's plan. Every number on screen comes from
stride; the commands are typed on screen and run for real against a copy of
the database. Tracking issue: #591.

## What you need once

- `ffmpeg`, `jq`, `sqlite3`, the `stride` CLI on `PATH`, and the app at
  `~/Applications/Stride.app` (`just install`, `just viz-app`).
- **Screen recording** for the app that runs the take (the terminal you run it
  from), and **Automation, Terminal** for it: the take opens a Terminal window
  and sets its font and colours. macOS asks for each once.
- **A voice.** By default `voice.sh` uses the voices installed on this Mac
  through `say`; nothing leaves the machine. A Premium or Enhanced voice
  (System Settings, Accessibility, Spoken Content, System Voice, Manage
  Voices) sounds much better and works the same way once downloaded.
  `VOICE_ENGINE=elevenlabs` uses ElevenLabs instead, with the key saved where
  only you can read it:

  ```
  mkdir -p ~/.config/stride-demo && pbpaste > ~/.config/stride-demo/elevenlabs.key && chmod 600 ~/.config/stride-demo/elevenlabs.key
  ```

  `voice.sh` hands it to curl through a header file readable only by you; it
  never appears on a command line or on screen. The narration text is the one
  thing sent off the machine.

## Data

The take runs against a scratch home (`/tmp/stride-demo/home`), built by
`setup.sh` from `~/.stride-demo/snapshot.sqlite` when that exists (a frozen
copy, so retakes show the same facts) and from `~/.stride/db.sqlite`
otherwise. The Strava access and refresh tokens and the client id and secret
are deleted from the copy, so no command on screen can print them. Everything
else is the athlete's real data: class titles, plan text, events, zones. The
database holds no GPS or routes.

`stride week` reads the current calendar week, so the snapshot only tells its
story (a skipped threshold session this week, a threshold planned next
Tuesday) until that week ends. `facts.sh` checks both and stops the take with a
message when either is missing; a new snapshot fixes it.

## Making the video

```
cd tools/demo
./take.sh                      # ~2.5 min; you press [ at the first chime, R at the second
./voice.sh voices              # the voices on this Mac
./voice.sh samples             # the opening line in a few of them
./voice.sh render "<Voice>"    # the narration in the chosen voice
./compose.sh                   # out/stride-demo-1440p.mp4, -1080p.mp4, poster.png, poster.gif, contact-sheet.png
```

During the take the stride window sits at the left of the screen and the
Terminal window at the right. The capture records that rectangle of the
screen, so whatever comes in front of it is recorded too: quit chat and mail
apps first, and keep your hands off the Mac except for two key presses in the
stride window, each cued by a chime: "[" at the first (it steps the trace to
an older session, which the next focus read reports) and "R" at the second (it
reloads the window, so the plan view shows the edit the terminal just made).
A guard sends both windows back on top if another app takes the front. Check
`out/contact-sheet.png` before publishing anything.

## The files

| file | does |
| --- | --- |
| `scenes.tsv` | the scenes: which mark each starts at, its caption, its narration (`{KEY}` filled from `facts.env`) |
| `setup.sh` | the scratch home, with the Strava login removed |
| `facts.sh` | the numbers and ids the take shows, read from stride |
| `window.sh`, `terminal.sh` | the two windows, side by side, filling a 16:9 rectangle |
| `drive.sh` | the terminal half: types and runs each command, logs a mark at every prompt |
| `capture.sh` | records that rectangle with ffmpeg |
| `take.sh` | runs one take end to end |
| `voice.sh` | the narration, by the Mac's own voices or ElevenLabs |
| `compose.sh` | the edit: cards, captions, narration, exports |

The finished MP4 goes up as a release asset or a GitHub attachment, not into
the repo; the README links it from `poster.gif`.
