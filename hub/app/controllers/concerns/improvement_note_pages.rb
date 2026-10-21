# Keeps the existing canvas note payload independent of review comment serialization.
module ImprovementNotePages
  private

  # Renders one root and its relational conversation using the existing client contract.
  def improvement_note_json(note)
    can_write = note.editable_by?(Current.user) &&
      @repository.authorization.sufficient?(@repository_permission, minimum: :write)
    {
      id: note.id, kind: "improvement_note", localId: note.local_id,
      revision: note.note_revision, status: note.note_status,
      buildNumber: note.build.number,
      body: note.body, anchor: note.anchor, capture: note.capture,
      thread: note.note_thread,
      deletedAt: note.deleted_at&.iso8601(6),
      createdAt: note.created_at.iso8601(6), updatedAt: note.updated_at.iso8601(6),
      author: author_json(note.user),
      viewerCanEdit: can_write, viewerCanDelete: can_write
    }
  end

  # Selects serialization at the feed boundary, not within either model's behavior.
  def canvas_comment_json(comment)
    comment.is_a?(ImprovementComment) ? improvement_note_json(comment) : review_comment_json(comment)
  end
end
