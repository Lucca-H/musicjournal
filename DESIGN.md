# Design System — MusicJournal

## Product Context
- **What this is:** a native macOS app that finds music for how you feel (Spotify or YouTube), keeps a private, Touch-ID-locked journal of your days and the songs that stuck, and has a small gravel zen garden.
- **Who it's for:** one person, mostly at the end of the day.
- **Space:** mood and music apps, personal journals, calm apps.
- **Project type:** native Mac app (SwiftUI, macOS 26, Liquid Glass).
- **The one thing to remember:** *it feels like dusk.* Every decision below serves that.

## Aesthetic Direction
- **Direction:** "Last Light": the twenty minutes after sunset. Dim, warm, lit from low and far away.
- **Decoration level:** intentional but light. The sky (glows, moonlight, stars) and the gravel garden are the only textures; everything else is type and space.
- **Mood:** the window should feel a little darker and quieter than the rest of the desktop, like dimming a lamp. First reaction: an exhale.
- **Never:** loud saturated colour, pure white text, bouncy or playful motion, greetings or emoji in the UI, streaks and scores.

## The Sky (window background)
The background follows the real evening by the local clock (`UI/NightSky.swift`, `Sky.at(_:)`).

| Time | What's lit |
|------|-----------|
| Day (7 am – 5 pm) | a soft warm glow, no stars |
| Sunset (5 – 7 pm) | clay glow from the upper left, a low horizon glow along the bottom |
| Evening (7 – 11 pm) | the glow fades and shifts to violet; stars fade in |
| Midnight onward | **no warm glow at all**; faint silver moonlight from the upper right, and stars |
| Dawn (4:30 – 6 am) | warmth returns, stars fade |

- **The room itself dims** through the evening: the background runs from a lighter ink in the afternoon (`#23222C`) through night ink (`#18171F`, about 10 pm) to its deepest (`#0F0E14`) around 3 am, and lifts at dawn. Sunset warms the glow's colour but never brightens the room, so from the afternoon on it only ever gets darker (measured average brightness: 59 at noon → 50 at 7 pm → 31 at 10 pm → 21 at 3 am).
- Glows are tinted by the current mood (valence picks the tone, energy adds a little strength) and blend in over ~2.4 s when the mood changes.
- Glows drift and breathe on offset 47–89 s loops: never fast enough to watch.
- **Stars** (dark mode only): ~170, mostly high up, 0.35–1.45 pt, a quarter twinkling slowly, the field turning one width per 15 minutes, a faint shooting star about once a minute when it's fully dark. They sit behind the whole interface; content surfaces stay translucent enough to let them through.
- A faint vignette darkens the edges first.
- **Reduce Motion:** everything holds still. **Light mode:** same glows, lighter, no stars.

## Color
- **Approach:** restrained. Neutrals plus one accent; colour is rare and means something.

| Token | Dark | Light | Use |
|-------|------|-------|-----|
| background (night ink / paper) | `#18171F` | `#ECE7DF` | window |
| surface | `#211F29` (or white 5%) | `#E4DED5` (or black 3.5%) | cards, lists, fields |
| surface 2 | `#282632` | `#DCD5CA` | selected segment, empty chart days |
| hairline | `#2F2D38` | `#D2CABE` | borders, dividers |
| text | `#DFD7CC` | `#29262F` | never pure white or black |
| text 2 | `#938C98` | `#6B6570` | secondary |
| text 3 | `#676270` | `#999299` | placeholders, hints |
| **accent** (dusty rose) | `#C28F94` | `#C28F94` | **at most one per screen**: the primary action |

- **Day scale / sky ramp (Awful → Great):** `#5E6B85` blue hour · `#7F7C9C` violet · `#A88A9E` mauve · `#C4978A` clay · `#D9BC95` afterglow. Lightness rises every step, so the month chart reads by brightness alone (it still works in grayscale).
- **Sky glow colours:** dusk clay `#C98F77`, dusk mauve `#977A90`, night violet `#5D5985`, night blue `#434A6B`, moonlight `#B8C4DC`.
- **Semantic:** error/warning use clay `#C47A6E` on a tinted glass; success uses the afterglow tone. No bright red or green.
- **Glow on things:** the primary button, the playing song, today's day and chosen feelings give off soft light (`0 0 28pt` accent at ~55%); these halos dim as the night deepens.
- **Dark mode is the primary design.** Light mode is the same system on paper, slightly dimmed.

## Typography
- **Titles / voice:** **Fraunces** Light (300), `SOFT 100`, `WONK 0`, optical size matched to the point size. SIL Open Font License; bundled with the app. Fallback: New York Light.
- **Interface:** SF Pro Text, Regular; Medium at most, never bold.
- **Small print (dates, counts, times):** SF Mono Light, 11 pt, +2% tracking, tabular figures, usually lowercase, like the small print on a record sleeve.
- **Journal feelings:** Fraunces Light *italic*, so they read like handwriting.
- **Scale (pt):**

| Role | Size | Font |
|------|------|------|
| welcome hero (tour only) | 40 | Fraunces 300 |
| page title | 34 | Fraunces 300 |
| sheet title | 26 | Fraunces 300 |
| mood prompt, mood reading | 22 | Fraunces 300 |
| mood quote | 20 italic | Fraunces 300 |
| words on a playlist cover | 20 | Fraunces 300 |
| small title (a month, up next) | 17 | Fraunces 300 |
| journal writing | 17, line spacing 4 | Fraunces 300 |
| quick log line | 16 | Fraunces 300 |
| feelings | 15 italic (12 in the chart key) | Fraunces 300 |
| interface | 15 / 13 | SF Pro |
| label (caps, +8% tracking) | 11 | SF Pro Medium |
| small print | 11 | SF Mono 300 |

## Spacing
- **Base unit:** 4 pt. **Density:** roomy.
- **Scale:** 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64.

## Layout
- Content is centred and calm: composer max 640 pt, results max ~1040 pt, journal entry max 760 pt.
- Glass is for **controls only** (buttons, the tab switcher, the composer, the player bar, toasts). Content sits on flat, low-contrast surfaces.
- **Corners:** chips, thumbnails, list rows 6 · fields 10 · cards 16 · panels 24 · large glass 32 · glass controls use capsules. Thin line-like bars may use 2.
- **In code:** `Theme.Serif.*`, `Theme.smallPrint`, `Theme.text(_:)`, `Theme.moodTones` (the sky ramp) and `.primaryAction(_:)` for the one accent button.

## Motion
- **Character:** slow deceleration, no bounce. Things arrive the way light fades.
- **Easing:** `cubic-bezier(0.22, 1, 0.36, 1)` (SwiftUI: `.smooth` or springs with damping ≥ 0.85).
- **Durations:** controls 0.16–0.2 s · content 0.6–0.9 s · list stagger 80 ms · mood-colour changes 1.4–2.4 s · sky loops 47–89 s.
- Satisfying feedback (logging, rating) comes from haptics and a small scale or glow, not from overshoot. SF Symbol feedback uses a single `.pulse`, never `.bounce`.
- **Reduce Motion:** crossfades only; the sky freezes.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-09-27 | Codified "Dusk Record" as "Last Light" | /design-consultation; owner chose to refine, not restart. Memorable thing: *it feels like dusk*. |
| 2026-09-27 | Night ink `#18171F`, dimmer warm text | Owner asked for "a tiny smidge more moody". |
| 2026-09-27 | Sky-brightness day scale | The old four mood tones were near-identical in lightness; the chart relied on hue alone. |
| 2026-09-27 | Accent once per screen | Keeps the rose meaningful; the preview showed two rose buttons competing. |
| 2026-09-27 | Fraunces for titles | Warmth nobody else in the space has; New York as fallback. |
| 2026-09-27 | Background follows the real evening | Makes "dusk" literal. Owner: "a lot more glow", then "hints of stars", "soft animation", and "1 am should have no glowing at all… hints of moonlight". |
| 2026-09-27 | Stars behind the whole interface | Owner asked for the stars in the app background, not only around it. |
| 2026-09-27 | Applied to the app | Fraunces bundled (Resources/Fonts, OFL), sky-ramp day colours, type and corner scales, warm text, one accent per screen, no-bounce motion. |
| 2026-09-27 | One-record-at-a-time results and a horizon-strip month chart: not adopted | Proposed by the outside voice; they change behaviour, not look. Left for a separate design pass. |

Preview: `~/.gstack/projects/spot-helper/designs/design-system-20260927/preview.html`.
