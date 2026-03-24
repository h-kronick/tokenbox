# TokenBox Icons

Tauri 2 requires the following icon files in this directory:

| File | Size | Format | Usage |
|------|------|--------|-------|
| `icon.png` | 512x512 | PNG | Default app icon |
| `32x32.png` | 32x32 | PNG | Small icon / system tray |
| `128x128.png` | 128x128 | PNG | Medium icon |
| `128x128@2x.png` | 256x256 | PNG | Retina medium icon |
| `icon.ico` | Multi-size | ICO | Windows executable icon (contains 16x16, 32x32, 48x48, 256x256) |

## Design Spec

- **Monogram:** "TB" centered on the icon
- **Background:** `#141310` (Classic Amber dark background)
- **Text color:** `#d4b830` (Amber/gold)
- **Font:** Bold monospace or industrial/mechanical style
- **Shape:** Rounded rectangle with ~12% corner radius
- **Style:** Clean, minimal — matches the split-flap display aesthetic

## Generating Icons

Create the 512x512 `icon.png` first, then derive the other sizes:

```bash
# Using ImageMagick to resize from the base icon
magick icon.png -resize 32x32 32x32.png
magick icon.png -resize 128x128 128x128.png
magick icon.png -resize 256x256 128x128@2x.png

# Generate ICO with multiple sizes embedded
magick icon.png -define icon:auto-resize=256,48,32,16 icon.ico
```

Alternatively, use https://tauri.app/start/prerequisites/#icons or `cargo tauri icon icon.png` to auto-generate all required sizes from a single source PNG.
