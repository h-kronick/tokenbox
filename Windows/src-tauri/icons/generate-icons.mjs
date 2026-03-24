#!/usr/bin/env node
// Generate minimal placeholder icons for Tauri build
// Creates valid PNG files with amber (#d4b830) on dark (#141310) background

import { writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

const __dirname = dirname(fileURLToPath(import.meta.url));

function createPNG(width, height, r, g, b, bgR, bgG, bgB) {
  // Build raw image data: filter byte + RGB pixels per row
  const rawRows = [];
  const borderSize = Math.max(1, Math.floor(width * 0.15));
  for (let y = 0; y < height; y++) {
    const row = [0]; // filter: None
    for (let x = 0; x < width; x++) {
      const isBorder = x < borderSize || x >= width - borderSize ||
                       y < borderSize || y >= height - borderSize;
      if (isBorder) {
        row.push(bgR, bgG, bgB);
      } else {
        row.push(r, g, b);
      }
    }
    rawRows.push(Buffer.from(row));
  }
  const rawData = Buffer.concat(rawRows);
  const compressed = deflateSync(rawData);

  // PNG signature
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR chunk
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 2;  // color type: RGB
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  const ihdrChunk = makeChunk('IHDR', ihdr);
  const idatChunk = makeChunk('IDAT', compressed);
  const iendChunk = makeChunk('IEND', Buffer.alloc(0));

  return Buffer.concat([signature, ihdrChunk, idatChunk, iendChunk]);
}

function makeChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBuffer = Buffer.from(type, 'ascii');
  const crcData = Buffer.concat([typeBuffer, data]);
  const crc = crc32(crcData);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc >>> 0, 0);
  return Buffer.concat([length, typeBuffer, data, crcBuf]);
}

function crc32(buf) {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < buf.length; i++) {
    crc ^= buf[i];
    for (let j = 0; j < 8; j++) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xEDB88320 : 0);
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function createICO(pngData) {
  // ICO header: 6 bytes
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);    // reserved
  header.writeUInt16LE(1, 2);    // type: ICO
  header.writeUInt16LE(1, 4);    // count: 1 image

  // Directory entry: 16 bytes
  const entry = Buffer.alloc(16);
  entry[0] = 0;    // width (0 = 256)
  entry[1] = 0;    // height (0 = 256)
  entry[2] = 0;    // color palette
  entry[3] = 0;    // reserved
  entry.writeUInt16LE(1, 4);     // color planes
  entry.writeUInt16LE(24, 6);    // bits per pixel
  entry.writeUInt32LE(pngData.length, 8);  // size of PNG data
  entry.writeUInt32LE(22, 12);   // offset to PNG data (6 + 16)

  return Buffer.concat([header, entry, pngData]);
}

// Amber: #d4b830, Dark bg: #141310
const amber = { r: 0xd4, g: 0xb8, b: 0x30 };
const dark = { r: 0x14, g: 0x13, b: 0x10 };

// Generate PNGs
const sizes = [
  { name: 'icon.png', size: 256 },
  { name: '32x32.png', size: 32 },
  { name: '128x128.png', size: 128 },
];

for (const { name, size } of sizes) {
  const png = createPNG(size, size, amber.r, amber.g, amber.b, dark.r, dark.g, dark.b);
  const path = join(__dirname, name);
  writeFileSync(path, png);
  console.log(`Created ${name} (${size}x${size}, ${png.length} bytes)`);
}

// Generate ICO from a 256x256 PNG
const ico256 = createPNG(256, 256, amber.r, amber.g, amber.b, dark.r, dark.g, dark.b);
const ico = createICO(ico256);
const icoPath = join(__dirname, 'icon.ico');
writeFileSync(icoPath, ico);
console.log(`Created icon.ico (${ico.length} bytes)`);
