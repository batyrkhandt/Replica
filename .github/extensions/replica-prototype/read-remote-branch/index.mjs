import { runCommand } from "../run-command/index.mjs"
import { gitShaPattern } from "../identity-patterns/index.mjs"

// Matching refs returns [] for a missing branch; authorization/HTTP errors stay unknown.
export async function readRemoteBranch(
  { repository, branch, commitSha, repositoryPath },
  run = runCommand,
) {
  const identity = { repository, branch, commitSha }
  if (!branch)
    return { ...identity, state: "detached", error: "Open a named branch before publishing." }
  if (!repository || !commitSha)
    return {
      ...identity,
      state: "unknown",
      error: "The GitHub origin or checkout commit could not be verified.",
    }
  const result = await run(
    "gh",
    [
      "api",
      "--hostname",
      "github.com",
      `repos/${repository}/git/matching-refs/heads/${encodeURIComponent(branch)}`,
    ],
    repositoryPath,
  )
  if (!result.ok) return { ...identity, state: "unknown", error: result.error }
  let refs
  try {
    refs = JSON.parse(result.stdout)
  } catch {
    return { ...identity, state: "unknown", error: "GitHub returned invalid branch data." }
  }
  if (
    !Array.isArray(refs) ||
    refs.some(
      (ref) =>
        !ref ||
        typeof ref.ref !== "string" ||
        !/^refs\/heads\//.test(ref.ref) ||
        ref.object?.type !== "commit" ||
        !gitShaPattern.test(ref.object?.sha || ""),
    )
  )
    return { ...identity, state: "unknown", error: "GitHub returned invalid branch refs." }
  const exact = refs.find((ref) => ref.ref === `refs/heads/${branch}`)
  return { ...identity, state: exact ? "present" : "absent", remoteSha: exact?.object.sha || null }
}
