import { Button, Checkbox, FormControl, Stack } from "@primer/react-brand"
import { useId, useState, type RefObject } from "react"

import { HubAlert } from "@components/hub-alert"

import { CanvasDialog } from "../prototype-canvas-dialog"
import type { PublishMode, PublishPreparation } from "@utils/prototype-canvas/types"
import { publishChangesCopy as copy } from "@hooks/use-canvas-publish-preference/en"

import "./styles.css"

export function PublishChangesDialog({
  busy,
  error,
  changes,
  remembered,
  returnFocusRef,
  onClose,
  onChoose,
}: {
  busy: boolean
  error: string
  changes?: PublishPreparation["changes"]
  remembered: boolean
  returnFocusRef: RefObject<HTMLButtonElement | null>
  onClose: () => void
  onChoose: (mode: PublishMode, remember: boolean) => void
}) {
  const [remember, setRemember] = useState(remembered)
  const descriptionId = useId()
  const checkboxId = useId()
  return (
    <CanvasDialog
      title={copy.title}
      closeLabel={copy.close}
      descriptionId={descriptionId}
      returnFocusRef={returnFocusRef}
      onClose={() => {
        if (!busy) onClose()
      }}
      className="publish-changes-dialog"
    >
      <Stack gap="normal" padding="none">
        <p id={descriptionId}>{copy.description}</p>
        {changes?.files.total ? (
          <section aria-label={copy.changedFiles}>
            <ul className="publish-changes-dialog__files">
              {changes.files.paths.map((file) => (
                <li key={file}>
                  <code>{file}</code>
                </li>
              ))}
              {changes.files.total > changes.files.paths.length ? (
                <li>{copy.moreChanges(changes.files.total - changes.files.paths.length)}</li>
              ) : null}
            </ul>
          </section>
        ) : null}
        <p>
          {changes?.localSkills.total ? `${copy.localSkills(changes.localSkills.total)} ` : null}
          {copy.selection}
        </p>
        <FormControl id={checkboxId} fullWidth>
          <Checkbox
            checked={remember}
            disabled={busy}
            onChange={(event) => setRemember(event.target.checked)}
          />
          <FormControl.Label>{copy.remember}</FormControl.Label>
        </FormControl>
        {error ? <HubAlert title={error} variant="critical" layout="compact" /> : null}
        <footer className="publish-changes-dialog__actions">
          <Button
            variant="primary"
            size="small"
            disabled={busy}
            aria-busy={busy}
            onClick={() => onChoose("commit-changes", remember)}
          >
            {copy.commit}
          </Button>
          <Button size="small" disabled={busy} onClick={() => onChoose("committed-only", false)}>
            {copy.committed}
          </Button>
        </footer>
      </Stack>
    </CanvasDialog>
  )
}
