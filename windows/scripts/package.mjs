import { cp, mkdir, rename, writeFile, access, readFile } from 'node:fs/promises';
import { NtExecutable, NtExecutableResource, Data, Resource } from 'resedit';
import { join } from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const electronExe = require('electron');
const { dirname } = await import('node:path');
const target = join('release', `SparkNTNU-win32-x64-${Date.now()}`);
await access('dist/main.cjs');
await cp(dirname(electronExe), target, { recursive: true });
await rename(join(target, 'electron.exe'), join(target, 'Spark NTNU.exe'));
const executablePath = join(target, 'Spark NTNU.exe');
const executable = NtExecutable.from(await readFile(executablePath), { ignoreCert: true });
const resources = NtExecutableResource.from(executable);
const icon = Data.IconFile.from(await readFile('dist/spark.ico'));
for (const group of Resource.IconGroupEntry.fromEntries(resources.entries)) Resource.IconGroupEntry.replaceIconsForResource(resources.entries, group.id, group.lang, icon.icons.map(i => i.data));
for (const version of Resource.VersionInfo.fromEntries(resources.entries)) {
  version.setFileVersion(0, 2, 0, 0, 1033); version.setProductVersion(0, 2, 0, 0, 1033);
  version.setStringValues({ lang: 1033, codepage: 1200 }, { FileDescription: 'Spark NTNU veilederverktøy', ProductName: 'Spark NTNU', InternalName: 'SparkNTNU', OriginalFilename: 'Spark NTNU.exe', CompanyName: 'Spark NTNU' });
  version.outputToResourceEntries(resources.entries);
}
resources.outputResource(executable);
await writeFile(executablePath, Buffer.from(executable.generate()));
await mkdir(join(target, 'resources', 'app'), { recursive: true });
await cp('dist', join(target, 'resources', 'app', 'dist'), { recursive: true });
await writeFile(join(target, 'resources', 'app', 'package.json'), JSON.stringify({ name: 'spark-ntnu-windows', productName: 'Spark NTNU', version: '0.2.0', main: 'dist/main.cjs' }, null, 2));
await writeFile(join(target, 'START-HER.txt'), 'Start Spark NTNU.exe. Modellen lastes ned i appen. Dette er en usignert utviklerversjon. Hele mappen må beholdes samlet.\r\n');
console.log(join(process.cwd(), target, 'Spark NTNU.exe'));
