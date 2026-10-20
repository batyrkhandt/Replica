export interface PrototypeAuthor {
  id: string
  login: string
  name: string | null
  avatarUrl: string | null
}

export interface PrototypeAuthorResults {
  authors: PrototypeAuthor[]
  nextCursor: string | null
}

export interface PrototypeListingControls {
  query: string
  pending: boolean
  error: boolean
  onQueryChange: (query: string) => void
  onQuerySubmit: () => void
  onAuthorChange: (author: string) => void
  onClearFilters: () => void
  onNavigate: (path: string) => void
  onRetry: () => void
  loadAuthors: (
    query: string,
    cursor: string | null,
    signal: AbortSignal,
  ) => Promise<PrototypeAuthorResults>
}

export interface PrototypeListing {
  query: string
  author: string
  authorLabel: string
  matchingCount: number
  previousPath: string | null
  nextPath: string | null
  newestPath: string | null
  authorsPath: string
  path: string
  copy: {
    author: string
    me: string
    allAuthors: string
    searchAuthors: string
    moreAuthors: string
    firstAuthors: string
    noAuthors: string
    loading: string
    retry: string
    authorsFailed: string
    resultsFailed: string
    clearFilters: string
    previous: string
    next: string
    newest: string
    pagination: string
    updating: string
    shown: string
  }
}
