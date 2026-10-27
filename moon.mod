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

name = "kupas/express"

version = "0.4.0"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/express"

license = "Apache-2.0"

keywords = [
  "express",
  "http",
  "http-server",
  "router",
  "middleware",
  "webserver",
  "uWebSockets",
  "native",
]

preferred_target = "native"

description = "An Express-compatible web framework for native MoonBit, served by µWebSockets (uWebSockets/uSockets bound through a C ABI shim)."
