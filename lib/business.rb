# frozen_string_literal: true
require 'net/http'
module DiscourseRsdate
  %w[Profile Questionnaire Submission Publication Match Run].each do |name|
    klass = Class.new(Record); klass.table_name = "river_rsdate_#{name.underscore.pluralize}"; const_set(name, klass)
  end
  module Service
    GENDERS = %w[男生 女生 非二元 其他].freeze
    TARGETS = %w[男生 女生 不限].freeze
    MBTI = %w[暂不确定 INTJ INTP ENTJ ENTP INFJ INFP ENFJ ENFP ISTJ ISFJ ESTJ ESFJ ISTP ISFP ESTP ESFP].freeze
    ZODIAC = %w[暂不填写 白羊座 金牛座 双子座 巨蟹座 狮子座 处女座 天秤座 天蝎座 射手座 摩羯座 水瓶座 双鱼座].freeze
    SCALE = %w[非常不同意 不同意 一般 同意 非常同意].freeze
    def self.school_rule(user)
      return unless user
      groups = user.groups.pluck(:name).map(&:downcase)
      SiteSetting.rsdate_school_groups.split(';').filter_map do |row|
        school, group, campuses = row.split(':', 3).map(&:strip)
        {school: school, campuses: campuses.to_s.split('|').map(&:strip).reject(&:blank?)} if group && groups.include?(group.downcase)
      end.first
    end
    def self.questions = Questionnaire.where(active: true).order(:position, :created_at, :id).to_a
    def self.fresh?(q, s)
      s && s.revision == q.revision && s.answers.size == q.questions.size && q.questions.all? do |question|
        question['options'].any? { |o| o['id'].to_s == s.answers[question['id'].to_s].to_s }
      end
    end
    def self.progress(user_id)
      submissions = Submission.where(user_id: user_id).index_by(&:questionnaire_id)
      modules = questions.map { |q| {item: q, submission: submissions[q.id], completed: !!fresh?(q, submissions[q.id])} }
      required = modules.select { |m| m[:item].required }
      {modules: modules, required: required.size, completed_required: required.count { |m| m[:completed] }, completed: modules.count { |m| m[:completed] }, ready: modules.any? && required.all? { |m| m[:completed] }}
    end
    def self.sync_school(profile, user)
      rule = school_rule(user)
      return profile unless profile && rule
      campus = rule[:campuses].include?(profile.campus) ? profile.campus : rule[:campuses].first
      if profile.school != rule[:school] || profile.campus != campus
        profile.update!(school: rule[:school], campus: campus)
      end
      profile
    end
    def self.parse_questions(draft)
      lines = Shared.text(draft, 32_000).lines.map(&:strip).reject(&:blank?)
      raise Error, '每个模块最多 100 题' if lines.size > 100
      lines.each_with_index.map do |line, index|
        prompt_part, *option_parts = line.split('||')
        # Also accept the previous native prototype's single-pipe notation.
        prompt_part, *option_parts = line.split('|') if option_parts.empty? && line.include?('|')
        prompt, description = prompt_part.split('##', 2).map(&:strip)
        options = option_parts.flat_map { |v| v.split('|') }.map(&:strip).reject(&:blank?)
        options = SCALE if options.empty?
        raise Error, "第 #{index + 1} 题应有 2 至 20 个选项" unless options.size.between?(2, 20)
        {'id' => SecureRandom.uuid, 'prompt' => Shared.text(prompt, 1000), 'description' => Shared.text(description, 2000, required: false), 'order' => index + 1,
         'options' => options.each_with_index.map { |label, i| {'id' => SecureRandom.uuid, 'order' => i + 1, 'value' => label, 'label' => Shared.text(label, 500)} }}
      end
    end
    def self.call(user, operation, data)
      Access.check!(user); Access.writable!
      # Same lock order in user commands, publication, import and lifecycle hooks.
      Shared.lock('matching-pool')
      case operation
      when 'profile'
        rule = school_rule(user); raise Error, '请先配置你的认证学校和校区' unless rule
        raise Error, '校区不属于你的学校' unless rule[:campuses].include?(data['campus'])
        raise Error, '性别选项无效' unless GENDERS.include?(data['gender']) && TARGETS.include?(data['target_gender'])
        raise Error, '年级选项无效' unless Matching::GRADES.include?(data['grade'])
        mbti = data['mbti'].presence || MBTI.first; zodiac = data['zodiac'].presence || ZODIAC.first
        raise Error, 'MBTI 或星座选项无效' unless MBTI.include?(mbti) && ZODIAC.include?(zodiac)
        attrs = {'nickname' => Shared.text(data['nickname'], 24), 'schedule' => Shared.text(data['schedule'], 120), 'bio' => Shared.text(data['bio'], 280), 'interests' => Shared.text(data['interests'], 1000, required: false)}
        raise Error, '昵称请控制在 2 到 24 个字符之间' if attrs['nickname'].length < 2
        raise Error, '时间安排请控制在 4 到 120 个字符之间' if attrs['schedule'].length < 4
        raise Error, '自我介绍请控制在 10 到 280 个字符之间' if attrs['bio'].length < 10
        interests = Matching.interests(attrs['interests'])
        raise Error, '兴趣最多 12 个，每个不超过 20 字' if interests.size > 12 || interests.any? { |v| v.length > 20 }
        attrs['interests'] = interests.join(', ')
        p = Profile.find_or_initialize_by(user_id: user.id)
        changed = %w[bio interests schedule].any? { |k| p.public_send(k) != attrs[k] }
        attrs.merge!(gender: data['gender'], target_gender: data['target_gender'], grade: data['grade'], school: rule[:school], campus: data['campus'], mbti: mbti == MBTI.first ? nil : mbti, zodiac: zodiac == ZODIAC.first ? nil : zodiac)
        attrs.merge!(embedding: nil, embedding_model: nil, embedding_fingerprint: nil, embedding_updated_at: nil) if changed
        p.update!(attrs)
        {message: '资料已保存；参与匹配请在个人主页主动报名', query: {view: 'home'}}
      when 'join', 'pause', 'set_active'
        Access.check!(user, admin: true) if operation == 'set_active'
        p = Profile.find_by!(user_id: operation == 'set_active' ? Shared.id(data['user_id']) : user.id)
        active = operation == 'join' || (operation == 'set_active' && Shared.bool(data['active']))
        if active
          raise Error, '请先完成当前必填问卷模块' unless progress(p.user_id)[:ready]
          participant = User.find_by(id: p.user_id)
          raise Error, '参与权限已变更' unless Access.member?(participant) && school_rule(participant)
          sync_school(p, participant)
        end
        p.update!(active: active)
        Shared.audit(user, active ? 'resume_profile' : 'pause_profile', p, data['reason']) if operation == 'set_active'
        {message: active ? '已加入当前匹配池' : '已暂停匹配', query: operation == 'set_active' ? nil : {view: 'home'}}
      when 'answers'
        q = Questionnaire.find(Shared.id(data['id']))
        raise Error, '问卷已变更，请刷新后重新填写' unless q.active && data['revision'].to_i == q.revision
        answers = q.questions.to_h do |question|
          value = data["answer_#{question['id']}"]
          raise Error, "请完成：#{question['prompt']}" unless question['options'].any? { |o| o['id'].to_s == value.to_s }
          [question['id'].to_s, value.to_s]
        end
        Submission.find_or_initialize_by(user_id: user.id, questionnaire_id: q.id).update!(answers: answers, revision: q.revision, submitted_at: Time.current)
        {message: '模块已保存', query: {view: 'questions'}}
      when 'questionnaire'
        Access.check!(user, admin: true)
        q = data['id'].present? ? Questionnaire.find(Shared.id(data['id'])) : Questionnaire.new(created_by_id: user.id)
        if q.persisted? && data['revision'].to_i != q.revision
          raise Error, '问卷已由其他管理员更新，请刷新后再编辑'
        end
        position = Integer((data['position'].presence || '0').to_s, 10)
        raise Error, '排序应在 0 至 10000 之间' unless position.between?(0, 10_000)
        q.update!(title: Shared.text(data['title'], 100), description: Shared.text(data['description'], 2000, required: false), questions: parse_questions(data['questions']), required: Shared.bool(data['required']), active: Shared.bool(data['active']), position: position, revision: q.persisted? ? q.revision + 1 : 1)
        Shared.audit(user, 'questionnaire_saved', q, '问卷已更新；旧版提交需要重填')
        {message: '问卷已保存；更新过的模块需要重新提交', query: {view: 'admin', part: 'modules'}}
      when 'delete_questionnaire'
        Access.check!(user, admin: true); q = Questionnaire.find(Shared.id(data['id']))
        Shared.audit(user, 'questionnaire_deleted', q, data['reason'])
        submission_ids = Submission.where(questionnaire_id: q.id).pluck(:id)
        archived = Legacy.where(target_kind: 'Submission', target_id: submission_ids).pluck(:legacy_id)
        Legacy.where(source: 'QuestionnaireModuleAnswer').where("data->>'submissionId' IN (?)", archived).delete_all if archived.any?
        old_module = Legacy.find_by(target_kind: 'Questionnaire', target_id: q.id)
        if old_module
          old_questions = Legacy.where(source: 'QuestionnaireModuleQuestion').where("data->>'moduleId' = ?", old_module.legacy_id)
          Legacy.where(source: 'QuestionnaireModuleOption').where("data->>'questionId' IN (?)", old_questions.pluck(:legacy_id)).delete_all
          old_questions.delete_all
        end
        Legacy.where(target_kind: 'Submission', target_id: submission_ids).delete_all
        Legacy.where(target_kind: 'Questionnaire', target_id: q.id).delete_all
        Submission.where(questionnaire_id: q.id).delete_all; q.destroy!
        {message: '问卷及其提交已删除'}
      when 'preview', 'publish', 'manual_pair'
        Access.check!(user, admin: true)
        details = {'reason' => operation == 'preview' ? '预览匹配池' : Shared.text(data['reason'], 500)}
        if operation == 'manual_pair'
          details.merge!('left' => User.find_by!(username_lower: data['left'].to_s.strip.downcase).id, 'right' => User.find_by!(username_lower: data['right'].to_s.strip.downcase).id)
        end
        r = Run.create!(user_id: user.id, mode: operation, details: details)
        Shared.audit(user, operation, r, details['reason'])
        {message: '任务已排队，后台完成后刷新管理页可查看', query: {view: 'admin'}}
      when 'clear_match'
        Access.check!(user, admin: true)
        p = Profile.find_by!(user_id: Shared.id(data['user_id']))
        current = Match.find_by(user_id: p.user_id, current: true)
        raise Error, '该用户没有当前匹配结果' unless current
        ids = [current.user_id, current.partner_id]
        # Withdraw both sides of this publication, including the corresponding history.
        removed = Match.where(publication_id: current.publication_id, user_id: ids)
        Legacy.where(target_kind: 'Match', target_id: removed.pluck(:id)).delete_all
        removed.delete_all
        Match.where(current: true).where('user_id IN (?) OR partner_id IN (?)', ids, ids).update_all(current: false)
        Profile.where(user_id: ids).update_all(active: true, last_published_cycle_key: nil, last_published_at: nil, updated_at: Time.current)
        Shared.audit(user, 'clear_current_match', p, data['reason'])
        {message: '双方结果已撤回，双方重新回到匹配池；其他历史记录保留'}
      else raise Error, '未知操作'
      end
    end
    def self.legacy_query(path, params = {})
      path = path.to_s.sub(%r{\A/}, '').sub(%r{/\z}, '')
      views = {'app' => 'home', 'profile' => 'me', 'waiting' => 'home', 'results' => 'results', 'questionnaire' => 'questions'}
      return {view: views[path]} if views.key?(path)
      if path == 'admin'
        id = Legacy.find_by(source: 'QuestionnaireModule', legacy_id: params['edit'].to_s)&.target_id if params['edit'].present?
        return id ? {view: 'admin', part: 'modules', edit: id} : {view: 'admin'}
      end
      if path.start_with?('questionnaire/')
        id = Legacy.find_by(source: 'QuestionnaireModule', legacy_id: path.split('/', 2).last)&.target_id
        return id && Questionnaire.exists?(id) ? {view: 'module', id: id} : {view: 'questions'}
      end
      {view: 'home'}
    end
    def self.scheduled_at(now = Time.current)
      zone = Time.find_zone!(SiteSetting.rsdate_publish_timezone)
      now = now.in_time_zone(zone)
      day = now.to_date - ((now.wday - SiteSetting.rsdate_publish_weekday) % 7)
      due = zone.local(day.year, day.month, day.day, SiteSetting.rsdate_publish_hour, SiteSetting.rsdate_publish_minute)
      due -= 7.days if due > now
      due
    end
    def self.next_publish_at(now = Time.current) = scheduled_at(now) + 7.days
    def self.tick
      return unless SiteSetting.rsdate_enabled && !SiteSetting.rsdate_read_only
      Run.where(status: 'pending').order(:id).limit(3).each do |run|
        begin
          Record.transaction do
            Shared.lock('matching-pool'); run.lock!
            next unless run.status == 'pending'
            actor = User.find_by(id: run.user_id); Access.check!(actor, admin: true)
            if run.mode == 'preview'
              preview = Matching.preview
              result = {pairs: preview[:pairs].map { |p| {left: Shared.user_name(p[:left].user_id), right: Shared.user_name(p[:right].user_id), score: p[:details]['score'], note: p[:details]['note'], modules: p[:details]['modules']} }, pool_size: preview[:pool].size, unmatched: preview[:unmatched].map { |p| Shared.user_name(p.user_id) }}
            else
              manual = run.mode == 'manual_pair' ? [Profile.find_by!(user_id: run.details['left']), Profile.find_by!(user_id: run.details['right'])] : nil
              pub = Matching.publish("manual-#{run.id}", user: actor, manual: manual, note: run.details['reason'])
              result = {publication_id: pub.id, pair_count: pub.pair_count, pool_size: pub.pool_size, unmatched_count: pub.unmatched_count}
            end
            run.update!(status: 'complete', result: result)
          end
        rescue StandardError => e
          Rails.logger.warn("RSDate run #{run.id}: #{e.class}")
          run.update!(status: 'failed', error: e.is_a?(Error) ? e.message : '任务未完成，请核对账号、权限或联系管理员检查日志')
        end
      end
      if SiteSetting.rsdate_scheduled_enabled
        due = scheduled_at
        start_at = SiteSetting.rsdate_scheduled_start_at.present? ? Time.iso8601(SiteSetting.rsdate_scheduled_start_at) : nil
        Matching.publish(due.strftime('%Y%m%d%H%M'), published_at: due) if start_at.nil? || due >= start_at
      end
      update_embeddings if SiteSetting.rsdate_embedding_key.present?
    end
    def self.embedding_text(p)
      "兴趣：#{p.interests.presence || '未填写'}\n时间安排：#{p.schedule.presence || '未填写'}\n自我介绍：#{p.bio.presence || '未填写'}"
    end
    def self.update_embeddings
      return unless SiteSetting.rsdate_enabled && !SiteSetting.rsdate_read_only && SiteSetting.rsdate_embedding_key.present?
      Profile.where(embedding: nil).order(:updated_at).limit(2).each do |p|
        next unless Access.member?(User.find_by(id: p.user_id))
        fingerprint = Digest::SHA256.hexdigest(embedding_text(p)); model = SiteSetting.rsdate_embedding_model
        uri = URI('https://api.openai.com/v1/embeddings')
        request = Net::HTTP::Post.new(uri); request['Authorization'] = "Bearer #{SiteSetting.rsdate_embedding_key}"; request['Content-Type'] = 'application/json'
        request.body = {model: model, input: embedding_text(p)}.to_json
        response = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 20) { |http| http.request(request) }
        next unless response.code == '200' && response.body.bytesize < 1.megabyte
        vector = JSON.parse(response.body).dig('data', 0, 'embedding')
        next unless vector.is_a?(Array) && vector.size.between?(1, 10000) && vector.all? { |v| v.is_a?(Numeric) && v.finite? }
        p.with_lock do
          next unless Digest::SHA256.hexdigest(embedding_text(p)) == fingerprint
          p.update!(embedding: vector, embedding_model: model, embedding_fingerprint: fingerprint, embedding_updated_at: Time.current)
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError
        Rails.logger.warn('RSDate embedding 暂时不可用')
      end
    end
  end
end
require_relative 'matching'
require_relative 'views'
