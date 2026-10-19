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
    const menu = screen.getByRole("menu", { name: "Author" })
    expect(within(menu).getAllByRole("menuitemradio")[0]).toHaveTextContent("Me")
    expect(within(menu).getByRole("searchbox")).toHaveFocus()
    expect(
      await within(menu).findByRole("menuitemradio", { name: "@mona (Mona)" }),
    ).toBeInTheDocument()
    expect(
      within(menu).getByRole("menuitemradio", { name: "All authors", checked: true }),
    ).toBeInTheDocument()
    fireEvent.click(within(menu).getByRole("menuitemradio", { name: "Me" }))
    expect(onChange).toHaveBeenCalledExactlyOnceWith("me")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
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
    expect(await screen.findByRole("menuitemradio", { name: "@octocat" })).toBeInTheDocument()
    const firstSignal = onSearch.mock.calls[0]?.[2]
    fireEvent.click(screen.getByRole("button", { name: "Next authors" }))
    expect(await screen.findByRole("menuitemradio", { name: "@mona" })).toBeInTheDocument()
    expect(screen.queryByRole("menuitemradio", { name: "@octocat" })).not.toBeInTheDocument()
    expect(firstSignal?.aborted).toBe(true)
    fireEvent.change(screen.getByRole("searchbox"), { target: { value: "mona" } })
    await waitFor(() =>
      expect(onSearch).toHaveBeenLastCalledWith("mona", null, expect.any(AbortSignal)),
    )
    fireEvent.keyDown(screen.getByRole("searchbox"), { key: "Escape" })
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
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
    expect(screen.getByRole("menuitemradio", { name: "Me" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    expect(await screen.findByRole("status")).toHaveTextContent(prototypeListing.copy.loading)
    await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("No matching authors"))
  })

  it.each([
    ["Me", " ", "me"],
    ["All authors", "Enter", ""],
  ])("selects %s once with the keyboard and restores trigger focus", (name, key, value) => {
    const onChange = vi.fn()
    render(
      <PrototypeAuthorFilter
        listing={prototypeListing}
        onChange={onChange}
        onSearch={() => Promise.resolve({ authors: [], nextCursor: null })}
      />,
    )
    const trigger = screen.getByRole("button", { name: "Author: All authors" })
    fireEvent.click(trigger)
    fireEvent.keyDown(screen.getByRole("searchbox"), { key: "ArrowDown" })
    expect(screen.getByRole("menuitemradio", { name: "Me" })).toHaveFocus()
    const option = screen.getByRole("menuitemradio", { name })
    option.focus()
    fireEvent.keyDown(option, { key })
    expect(onChange).toHaveBeenCalledExactlyOnceWith(value)
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })
})
