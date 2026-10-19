# Gives an agent the learnings its repository's administrators accepted.
#
# The Replica plugin asks with each prompt a person submits. It never sends the prompt, so recall
# orders the learnings by how many prototypes and reviewers raised them, then by when they were
# accepted. This answers from the cached read permission and returns empty text when there is
# nothing to give. It names each learning it gives by ID and content digest, so the plugin can tell
# when they change. The store records each recall as a use by the person the agent works for.
class CanvasApi::LearningRecallsController < CanvasApi::BaseController
  # The plugin stops waiting after three seconds. Ending a recall can take Learning::Command's
  # STOP_TIME more, so Hub ends a slower one, such as one waiting for a busy store, early enough to
  # answer within those three seconds.
  TIMEOUT = 1.5.seconds

  # Each recall starts a replica-learning process, so Hub limits how often one connection can ask.
  before_action -> { enforce_security_rate_limit(:learning_recalls, identity: Current.canvas_grant.id) }

  # @route POST /api/canvas/learnings/recall (canvas_api_learnings_recall)
  def create
    # A connection approved before the approval page mentioned learnings never agreed to them.
    return render json: { code: "learnings_consent_required" }, status: :forbidden if Current.canvas_grant.learnings_consented_at.nil?

    # The code tells the plugin that no learnings apply, unlike a 404 from a Hub without this route.
    return render json: { code: "learnings_off" }, status: :not_found if !Learning.available_for?(@repository)

    store = Learning::Store.new(@repository)
    return render json: { text: "", memories: [] } if !store.exist?

    result = store.call("recall", "--actor", Learning.person_for(Current.user), timeout: TIMEOUT)
    memories = result.fetch("memories").map { { id: _1.fetch("id"), digest: _1.fetch("contentDigest") } }
    render json: { text: memories.empty? ? "" : result.fetch("text"), memories: }
  rescue Learning::Error, KeyError, TypeError, NoMethodError
    head :service_unavailable
  end

  private

  # Recall only reads, so a recently confirmed read permission is enough, as for GET requests.
  def fresh_permission?
    false
  end
end
