import { readFile, writeFile } from 'node:fs/promises';
// Package the existing Mac PNGs into a Windows ICO; no logo redraw or image alteration.
const sizes = [16, 32, 128, 256];
const images = await Promise.all(sizes.map(size => readFile(`../Assets/AppIcon.xcassets/AppIcon.appiconset/icon_${size}x${size}.png`)));
const header = Buffer.alloc(6 + 16 * sizes.length); header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4);
let offset = header.length;
for (let i = 0; i < sizes.length; i++) {
  const start = 6 + i * 16; header[start] = sizes[i] === 256 ? 0 : sizes[i]; header[start + 1] = header[start];
  header.writeUInt16LE(1, start + 4); header.writeUInt16LE(32, start + 6); header.writeUInt32LE(images[i].length, start + 8); header.writeUInt32LE(offset, start + 12); offset += images[i].length;
}
await writeFile('dist/spark.ico', Buffer.concat([header, ...images]));
