#!/usr/bin/env node
// ============================================================
// UniPortal — build step
// ------------------------------------------------------------
// app.html can compile app.jsx in the browser with Babel standalone, which
// works but costs ~3 MB of CDN payload and a multi-second compile on every
// cold visit. This script does that work once, ahead of time:
//
//   app.jsx + the feature modules  ->  app.bundle.js  (esbuild, minified)
//
// The concatenation mirrors app.html's runtime loader exactly: the feature
// modules are spliced into app.jsx's module scope at its __FEATURES__ marker,
// so they keep sharing one scope.
//
// React / react-dom / lucide-react / recharts stay external — the import map
// in app.html resolves them from esm.sh, same as the no-build path.
//
// Usage:  npm run build     (the Pages workflow runs this before deploying)
// ============================================================
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import * as esbuild from 'esbuild';

const root = dirname(fileURLToPath(import.meta.url));

const FEATURE_FILES = [
  'features/data-layer.jsx',
  'features/knowledge-base.jsx',
  'features/feed.jsx',
  'features/programs.jsx',
  'features/assistant.jsx',
  'features/registrations.jsx',
];

const EXTERNALS = [
  'react', 'react-dom', 'react-dom/client',
  'lucide-react', 'recharts', 'motion', 'motion/react',
];

let src = readFileSync(join(root, 'app.jsx'), 'utf8');
const features = FEATURE_FILES.map((f) => readFileSync(join(root, f), 'utf8')).join('\n\n');
src = src.includes('/*__FEATURES__*/')
  ? src.replace('/*__FEATURES__*/', features)
  : src + '\n\n' + features;

// esbuild infers the loader from the extension, so stage the combined source
// as .tsx (app.jsx contains both TypeScript annotations and JSX).
const entry = join(root, '.app.build.tsx');
writeFileSync(entry, src);

try {
  const result = await esbuild.build({
    entryPoints: [entry],
    outfile: join(root, 'app.bundle.js'),
    bundle: true,
    format: 'esm',
    target: 'es2020',
    jsx: 'transform', // classic runtime — React is imported at the top of app.jsx
    minify: true,
    external: EXTERNALS,
    logOverride: { 'duplicate-object-key': 'silent' }, // known dupes in the HU→EN table
    metafile: true,
  });
  const bytes = Object.values(result.metafile.outputs)[0].bytes;
  console.log(`app.bundle.js  ${(bytes / 1024).toFixed(1)} kB`);
} finally {
  rmSync(entry, { force: true });
}
