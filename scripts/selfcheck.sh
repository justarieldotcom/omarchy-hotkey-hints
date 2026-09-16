#!/usr/bin/bash
# Runs Model.selfCheck() under node (strips the QML-only pragma).
set -euo pipefail
ROOT="$(cd "$(dirname -- "$0")/.." && pwd)"
/usr/bin/node - <<EOF
const fs = require("fs");
const src = fs.readFileSync("$ROOT/Model.js", "utf8").replace(".pragma library", "");
console.assert = (cond, msg) => {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
};
eval(src);
if (selfCheck() !== true) {
  console.error("selfCheck did not return true");
  process.exit(1);
}
console.log("Model.selfCheck ok");
EOF
