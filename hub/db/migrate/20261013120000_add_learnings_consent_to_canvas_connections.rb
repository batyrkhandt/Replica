class AddLearningsConsentToCanvasConnections < ActiveRecord::Migration[8.1]
  def change
    add_column :canvas_pairings, :learnings_consented_at, :datetime
    add_column :canvas_grants, :learnings_consented_at, :datetime
    add_check_constraint \
      :canvas_pairings,
      "learnings_consented_at IS NULL OR approved_at IS NOT NULL",
      name: "canvas_pairings_learnings_consent"
  end
end
