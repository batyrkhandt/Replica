export function runCommand(
  command: string,
  args: string[],
  cwd?: string,
  options?: { env?: Record<string, string | undefined> },
): Promise<
  | { ok: true; stdout: string }
  | {
      ok: false
      error: string
      exitCode?: string | number
      stdout?: string
      stderr?: string
    }
>
