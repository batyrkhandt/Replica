class AddNoteThreadToReviewComments < ActiveRecord::Migration[8.1]
  def change
    add_column :review_comments, :note_thread, :json
    add_check_constraint :review_comments,
      "note_thread IS NULL OR (kind = 'improvement_note' AND " \
      "CASE WHEN json_valid(note_thread) THEN json_type(note_thread) = 'object' ELSE 0 END AND " \
      "length(CAST(note_thread AS BLOB)) BETWEEN 2 AND 32768)",
      name: "review_comments_note_thread"
  end
end
