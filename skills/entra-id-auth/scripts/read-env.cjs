// read-env.cjs <file> <KEY>: prints every value KEY takes in <file>, one per
// line, in file order, read the way dotenv (and so Next.js) reads it: CRLF,
// `export `, quotes and ` # comments` handled; the last line wins at run time.
// read-env.cjs <file> --keys: prints every key the file sets, one per line.
// A value is never printed by the scripts that call this; they only test it.
"use strict";
const fs = require("fs");
const [file, key] = process.argv.slice(2);
// dotenv 16's own line pattern (lib/main.js).
const LINE = /(?:^|^)\s*(?:export\s+)?([\w.-]+)(?:\s*=\s*?|:\s+?)(\s*'(?:\\'|[^'])*'|\s*"(?:\\"|[^"])*"|\s*`(?:\\`|[^`])*`|[^#\r\n]+)?\s*(?:#.*)?(?:$|$)/gm;
let src = "";
try { src = fs.readFileSync(file, "utf8"); } catch { process.exit(0); }
src = src.replace(/\r\n?/gm, "\n");
const out = [];
let m;
while ((m = LINE.exec(src)) !== null) {
  if (key === "--keys") { out.push(m[1]); continue; }
  if (m[1] !== key) continue;
  let v = (m[2] || "").trim();
  const q = v[0];
  v = v.replace(/^(['"`])([\s\S]*)\1$/gm, "$2");
  if (q === '"') v = v.replace(/\\n/g, "\n").replace(/\\r/g, "\r");
  // One value per output line; a line break inside a value makes it unusable
  // as a local URL anyway, so it is kept visible as a space.
  out.push(v.replace(/[\r\n]/g, " "));
}
if (out.length) process.stdout.write(out.join("\n") + "\n");
