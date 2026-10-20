require "open3"

# Associates local feedback only after the matching source has become a successful Build.
class Build::DraftReviews < ActiveRecord::AssociatedObject
  # Looks up the immutable commit's tree outside database locks.
  def fetch!(configuration: GithubAppConfiguration.current)
    return unless build.state == "successful"
    return unless build.prototype.draft_review_revisions.where(build_id: nil).exists?

    repository = build.prototype.repository
    if repository.local?
      unless LocalDevelopment.repository_available?(repository.local_path, identity: repository.local_identity)
        raise LocalDevelopment::Error, "The local review repository is unavailable"
      end

      tree, error, status = Open3.capture3("git", "-C", repository.local_path, "rev-parse", "#{build.commit_sha}^{tree}")
      raise LocalDevelopment::Error, "Could not read the published source tree: #{error}" unless status.success?

      tree_sha = tree.strip
    else
      raise GithubClient::Error, "The GitHub App is unavailable" unless configuration&.installation_state == "active"

      commit = configuration.github_client.repositories.commit \
        repository,
        build.commit_sha,
        token: configuration.tokens.installation
      unless commit.is_a?(Hash) && commit["sha"] == build.commit_sha
        raise GithubClient::InvalidResponse, "GitHub returned a different review commit"
      end

      unless commit["commit"].is_a?(Hash) && commit["commit"]["tree"].is_a?(Hash)
        raise GithubClient::InvalidResponse, "GitHub did not return the published source tree"
      end

      tree_sha = commit["commit"]["tree"]["sha"]
    end
    associate!(tree_sha:)
  end

  # Keeps existing threads intact and never associates an already-published older Build.
  def associate!(tree_sha:)
    unless tree_sha.is_a?(String) && Build::COMMIT_SHA_FORMAT.match?(tree_sha)
      raise GithubClient::InvalidResponse, "The published source tree is invalid"
    end

    prototype = build.prototype
    changed = prototype.with_lock do
      build.reload
      return unless build.state == "successful"

      revisions = prototype.draft_review_revisions.where \
        build_id: nil,
        tree_sha:,
        created_at: ..build.finished_at
      ids = revisions.ids
      revisions.update_all(build_id: build.id, updated_at: Time.current)
      ReviewComment.roots.where(draft_review_revision_id: ids, build_id: nil)
        .update_all(build_id: build.id, updated_at: Time.current)
      ids.any?
    end
    ReviewCommentsChannel.broadcast_invalidation(prototype) if changed
  end
end
