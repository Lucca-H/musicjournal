# MusicJournal

A native macOS app that recommends music for how you feel, with a private, locked journal of your moods and the songs that stuck. Type your mood in plain words ("rainy sunday, a bit melancholy but cozy") and get:

- **Playlists to find on Spotify**: mood-shaped search phrases that open straight in the Spotify app
- **Custom mix**: about 25 songs chosen for the mood and your taste, with artwork and 30-second previews. Click a song to open it in Spotify, **Play in Spotify** to play the whole mix there, or **YouTube** to queue it all on YouTube.

It works with a **free Spotify account** and needs no login.

## Download & install

1. Download `MusicJournal-<version>.zip` from the [Releases](../../releases) page and unzip it.
2. Drag **MusicJournal** into your Applications folder.
3. Open it. The first time, macOS says it can't verify the developer, because the app isn't
   notarized by Apple. Click **Done**, then open **System Settings → Privacy & Security**, scroll
   down, and click **Open Anyway** next to MusicJournal. (Or right-click the app → **Open**.)
   You only need to do this once.
4. When you first play a mix, macOS asks whether MusicJournal may control Spotify. Click **OK**.

**You'll need:**
- **macOS 26** (Tahoe) or later.
- The **Spotify desktop app**. A free account is fine.
- For recommendations: **[Claude Code](https://claude.com/claude-code)** installed and signed in
  (`claude -p "hi"` should work in Terminal). No API key needed; it uses your Claude subscription.
  Without it, MusicJournal uses Apple's on-device model if Apple Intelligence is on.
- For **Play in Spotify**: connect Spotify in claude.ai → **Settings → Connectors**.

Everything you write in the journal stays on your Mac, encrypted, and locked with Touch ID or
your Mac password.

## How it works

Spotify no longer offers mood data (audio features, recommendations) to new apps, so a language model does the matching:

1. **The mood leads.** By default, picks are based on how you feel, with variety: at most 2 songs per artist (enforced), and a mix of well-known songs and ones you probably haven't heard.
2. **The mood brain** turns your mood (plus your personalization profile, if you set one up) into a plan: an interpretation, energy/valence, playlist search phrases, and song suggestions. Each mood is a fresh request with no memory of earlier moods.
   - **Claude** (default) runs through your installed Claude Code CLI (`claude -p`), so it uses your Claude subscription. No API key needed. About 10 to 15 seconds per mood.
   - **Apple's on-device model** (macOS 26, Apple Intelligence on) is used as a fallback, or on its own if you choose that in Settings.
3. **Checking songs**: each suggestion is looked up with Apple's free iTunes Search API, which provides artwork, duration and a preview clip. iTunes is missing some real songs (Bon Iver's "Holocene", for one), so a song it can't find is shown as *not verified* rather than hidden. Clicking any song runs a Spotify search for it in the desktop app, or in the web player if the app isn't installed.

## Play in Spotify (free accounts)

Spotify's scripting can play a specific song but has no "add to queue" or "make a playlist" (both are Premium-only through its API). So MusicJournal acts as the queue:

1. **Play in Spotify** looks up every song with Spotify's official Claude connector. Its search works on free accounts, and this takes about 30 seconds the first time per mix.
2. Each link is checked against Spotify's public oEmbed endpoint, so made-up or mismatched songs are dropped.
3. MusicJournal tells the Spotify app to play song 1, watches for it to end, then plays song 2, and so on. A glass bar at the bottom shows what's playing, with previous, next and stop.

How the queue behaves:
- **Your control:** pausing in Spotify is fine; the queue waits. If you play something else yourself, the queue steps aside. Spotify may insert ads on free accounts, and the queue waits them out.
- **Where to start:** right-click a song to play from there.
- **Past journal entries:** they have their own **Play in Spotify** button. It plays the songs that stuck, or all of them, and remembers the Spotify links for next time.
- **Needs:** MusicJournal has to stay open while it plays. The first time, macOS asks whether MusicJournal may control Spotify.
- **Label-blocked songs:** some record labels block the Claude connector, so a few songs per mix can't be played this way. They're skipped.

This needs Spotify connected in claude.ai (**Settings → Connectors**).

## Play on YouTube

**YouTube** (next to Play in Spotify, on journal entries, and "Play from here on YouTube" when you
right-click a song) queues the whole mix on YouTube in one go and opens it in your browser. No
login or API key needed.

- Each song is looked up with the same search the YouTube website uses. MusicJournal picks the
  artist's own upload (official audio first), close to the right length, and passes over live
  versions, covers, sped-up edits and full albums. A mix of 25 takes a few seconds.
- YouTube plays the list as a temporary playlist, in order, with its own next, shuffle and loop.
  It holds up to 50 songs. MusicJournal doesn't need to stay open.
- Starting YouTube stops the Spotify queue (and pauses Spotify), so only one thing plays.
- Journal entries remember each song's video, so replaying a past day is instant.

## Journal

Switch to **Journal** with the Mood | Journal control at the top of the window.

What's in it:
- **Locked:** it opens with Touch ID or your Mac password. It locks itself when the Mac sleeps, the screen locks, or you've been away from the app for 5 minutes. **⌘L** locks it now.
- **Encrypted on this Mac:** AES-GCM, with the key in your Keychain. Entries are only sent to Claude when you press **Suggest from my writing**, and only that entry.
- **Add log (⇧⌘L, from anywhere):** how the day's going on five steps (Awful · Rough · Okay · Good · Great) and a line. Saving gives a soft haptic and a "Logged" note, and today's square in the month chart ripples as it fills in.
- **Write:** opens today's page for more; **⌘N** makes a new entry.
- **From a mood:** **Save to journal** on results saves the mood, the mix and your 👍 songs as an entry.
- **Songs that stuck:** star songs from the mix, or add any song as "Title — Artist". **Play in Spotify** plays them.
- **How was the day?** Awful to great on one scale, asked once a day: the day's first entry (or first quick log) asks it, and later entries just show a quiet "A good day · Change" line. A day has one answer, and it's what colours the month chart. Claude's suggestion only rates the day if you haven't.
- **Feelings (optional detail):** pick up to three of 14 feelings, each with its own muted colour: joyful, excited, loved, grateful, calm, hopeful, nostalgic, tired, numb, anxious, overwhelmed, sad, lonely, angry.
  - **Suggest from my writing** sends that one entry to Claude, which rates the day and picks feelings, with a one-line reason. It only runs when you press it, and you can change the picks.
  - Entries saved from a mood start with a feeling based on how Claude read that mood.
- **Month chart:** one colour per day, from rough to great. Click a day to open it.

## Zen corner

A sand garden to rake when you need a minute. It isn't a picture: the sand is simulated as a surface of heights, lit from the top left.
- **Raking:** the rake presses grooves where its tines pass and lifts ridges between them, and your pointer becomes the rake while you're over the sand.
- **Stones:** they cast soft shadows and can't be raked through.
- **Controls:** choose 3, 5 or 7 tines. **Smooth the sand** sweeps it flat again, and **Move stones** rearranges them.

## Welcome tour

The first launch shows a short tour: how it works, a setup check (Claude Code signed in, Spotify app installed), optional taste, and the journal. Replay it from **Help → Welcome Tour**.

## Setup

1. **Claude Code** must be installed and logged in: `claude -p "hi"` should work in Terminal.
2. The **Spotify desktop app**, so links open there instead of the browser. It's also needed for pasting the mix into a playlist.
3. For **Play in Spotify**: connect Spotify in claude.ai → Settings → Connectors.
4. Optional: turn on Apple Intelligence for the on-device fallback.

## Build and run

Only the Command Line Tools are needed; Xcode isn't required.

```bash
scripts/build-app.sh          # → build/MusicJournal.app (ad-hoc signed)
open build/MusicJournal.app
```

```bash
scripts/package.sh            # → dist/MusicJournal-<version>.zip, ready for a GitHub Release
scripts/test.sh               # unit tests (Swift Testing)
scripts/make-icon.sh          # regenerate Resources/AppIcon.icns from scripts/icon/AppIcon.swift

# Try the pipeline from the terminal, no UI:
.build/debug/MusicJournal --brain-test "late night drive" free "Radiohead, Nujabes"   # full free mode
.build/debug/MusicJournal --brain-test "late night drive" free "Radiohead" links      # + Spotify links
.build/debug/MusicJournal --brain-test "hyped for the gym" claude                    # just the Claude plan
.build/debug/MusicJournal --brain-test "hyped for the gym" apple                     # just the on-device plan
.build/debug/MusicJournal --resolve-test "Holocene — Bon Iver"                        # Spotify lookup only (nothing plays)
.build/debug/MusicJournal --youtube-test "Holocene — Bon Iver"                        # YouTube lookup only (nothing opens)
```

## Settings (⌘,)

**Personalization** (all optional; your mood always comes first):

*How to pick*: applies to every mix.
- **Mood**:
  - *Match me* stays with how you feel.
  - *Lift me up* starts close to your mood and moves somewhere warmer.
  - *You decide* lets Claude judge from your words.
  - This switch also sits under the mood box.
- **Discovery**: *Familiar* hits, *Balanced*, or *Discover* deep cuts.
- **Vocals** (any, mostly instrumental, or mostly vocals), **Songs per mix** (15/25/40), and **Clean lyrics only**. Clean-only drops tracks iTunes or Spotify mark as explicit.

*What you like*: follows the **Use my taste** dial.
- *Off* goes by mood alone.
- *Subtle* (default) treats your taste as a hint, allows at most 3 songs by your artists (enforced by the app, not just requested from Claude), and never replays your listed favourites or songs you liked.
- *Strong* leans on your favourites.
- Fields: **Artists**, **Favourite songs** (one per line), **Genres & vibes**, **Eras**, **Languages**, and **Songs you liked**, which fills in from 👍.

*Not for me*: always respected, even with taste off.
- **Artists & genres** to never suggest.
- **Songs you skipped**, which fills in from 👎. A skipped song leaves the current mix too: it isn't played, copied or saved.

Hover a song in a mix for 👍 / 👎. Both are toggles, and 👍/👎 on the same song replace each other.

**General**:
- **Mode**: Free (default) or Spotify account (see below). In account mode, your Spotify listening history is used as your taste, following the same Off/Subtle/Strong setting.
- **Mood brain**: Claude with on-device fallback, Claude only, or on-device only.
- **Claude model**: leave blank to use your Claude Code default, or enter e.g. `sonnet`. Requests run at `--effort low` (override with `SPOTHELPER_EFFORT`).
- **Claude CLI path**: auto-detected (`~/.local/bin/claude`, Homebrew, or your login shell's PATH).

## Optional: Spotify account mode (needs Premium)

If you have Spotify Premium, account mode adds:
- **Your own playlists** that fit the mood
- **Real public playlist cards** with artwork
- **Listening history** used as your taste, instead of typed artists
- **One-click "Save to Spotify"** for the mix

Since February 2026, Spotify requires the owner of a developer app to have Premium, and limits it to 5 users.

To set it up:
1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), click **Create app** and tick **Web API**.
2. Add the redirect URI `musicjournal://callback`.
3. Copy the **Client ID**. There's no secret, because the app uses PKCE.
4. In Settings, switch **Mode** to *Spotify account (Premium)*, paste the Client ID, and click **Connect Spotify**.

The refresh token is kept in the Keychain. Because the app is ad-hoc signed, macOS may ask once after each rebuild whether MusicJournal can access it. The **Debug** menu has *Refresh Taste Profile* and *Force Spotify Token Expiry* for this mode.

## Notes

- Each mood uses one Claude Code request, and the first **Play in Spotify** for a mix uses one more. Both count toward your Claude plan's usage.
- iTunes rate-limits heavy use (about 20 requests a minute). If it pushes back, songs show as *not verified* for a minute instead of failing.

## Layout

```
Sources/MusicJournal/
  App/        entry point, AppModel (state), preview player, --brain-test harness
  Brain/      MoodPlan + prompt/schema, Claude CLI brain, Apple on-device brain, fallback
  Catalog/    song matching, iTunes catalog (free), Spotify catalog (account), connector link lookup
  Spotify/    PKCE auth, API client, models, taste profile
  Recommend/  RecommendationEngine: brain → catalog lookups → results
  UI/         SwiftUI views
  Support/    Keychain, process runner, text helpers
```

## License

MIT. See [LICENSE](LICENSE).
