import { runCommand } from "../run-command/index.mjs"

// Agent skill directories hold local tooling, not prototype source, so they never make a
// prototype checkout "changed". Every other path counts because it cannot be classified safely.
export const LOCAL_SKILL_DIRECTORIES = [".github/skills/", ".agents/skills/", ".claude/skills/"]
export const MAX_LISTED_CHANGES = 20

export async function readWorkingTreeChanges(repositoryPath) {
  const status = await runCommand(
    "git",
    ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    repositoryPath,
  )
  if (!status.ok) return { state: "unavailable", error: status.error }
  return classifyWorkingTreeChanges(status.stdout)
}

export function classifyWorkingTreeChanges(porcelain) {
  const prototype = []
  const localSkills = []
  const entries = porcelain.split("\0")
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index]
    if (entry.length < 4) continue
    const paths = [entry.slice(3)]
    // Renames and copies are followed by their source path.
    if (/[RC]/.test(entry.slice(0, 2))) paths.push(entries[++index] ?? "")
    ;(paths.every(isLocalSkillPath) ? localSkills : prototype).push(paths[0])
  }
  return {
    state: prototype.length ? "changed" : "clean",
    files: { paths: prototype.slice(0, MAX_LISTED_CHANGES), total: prototype.length },
    localSkills: { paths: localSkills.slice(0, MAX_LISTED_CHANGES), total: localSkills.length },
  }
}

function isLocalSkillPath(path) {
  return LOCAL_SKILL_DIRECTORIES.some((directory) => path.startsWith(directory))
}
