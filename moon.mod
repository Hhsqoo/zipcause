// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "Hhsqoo/zipcause"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/Hhsqoo/zipcause"

license = "Apache-2.0"

keywords = [ "zip", "build-tools", "reproducible-builds" ]

preferred_target = "native"

description = "Explain byte differences between two ZIP build artifacts."

import {
  "moonbitlang/x@0.5.5",
  "moonbit-community/flate@0.8.0",
}
