import type { ReviewAnchor } from "@utils/review-anchor/types"

export type Route = string
export type Rect = { x: number; y: number; width: number; height: number }
export type Target = {
  id: string
  label: string
  route: Route
  rect: Rect
}
export type Note = {
  id: number
  kind: "improvement_note"
  author: string
  authorProfile?: { id: number; login: string; avatarUrl: string | null }
  localId?: string
  result?: string
  body: string
  route: Route
  target: string
  selector: string | null
  rect: Rect
  capture: string
  anchor?: ReviewAnchor
  capturePlaceholder?: boolean
  status: "open" | "sent" | "ready" | "resolved" | "blocked"
  sync: "local" | "synced" | "failed"
  revision: number
  thread?: {
    version: 1 | 2
    originalAuthor?: { id: number; login: string; avatarUrl: string | null }
    originalStatus: "open" | "sent" | "ready" | "blocked"
    messages: (
      | {
          id: string
          role: "author"
          body: string
          status: "open" | "sent" | "ready" | "blocked"
          author?: { id: number; login: string; avatarUrl: string | null }
        }
      | {
          id: string
          role: "copilot"
          body: string
          status: "ready" | "blocked"
          requestIds: string[]
        }
    )[]
  }
}
export type Selection = Pick<
  Note,
  "route" | "target" | "selector" | "rect" | "capture" | "anchor" | "capturePlaceholder"
> & { identity?: string; noteRevision?: number; originalBody?: string }
