# Making the device-tree icons legible without making them bigger

Work order for a follow-up session on a Mac with a Swift toolchain. Everything
below is about the small icons on the nested rows inside a connection card
(`DeviceLine` in `MenuContentView.swift`). The card header icons — the charger's
plug, the hub's cable — are fine and are not the subject here.

## What is actually wrong

The row draws its icon like this:

```swift
Image(systemName: entry.node.symbolName)
    .font(.system(size: 9))
    .foregroundStyle(.tertiary)
    .frame(width: 13)
```

Three things compound, and only one of them is size:

1. **9 pt at `.regular` weight.** An SF Symbol at 9 pt has roughly a 0.7 pt
   stroke. On a 13" MacBook Pro at its default scaled resolution a point is
   physically smaller than on an external display, so the same 9 pt is a
   smaller thing on exactly the machine where it was noticed. "More Space"
   scaling makes it smaller again.
2. **`.tertiary`.** About a quarter-opacity white over a translucent, moving
   background. Thin stroke and low contrast multiply — each one alone would be
   survivable.
3. **The glyphs themselves.** `point.3.connected.trianglepath.dotted` is the
   worst case in the table: three hairline circles joined by a *dotted* path.
   At 9 pt the dots are sub-pixel and it resolves to a smudge. `display` and
   `cable.connector.horizontal` are outline symbols with the same problem.

The screenshot in the README is the proof. At the *same* 9 pt, `keyboard.fill`
and `sdcard.fill` are perfectly readable, and the three hubs are not. Nothing
separates them but how much ink is on the page.

## The idea

**Legibility here is a function of ink, not area — and the hierarchy that
"bigger would ruin" is carried by contrast, not size.**

Two consequences, and they're what the whole plan rests on:

- Filling the glyphs, thickening the stroke and raising the contrast buys most
  of the legibility back at an unchanged footprint.
- A modest size bump is *free anyway*. The icon sets neither dimension of the
  row: height comes from the text block (an 11 pt name over a 10 pt meta line,
  ~28 pt), width from a fixed `.frame(width: 13)`. Going 9 → 11 pt moves no
  other pixel. The icon stays subordinate to the 11 pt name because it stays
  `.secondary` against the name's `.primary` — which is where the hierarchy
  actually lives.

So: take the free size, spend it on ink, and hold the hierarchy with colour.

The tiers below are ordered by confidence and can be stopped at any point.
Tier 1 alone is expected to resolve the complaint.

---

## Tier 1 — the free fix

No layout change at all. The icon column is 13 + 6 = 19 pt wide today; it stays
19 pt.

In `MenuContentView.swift`, `DeviceLine.body`:

```diff
             Image(systemName: entry.node.symbolName)
-                .font(.system(size: 9))
-                .foregroundStyle(.tertiary)
-                .frame(width: 13)
-                .padding(.top, 2)
-                .padding(.trailing, 6)
+                .font(.system(size: 11, weight: .medium))
+                .symbolVariant(.fill)
+                .foregroundStyle(.secondary)
+                .frame(width: 14)
+                .padding(.top, 1)
+                .padding(.trailing, 5)
```

Line by line, because each one is doing separate work:

- **`size: 11`** — matches the name next to it. Free, per above.
- **`weight: .medium`** — SF Symbols scale stroke weight with font weight, so
  this thickens the line without widening the glyph. Try `.semibold` if
  `.medium` still reads thin on the panel's translucent backing; it is the one
  value here most worth eyeballing at both weights.
- **`.symbolVariant(.fill)`** — asks for the filled variant of whatever symbol
  the row resolved to, and silently keeps the outline where no fill exists.
  One line, and it upgrades most of the table without touching it. Note it is
  applied *here* and not in the shared table, so the card headers keep their
  current outline look deliberately.
- **`.secondary`** — the single biggest contrast win, and reversible in one
  word if the rows start shouting over the card title.
- **`width: 14` with trailing `5`** — an 11 pt glyph can exceed a 13 pt layout
  width on the wide symbols (`keyboard.fill`, `cable.connector.horizontal`).
  SwiftUI will not clip it, it will just overlap the text. 14 + 5 keeps the
  column at the same 19 pt while giving the glyph room. Even widths also land
  hairlines on the pixel grid at 2x rather than straddling it.
- **`.padding(.top, 1)`** — a taller glyph sits higher against the name's cap
  height. Eyeball this; it is pure optical alignment, worth 30 seconds.

### Then check hierarchy, not just legibility

The one real risk in Tier 1 is that the nested rows now compete with the card
header. Open a card with a hub in it and look at the whole panel at arm's
length. If the tree shouts, walk back **`.secondary` → `.tertiary` first** and
keep the size and fill — contrast is the cheapest dial and the one that costs
no legibility of *shape*.

---

## Tier 2 — the glyph table

`Models.swift`, `DeviceNode.symbolName`. Only worth doing for symbols where
`.symbolVariant(.fill)` cannot help, because the fill variant is named
irregularly or does not exist.

**Do this one regardless — it is the single worst offender and the reason three
rows in the screenshot are unreadable:**

```diff
-        case "Hub": return "point.3.connected.trianglepath.dotted"
+        case "Hub": return "point.3.filled.connected.trianglepath.dotted"
```

`.symbolVariant(.fill)` will *not* find this one on its own: the fill is
infixed as `filled` rather than suffixed as `.fill`, so it has to be spelled
out. It has been available since macOS 12, so the deployment target is fine.

⚠️ **This table also feeds the card header icons** (`Connection.symbol`, via
`DeviceModel.swift:293` and `:323`). Any change here changes both places. For
the hub that is a straight improvement in both. Just look at the header after
changing it rather than being surprised by it.

Judgement calls to make with the SF Symbols app open, at 9–11 pt, rather than
from a list:

| Type | Now | Problem at small size | Try |
|---|---|---|---|
| Display | `display` | thin outline, but a simple closed rect | keep; `tv.fill` if still weak |
| Ethernet | `cable.connector.horizontal` | wide and thin, tiny in a 14 pt box | keep at `.medium`; no good filled equivalent exists |
| AirPods | `airpodspro` | very detailed, hopeless at this size | `headphones` — a simple arc, and reads |
| Apple Watch | `applewatch` | detailed, no better option | keep |
| Audio | `speaker.wave.2.fill` | body is solid, the waves are hairlines | `speaker.fill` if the waves smear |

Everything else in the table (`externaldrive.fill`, `sdcard.fill`,
`keyboard.fill`, `computermouse.fill`, `camera.fill`, `bolt.fill`) is already
filled and already fine.

### Verify the names resolve

A mistyped or too-new symbol name renders as nothing at all, and an empty icon
column is easy to miss in a list of twelve devices. `NSImage` returns nil for a
name the OS does not know, so this can be checked rather than assumed:

```swift
// Throwaway, in --dump or a test: prints anything this macOS cannot draw.
for name in ["point.3.filled.connected.trianglepath.dotted", "headphones", /* … */] {
    if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
        print("missing symbol:", name)
    }
}
```

---

## Tier 3 — colour, only if shape still is not enough

Do not start here, and only reach for it if Tiers 1–2 leave the rows legible
but still hard to *tell apart* at a glance.

Colour is recognised pre-attentively — it separates categories with no extra
pixels at all, which is exactly the constraint. `.symbolRenderingMode(.hierarchical)`
plus a tint per category:

```swift
.foregroundStyle(deviceTint(entry.node))   // desaturated, .secondary as the default
```

Keep it to three or four categories that are genuinely different kinds of thing
— storage, display, input, everything else neutral — and keep them
desaturated. A utility panel that turns into a rainbow has traded one legibility
problem for another, and this panel already spends its colour budget on the
allocation bar, where colour *means* something. If a tint here reads as a
fourth signal competing with those, drop it and stay monochrome.

---

## Considered and rejected

- **Just make them bigger.** Rejected as stated — but note the diagnosis above:
  the size bump in Tier 1 is not what fixes it, ink is. Size alone would have
  had to go a long way to fix a contrast problem, and *that* is what would have
  wrecked the hierarchy.
- **Drop the icons on nested rows.** Defensible — the meta line already spells
  the type out in words ("Hub · 480 Mbps · VIA Labs"), so the icon is
  technically redundant, and the tree guides already carry the structure. But
  the icon is what makes the list scannable without reading it, which is the
  whole point of a glanceable panel. Keep it only as a last resort.
- **An icon-size setting.** Settings already carry seven toggles. A preference
  is what you ship when you cannot decide; this one is decidable.

## Checklist for the session

- [ ] Tier 1 diff applied, `./build.sh --install`, panel open with a hub attached
- [ ] `.medium` vs `.semibold` compared on the actual 13" panel
- [ ] Hierarchy checked at arm's length; `.secondary` → `.tertiary` if the tree shouts
- [ ] Hub symbol swapped, **card header** checked as well as the tree row
- [ ] Tier 2 judgement calls made against real hardware, not the table above
- [ ] Every symbol name resolves (nil check)
- [ ] `docs/panel.png` re-shot if the change is visible enough to date the README
