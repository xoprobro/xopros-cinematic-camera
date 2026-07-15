# Cinematic Camera for Garry's Mod

A free-flying cinematic camera addon for Garry's Mod, built for filming machinima-style shots without messing with your normal player movement.

## What it does

- A free-fly camera you can move independently of your player, controlled with the arrow keys (and Alt + arrows to look around), so your WASD, mouse aim, and weapon firing stay completely normal
- Multiple camera modes: Free Fly, Static, Top-Down, Shoulder, Chase, Front, Crane, Orbit, Dolly Zoom (vertigo effect), Drone Follow, Low-Angle Hero, and Side-Scroller
- A "Bone Cam" that attaches to specific parts of your playermodel's actual skeleton (head, chest, hands, feet, etc.) and follows them in real time
- Cinematic black bars and a HUD-hide toggle (with weapon switching still working while hidden)
- Handheld shake and Dutch tilt effects
- An AFK cam that kicks in when you've been idle for a while, cutting between nearby players/NPCs/vehicles like an idle camera in an open-world game, and hands control back the instant you move again
- Everything is controlled from a menu accessible by pressing C (the same context menu other addons like PAC3 use)

## Installation

1. Download or clone this repo
2. Drop the whole folder into your `garrysmod/addons/` directory
3. Restart Garry's Mod
4. Press **C** in-game and look for the camera icon

## Controls

| Key | Action |
|---|---|
| Arrow keys | Move the camera (Free Fly mode) |
| Alt + Arrow keys | Rotate the camera |
| Page Up / Page Down | Move camera up/down |

Everything else (mode switching, sliders, checkboxes) is handled through the in-game menu rather than console commands, so there's nothing else to memorize.

## Notes

This was built through a long back-and-forth of testing and iterating in-game, so some of the numbers (camera offsets, speeds, etc.) are tuned by feel rather than any hard science. If something feels off for your setup, the values are easy to find and tweak near the top of the script.

## License

MIT — do whatever you want with it.
