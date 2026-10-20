import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { HubCounter } from "."
import styles from "./styles.css?inline"

describe("HubCounter()", () => {
  it("preserves exact counts and caller accessibility attributes", () => {
    render(
      <HubCounter className="pending" aria-label="27 pending requests">
        {27}
      </HubCounter>,
    )
    expect(screen.getByLabelText("27 pending requests")).toHaveTextContent("27")
    expect(screen.getByLabelText("27 pending requests")).toHaveClass("hub-counter", "pending")
  })

  it("supports a scoped background while retaining its default and inherited foreground", () => {
    expect(styles).toContain(
      "background: var(--hub-counter-background, color-mix(in srgb, currentColor 10%, Canvas))",
    )
    expect(styles).toContain("color: inherit")
  })
})
