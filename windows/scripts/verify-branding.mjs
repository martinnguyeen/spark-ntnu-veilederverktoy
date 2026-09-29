import { readFile } from 'node:fs/promises';
import { NtExecutable, NtExecutableResource, Resource } from 'resedit';
import assert from 'node:assert/strict';
const exe = NtExecutable.from(await readFile(process.argv[2]));
const resources = NtExecutableResource.from(exe);
const groups = Resource.IconGroupEntry.fromEntries(resources.entries); assert.ok(groups.length);
for (const group of groups) {
  assert.equal(group.icons.length, 4);
  const icons = group.getIconItemsFromEntries(resources.entries);
  for (const icon of icons) {
    const size = icon.width || 256;
    assert.deepEqual(Buffer.from(icon.bin), await readFile(`../Assets/AppIcon.xcassets/AppIcon.appiconset/icon_${size}x${size}.png`));
  }
}
const versions = Resource.VersionInfo.fromEntries(resources.entries); assert.ok(versions.length);
assert.equal(versions[0].getStringValues({ lang: 1033, codepage: 1200 }).ProductName, 'Spark NTNU');
console.log('Branding PASS: all EXE icon groups contain the original Spark PNGs at 16/32/128/256 px; product name Spark NTNU.');
