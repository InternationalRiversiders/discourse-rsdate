# frozen_string_literal: true
module DiscourseRsdate
  module UserLifecycle
    def self.export(id)
      # Only the requesting user's own answers and records, never a partner's profile or answers.
      {exported_at: Time.current.iso8601, profile: Profile.find_by(user_id: id)&.as_json, submissions: Submission.where(user_id: id).as_json, matches: Match.where(user_id: id).map { |m| m.as_json.merge('details' => m.details.except('note')) }}
    end
    def self.purge(id)
      return unless Profile.table_exists?
      Record.transaction do
        Shared.lock('matching-pool')
        # Remove archived answers through their submission foreign keys as well as direct identities.
        submissions = Legacy.where(source: %w[QuestionnaireSubmission QuestionnaireModuleSubmission]).where("data->>'externalUserId' = ?", id.to_s).pluck(:legacy_id)
        Legacy.where("data->>'submissionId' IN (?)", submissions).delete_all if submissions.any?
        Legacy.where("data->>'externalUserId' = ? OR data->>'userExternalId' = ? OR data->>'matchedUserExternalId' = ?", id.to_s, id.to_s, id.to_s).delete_all
        Legacy.where("data->>'createdByExternalId' = ? OR data->>'publishedByExternalId' = ? OR data->>'triggeredByExternalId' = ?", id.to_s, id.to_s, id.to_s).find_each do |row|
          row.update!(data: row.data.except('createdByExternalId', 'publishedByExternalId', 'triggeredByExternalId'))
        end
        matches = Match.where('user_id = ? OR partner_id = ?', id, id)
        Legacy.where(target_kind: 'Match', target_id: matches.pluck(:id)).delete_all
        matches.delete_all
        [Profile, Submission, Command, Event].each { |klass| klass.where(user_id: id).delete_all }
        # Previews contain identities in rendered pairs; expire them on account erasure.
        Run.delete_all
        Audit.where(user_id: id).update_all(user_id: Discourse.system_user.id)
        Publication.where(user_id: id).update_all(user_id: nil)
        Questionnaire.where(created_by_id: id).update_all(created_by_id: nil)
        Match.where(published_by_id: id).update_all(published_by_id: nil)
        Notification.where(user_id: id, notification_type: Notification.types[:custom]).where("data::jsonb->>'river_app' = 'rsdate'").destroy_all
      end
    end
    def self.merge(source, target)
      # Consent/preferences must not be transferred to a different account implicitly.
      # Retain the destination account's own RSDate data and remove the source's private data.
      purge(source.id)
    end
  end
end
DiscourseEvent.on(:user_destroyed) { |user| DiscourseRsdate::UserLifecycle.purge(user.id) }
DiscourseEvent.on(:user_anonymized) { |user:, **_| DiscourseRsdate::UserLifecycle.purge(user.id) }
DiscourseEvent.on(:merging_users) { |source, target| DiscourseRsdate::UserLifecycle.merge(source, target) }
