import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"

import { prototypeListing } from "@/storybook/fixtures/prototype-listing"
import type { PrototypeAuthorResults } from "@utils/prototype-listing/types"

import { PrototypeAuthorFilter } from "."

describe("PrototypeAuthorFilter()", () => {
  it("pins Me first and selects the authenticated-user filter without a separate personal view", async () => {
    const onChange = vi.fn()
    const onSearch = vi.fn<
      (query: string, cursor: string | null, signal: AbortSignal) => Promise<PrototypeAuthorResults>
    >(() =>
      Promise.resolve({
        authors: [{ id: "2", login: "mona", name: "Mona", avatarUrl: null }],
        nextCursor: null,
      }),
    )
    render(
      <PrototypeAuthorFilter listing={prototypeListing} onChange={onChange} onSearch={onSearch} />,
    )
    const trigger = screen.getByRole("button", { name: "Author: All authors" })
    fireEvent.click(trigger)
    const dialog = screen.getByRole("dialog", { name: "Author" })
    expect(within(dialog).getAllByRole("button")[0]).toHaveTextContent("Me")
    expect(within(dialog).getByRole("searchbox")).toHaveFocus()
    expect(await within(dialog).findByRole("button", { name: "@mona (Mona)" })).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Me" }))
    expect(onChange).toHaveBeenCalledExactlyOnceWith("me")
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
    expect(screen.queryByText("My prototypes")).not.toBeInTheDocument()
  })

  it("replaces author option pages and cancels stale searches when the query changes", async () => {
    const onSearch = vi
      .fn<
        (
          query: string,
          cursor: string | null,
          signal: AbortSignal,
        ) => Promise<PrototypeAuthorResults>
      >(() =>
        Promise.resolve({
          authors: [{ id: "2", login: "mona", name: null, avatarUrl: null }],
          nextCursor: "next",
        }),
      )
      .mockResolvedValueOnce({
        authors: [{ id: "1", login: "octocat", name: null, avatarUrl: null }],
        nextCursor: "next",
      })
    render(
      <PrototypeAuthorFilter listing={prototypeListing} onChange={vi.fn()} onSearch={onSearch} />,
    )
    fireEvent.click(screen.getByRole("button", { name: "Author: All authors" }))
    expect(await screen.findByRole("button", { name: "@octocat" })).toBeInTheDocument()
    const firstSignal = onSearch.mock.calls[0]?.[2]
    fireEvent.click(screen.getByRole("button", { name: "Next authors" }))
    expect(await screen.findByRole("button", { name: "@mona" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "@octocat" })).not.toBeInTheDocument()
    expect(firstSignal?.aborted).toBe(true)
    fireEvent.change(screen.getByRole("searchbox"), { target: { value: "mona" } })
    await waitFor(() =>
      expect(onSearch).toHaveBeenLastCalledWith("mona", null, expect.any(AbortSignal)),
    )
    fireEvent.keyDown(screen.getByRole("searchbox"), { key: "Escape" })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(onSearch.mock.calls.at(-1)?.[2].aborted).toBe(true)
  })

  it("reports lookup failures and retries without losing the pinned Me option", async () => {
    const onSearch = vi
      .fn(() => Promise.resolve({ authors: [], nextCursor: null }))
      .mockRejectedValueOnce(new Error("Unavailable"))
    render(
      <PrototypeAuthorFilter listing={prototypeListing} onChange={vi.fn()} onSearch={onSearch} />,
    )
    fireEvent.click(screen.getByRole("button", { name: "Author: All authors" }))
    expect(await screen.findByRole("alert")).toHaveTextContent(prototypeListing.copy.authorsFailed)
    expect(screen.getByRole("button", { name: "Me" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    expect(await screen.findByRole("status")).toHaveTextContent(prototypeListing.copy.loading)
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("No matching authors"))
  })
})
