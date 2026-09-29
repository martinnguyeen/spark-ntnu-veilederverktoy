import { Runtime } from '../src/runtime.ts';
import { join } from 'node:path';
const root = process.env.SPARK_TEST_DATA || join(process.env.LOCALAPPDATA!, 'SparkNTNU');
let last = 0;
const runtime = new Runtime(root, p => { if (Date.now() - last > 2000 || ['ready', 'error'].includes(p.phase)) { console.log(`${p.phase}: ${Math.round(p.received / 1048576)} / ${Math.round(p.total / 1048576)} MiB${p.error ? ` — ${p.error}` : ''}`); last = Date.now(); } });
await runtime.start();
if (!runtime.ready) process.exitCode = 1;
