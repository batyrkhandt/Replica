export function readErrorCode(error: unknown): string | number | undefined {
  if (typeof error !== "object" || error === null || !("code" in error)) return undefined
  return typeof error.code === "string" || typeof error.code === "number" ? error.code : undefined
}
