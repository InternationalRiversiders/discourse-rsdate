# frozen_string_literal: true
require 'digest'
module DiscourseRsdate
  class Importer
    def initialize(payload, **_)
      @payload = payload; @tables = payload.fetch('tables')
      raise Error, '导出文件格式或项目不符' unless payload['format'] == 'riverside-community-v1' && payload['project'] == 'rsdate'
    end
    def rows(name) = @tables[name] || []
    def ref(source, id) = Legacy.find_by!(source: source, legacy_id: id.to_s).target_id
    def user(id, optional: false)
      return nil if optional && (id.blank? || id == 'system')
      uid = Integer(id.to_s, 10) rescue nil
      raise Error, '导入包含未映射的论坛用户，请先核对身份映射' unless uid && User.exists?(uid)
      uid
    end
    def time(value) = value.present? ? Time.iso8601(value) : nil
    def stamp(row)
      {created_at: time(row['createdAt']), updated_at: time(row['updatedAt'])}.compact
    end
    def put(source, row, klass, attrs)
      item = klass.create!(stamp(row).merge(attrs))
      Legacy.find_by!(source: source, legacy_id: row.fetch('id').to_s).update!(target_kind: klass.name.demodulize, target_id: item.id)
      item
    end
    def run(sha:, apply: false, expected_sha: nil)
      raise Error, '正式导入需要匹配的 SHA256' if apply && sha != expected_sha
      raise Error, '正式导入前请关闭插件' if apply && SiteSetting.rsdate_enabled
      result = nil
      Record.transaction do
        Shared.lock('matching-pool'); Shared.lock('legacy-import')
        existing = Legacy.find_by(source: '__manifest', legacy_id: sha)
        if existing
          result = {already_imported: true, sha256: sha, counts: existing.data['counts']}; next
        end
        tables = Record.connection.tables.grep(/\Ariver_rsdate_/)
        occupied = tables.any? { |table| Record.connection.select_value("SELECT EXISTS(SELECT 1 FROM #{Record.connection.quote_table_name(table)})") }
        raise Error, '目标插件已有业务数据，请使用空的隔离目标演练' if occupied
        @tables.each do |source, records|
          raise Error, '记录列表无效' unless records.is_a?(Array)
          records.each { |row| Legacy.create!(source: source, legacy_id: row.fetch('id').to_s, data: row) }
        end
        import_domain
        counts = tables.to_h { |table| [table, Record.connection.select_value("SELECT COUNT(*) FROM #{Record.connection.quote_table_name(table)}").to_i] }
        result = {sha256: sha, apply: apply, source_counts: @tables.transform_values(&:size), counts: counts}
        Legacy.create!(source: '__manifest', legacy_id: sha, data: result)
        Record.connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
        raise ActiveRecord::Rollback unless apply
      end
      result
    end
    def import_domain
      rows('UserProfile').each do |r|
        put('UserProfile', r, Profile, {user_id: user(r['externalUserId']), nickname: r['nickname'], gender: r['gender'], target_gender: r['targetGender'], school: r['school'], campus: r['campus'], grade: r['grade'], mbti: r['mbti'], zodiac: r['zodiac'], interests: r['interests'], schedule: r['schedule'], bio: r['bio'], active: !!r['activeForMatching'], embedding: r['freeTextEmbedding'], embedding_model: r['embeddingModel'], embedding_updated_at: time(r['embeddingUpdatedAt']), last_published_cycle_key: r['lastPublishedCycleKey'], last_published_at: time(r['lastPublishedAt'])})
      end
      rows('QuestionnaireModule').each do |r|
        questions = rows('QuestionnaireModuleQuestion').select { |q| q['moduleId'] == r['id'] }.sort_by { |q| q['orderIndex'] }.map do |q|
          {'id' => q['id'], 'prompt' => q['prompt'], 'description' => q['description'], 'order' => q['orderIndex'], 'options' => rows('QuestionnaireModuleOption').select { |o| o['questionId'] == q['id'] }.sort_by { |o| o['orderIndex'] }.map { |o| {'id' => o['id'], 'label' => o['label'], 'value' => o['value'], 'order' => o['orderIndex']} }}
        end
        put('QuestionnaireModule', r, Questionnaire, {title: r['title'], description: r['description'], required: !!r['isRequiredForMatching'], position: r['orderIndex'], questions: questions, created_by_id: user(r['createdByExternalId'], optional: true)})
      end
      rows('QuestionnaireModuleSubmission').each do |r|
        q = Questionnaire.find(ref('QuestionnaireModule', r['moduleId']))
        answers = rows('QuestionnaireModuleAnswer').select { |a| a['submissionId'] == r['id'] }.to_h { |a| [a['questionId'].to_s, a['optionId'].to_s] }
        fresh = time(r['submittedAt']) && time(r['submittedAt']) >= q.updated_at && q.questions.size == answers.size
        put('QuestionnaireModuleSubmission', r, Submission, {user_id: user(r['externalUserId']), questionnaire_id: q.id, revision: fresh ? q.revision : 0, answers: answers, submitted_at: time(r['submittedAt'])})
      end
      rows('MatchPublication').each do |r|
        put('MatchPublication', r, Publication, {cycle_key: r['cycleKey'], user_id: user(r['triggeredByExternalId'], optional: true), mode: r['mode'], pool_size: r['poolSize'], pair_count: r['pairCount'], unmatched_count: r['unmatchedCount'], created_at: time(r['publishedAt'])})
      end
      histories = rows('MatchResultHistory').dup
      signature = ->(r) { [r['userExternalId'], r['matchedUserExternalId'], time(r['publishedAt'])] }
      rows('MatchResult').each do |r|
        unless histories.any? { |h| signature.call(h) == signature.call(r) }
          copy = r.merge('id' => "current-#{r['id']}")
          Legacy.create!(source: 'MatchResultHistory', legacy_id: copy['id'], data: copy); histories << copy
        end
      end
      histories.sort_by { |r| [time(r['publishedAt']), r['id']] }.each do |r|
        published = time(r['publishedAt'])
        # Early histories predate cycle keys; associate with the publication timestamp when possible.
        pub = r['publicationCycleKey'].present? ? Publication.find_by(cycle_key: r['publicationCycleKey']) : Publication.find_by(created_at: published)
        pub ||= Publication.find_or_create_by!(cycle_key: r['publicationCycleKey'].presence || "legacy-#{published.iso8601(6)}") { |p| p.mode = 'legacy'; p.pool_size = 0; p.pair_count = 0; p.created_at = published }
        currents = rows('MatchResult').select { |c| signature.call(c) == signature.call(r) }
        uid = user(r['userExternalId']); partner = user(r['matchedUserExternalId'])
        raise Error, '同一用户存在重复的当前匹配' if currents.any? && Match.exists?(user_id: uid, current: true)
        raw_modules = r['moduleSimilarityJson'].present? ? JSON.parse(r['moduleSimilarityJson']) : []
        details = {'modules' => raw_modules.map { |m| {'module_id' => m['moduleId'], 'title' => m['moduleTitle'], 'count' => m['comparableCount'], 'same' => m['sameCount'], 'near' => m['nearCount'], 'score' => m['score'], 'summary' => m['summary']} }, 'note' => r['adminNote']}
        item = put('MatchResultHistory', r, Match, {publication_id: pub.id, user_id: uid, partner_id: partner, current: currents.any?, details: details, published_at: published, published_by_id: user(r['publishedByExternalId'], optional: true)})
        currents.each { |c| Legacy.find_by!(source: 'MatchResult', legacy_id: c['id']).update!(target_kind: 'Match', target_id: item.id) }
      end
    end
  end
end
