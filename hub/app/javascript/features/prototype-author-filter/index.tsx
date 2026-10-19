import { useEffect, useId, useRef, useState } from "react"

import { CheckIcon, ChevronDownIcon } from "@primer/octicons-react"
import { Button, TextInput } from "@primer/react-brand"

import type { PrototypeAuthorResults, PrototypeListing } from "@utils/prototype-listing/types"

import "./styles.css"

/** Offers Me first and searches bounded pages of this repository's registration authors. */
export function PrototypeAuthorFilter({
  listing,
  onChange,
  onSearch,
}: {
  listing: PrototypeListing
  onChange: (author: string) => void
  onSearch: (
    query: string,
    cursor: string | null,
    signal: AbortSignal,
  ) => Promise<PrototypeAuthorResults>
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState("")
  const [cursor, setCursor] = useState<string | null>(null)
  const [results, setResults] = useState<PrototypeAuthorResults | null>(null)
  const [failed, setFailed] = useState(false)
  const [retry, setRetry] = useState(0)
  const wrapper = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const id = useId()
  const copy = listing.copy

  useEffect(() => {
    if (!open) return

    input.current?.focus()
    function dismiss(event: PointerEvent) {
      if (event.target instanceof Node && !wrapper.current?.contains(event.target)) setOpen(false)
    }
    document.addEventListener("pointerdown", dismiss)
    return () => document.removeEventListener("pointerdown", dismiss)
  }, [open])

  useEffect(() => {
    if (!open) return

    const controller = new AbortController()
    const timer = setTimeout(() => {
      onSearch(query, cursor, controller.signal).then(
        (value) => {
          if (!controller.signal.aborted) setResults(value)
        },
        () => {
          if (!controller.signal.aborted) setFailed(true)
        },
      )
    }, 200)
    return () => {
      clearTimeout(timer)
      controller.abort()
    }
  }, [open, query, cursor, retry, onSearch])

  function select(value: string) {
    setOpen(false)
    trigger.current?.focus()
    onChange(value)
  }

  return (
    <div
      className="prototype-author-filter"
      ref={wrapper}
      onKeyDown={(event) => {
        if (event.key === "Escape" && open) {
          event.preventDefault()
          event.stopPropagation()
          setOpen(false)
          trigger.current?.focus()
        }
      }}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false)
      }}
    >
      <Button
        ref={trigger}
        variant="secondary"
        size="small"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        trailingVisual={<ChevronDownIcon size={16} />}
        onClick={() => {
          setResults(null)
          setFailed(false)
          setOpen(!open)
        }}
      >
        {copy.author}: {listing.authorLabel}
      </Button>

      {open ? (
        <div
          id={id}
          role="dialog"
          aria-label={copy.author}
          className="prototype-author-filter__popup"
        >
          <TextInput
            ref={input}
            fullWidth
            type="search"
            aria-label={copy.searchAuthors}
            placeholder={copy.searchAuthors}
            value={query}
            maxLength={200}
            onChange={(event) => {
              setQuery(event.target.value)
              setCursor(null)
              setResults(null)
              setFailed(false)
            }}
          />

          <div className="prototype-author-filter__choices">
            <Button
              variant="subtle"
              size="small"
              aria-pressed={listing.author === "me"}
              onClick={() => select("me")}
              leadingVisual={listing.author === "me" ? <CheckIcon size={16} /> : undefined}
            >
              {copy.me}
            </Button>
            <Button
              variant="subtle"
              size="small"
              aria-pressed={!listing.author}
              onClick={() => select("")}
            >
              {copy.allAuthors}
            </Button>

            <div aria-busy={!results && !failed}>
              {failed ? (
                <div role="alert">
                  <p>{copy.authorsFailed}</p>
                  <Button
                    size="small"
                    variant="subtle"
                    onClick={() => {
                      setFailed(false)
                      setRetry((value) => value + 1)
                    }}
                  >
                    {copy.retry}
                  </Button>
                </div>
              ) : !results ? (
                <p role="status">{copy.loading}</p>
              ) : !results.authors.length ? (
                <p role="status">{copy.noAuthors}</p>
              ) : (
                results.authors.map((author) => (
                  <Button
                    key={author.id}
                    variant="subtle"
                    size="small"
                    aria-pressed={listing.author === author.id}
                    onClick={() => select(author.id)}
                  >
                    @{author.login}
                    {author.name ? ` (${author.name})` : ""}
                  </Button>
                ))
              )}
            </div>

            {results?.nextCursor ? (
              <Button
                variant="subtle"
                size="small"
                onClick={() => {
                  setCursor(results.nextCursor)
                  setResults(null)
                  input.current?.focus()
                }}
              >
                {copy.moreAuthors}
              </Button>
            ) : null}
            {cursor ? (
              <Button
                variant="subtle"
                size="small"
                onClick={() => {
                  setCursor(null)
                  setResults(null)
                  setFailed(false)
                  input.current?.focus()
                }}
              >
                {copy.firstAuthors}
              </Button>
            ) : null}
          </div>
        </div>
      ) : null}
    </div>
  )
}
