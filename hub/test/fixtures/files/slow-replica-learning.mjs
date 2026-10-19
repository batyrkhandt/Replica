// Stands in for a replica-learning recall that answers after ten seconds, longer than Hub waits. A
// process outside its process group, as a runtime that escaped it would be, keeps its output open
// for a few seconds, so Hub also waits its whole stop time after it ends the command.
import { spawn } from "node:child_process"

spawn(process.execPath, ["-e", "setTimeout(() => {}, 4000)"], {
  detached: true,
  stdio: ["ignore", "inherit", "inherit"],
}).unref()
setTimeout(() => process.stdout.write(JSON.stringify({ text: "", memories: [] })), 10_000)
