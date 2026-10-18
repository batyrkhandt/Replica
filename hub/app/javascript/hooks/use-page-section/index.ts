import { useCallback, useContext, useEffect, useState } from "react"
import { NavigationContext, useSuperglue } from "@thoughtbot/superglue"

/** Loads one authorized page section without holding up navigation. */
export function usePageSection(path: string, loadId: string) {
  const { remote } = useContext(NavigationContext)
  const { currentPageKey } = useSuperglue()
  const [attempt, setAttempt] = useState(0)
  const [result, setResult] = useState<{ key: string; failed: boolean } | null>(null)
  const key = `${loadId}:${currentPageKey}:${path}:${attempt}`

  useEffect(() => {
    const controller = new AbortController()
    void remote(path, { pageKey: currentPageKey, signal: controller.signal })
      .then((metadata) => {
        if (!controller.signal.aborted) setResult({ key, failed: metadata.needsRefresh })
      })
      .catch(() => {
        if (!controller.signal.aborted) setResult({ key, failed: true })
      })
    return () => controller.abort()
  }, [currentPageKey, key, path, remote])

  const retry = useCallback(() => setAttempt((previous) => previous + 1), [])
  return {
    loading: result?.key !== key,
    failed: result?.key === key && result.failed,
    retry,
  }
}
