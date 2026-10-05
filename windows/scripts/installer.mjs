import { build, Platform, Arch } from 'electron-builder';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

process.chdir(resolve(dirname(fileURLToPath(import.meta.url)), '..'));
for (const script of ['build.mjs', 'package.mjs']) {
  const result = spawnSync(process.execPath, [`scripts/${script}`], { encoding: 'utf8', windowsHide: true });
  process.stdout.write(result.stdout ?? ''); process.stderr.write(result.stderr ?? '');
  if (result.status !== 0) throw new Error(`${script} failed: ${result.error ?? result.status}`);
  if (script === 'package.mjs') {
    const executable = result.stdout.trim().split(/\r?\n/).at(-1);
    await build({
      targets: Platform.WINDOWS.createTarget('nsis', Arch.x64),
      prepackaged: dirname(executable),
      publish: 'never',
      config: {
        appId: 'no.spark.ntnu.windows',
        productName: 'Spark NTNU',
        executableName: 'Spark NTNU',
        directories: { output: 'release/installer' },
        artifactName: 'Spark-NTNU-Windows-x64-${version}-Setup.${ext}',
        win: { icon: 'dist/spark.ico', signAndEditExecutable: false },
        nsis: {
          oneClick: false,
          perMachine: false,
          allowElevation: false,
          allowToChangeInstallationDirectory: true,
          createDesktopShortcut: true,
          createStartMenuShortcut: true,
          runAfterFinish: true,
          deleteAppDataOnUninstall: false,
          installerIcon: 'dist/spark.ico',
          uninstallerIcon: 'dist/spark.ico',
          include: 'scripts/installer.nsh',
        },
      },
    });
  }
}
