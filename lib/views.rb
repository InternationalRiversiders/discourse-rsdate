# frozen_string_literal: true
module DiscourseRsdate
  module Service
    def self.profile_form(user)
      p = Profile.find_by(user_id: user.id); rule = school_rule(user)
      fields = [Ui.field('nickname', '昵称', p&.nickname, required: true, minlength: 2, maxlength: 24),
        Ui.field('gender', '性别', p&.gender || GENDERS.first, type: 'select', options: GENDERS),
        Ui.field('target_gender', '希望认识的对象', p&.target_gender || '不限', type: 'select', options: TARGETS),
        Ui.field('grade', '年级', p&.grade || '大一', type: 'select', options: Matching::GRADES),
        Ui.field('campus', '校区', rule && rule[:campuses].include?(p&.campus) ? p.campus : rule&.dig(:campuses)&.first, type: 'select', options: rule&.dig(:campuses) || []),
        Ui.field('mbti', 'MBTI（可选）', p&.mbti || MBTI.first, type: 'select', options: MBTI),
        Ui.field('zodiac', '星座（可选）', p&.zodiac || ZODIAC.first, type: 'select', options: ZODIAC),
        Ui.field('interests', '兴趣标签', p&.interests, type: 'textarea', hint: '用逗号或换行分隔，最多 12 个，每个不超过 20 字。', maxlength: 1000),
        Ui.field('schedule', '空闲时间', p&.schedule, type: 'textarea', required: true, minlength: 4, maxlength: 120),
        Ui.field('bio', '自我介绍', p&.bio, type: 'textarea', required: true, minlength: 10, maxlength: 280)]
      Ui.form('我的资料', 'profile', fields, button: '保存资料')
    end
    def self.module_form(q = nil)
      draft = q&.questions&.map { |x| "#{x['prompt']}#{x['description'].present? ? "###{x['description']}" : ''}||#{x['options'].map { |o| o['label'] }.join('|')}" }&.join("\n")
      Ui.form(q ? "编辑问卷：#{q.title}" : '新建问卷模块', 'questionnaire', [Ui.field('title', '模块名称', q&.title, required: true, maxlength: 100),
        Ui.field('description', '模块说明', q&.description, type: 'textarea', maxlength: 2000),
        Ui.field('position', '排列顺序', q&.position || 0, type: 'number', min: 0, max: 10000),
        Ui.field('questions', '问卷内容', draft, type: 'textarea', required: true, maxlength: 32000, hint: '每行一题：题目##题目说明||选项一|选项二。不写选项时使用五级同意量表。保存更新后，参与者需要重新填写本模块。'),
        Ui.field('required', '参加匹配前必须完成', q.nil? || q.required, type: 'checkbox'), Ui.field('active', '启用此模块', q.nil? || q.active, type: 'checkbox')], q ? {'id' => q.id, 'revision' => q.revision} : {}, button: '保存问卷', confirm: q ? '更新后本模块的旧提交将失效，需要重新填写。确定保存？' : nil)
    end
    def self.page_scope(scope, out, query, size: 20)
      count = scope.count; pages = [(count.to_f / size).ceil, 1].max; page = [[query['page'].to_i, 1].max, pages].min
      out[:pagination] = "第 #{page} / #{pages} 页 · 共 #{count} 条"
      base = query.slice('view', 'part', 'q')
      out[:previous] = base.merge('page' => page - 1) if page > 1
      out[:next] = base.merge('page' => page + 1) if page < pages
      scope.offset((page - 1) * size).limit(size)
    end
    def self.profile_body(p)
      "#{p.school} · #{p.grade} · #{p.campus}\n#{p.gender} · 希望认识：#{p.target_gender}\nMBTI：#{p.mbti.presence || '暂未填写'} · 星座：#{p.zodiac.presence || '暂未填写'}\n兴趣：#{p.interests.presence || '暂未填写'}\n时间安排：#{p.schedule}\n#{p.bio}"
    end
    def self.state(user, query)
      Access.check!(user)
      tabs = [['home', '个人主页'], ['me', '我的资料'], ['questions', '问卷模块'], ['results', '匹配结果']]
      tabs << ['admin', '管理'] if Access.admin?(user)
      out = Ui.shell(user, query, tabs, empty_title: '还没有新的记录', empty_text: '完成资料和问卷，自主报名，等待下一次相遇。')
      raise Discourse::NotFound unless %w[home me questions module results waiting admin].include?(out[:view])
      p = Profile.find_by(user_id: user.id); progress = progress(user.id)
      case out[:view]
      when 'me'
        rule = school_rule(user)
        out[:forms] = [profile_form(user)] if rule
        out[:note] = rule ? "已认证学校：#{rule[:school]}。资料不会公开展示，仅在配对成功后对匹配对象可见。" : '尚未找到与你的论坛用户组对应的学校，请联系管理员配置学校与校区。'
        out[:export_url] = '/rsdate/export'
      when 'questions'
        out[:cards] = progress[:modules].map do |m|
          q = m[:item]
          Ui.card("module-#{q.id}", q.title, q.description, tag: m[:completed] ? '已完成' : (m[:submission] ? '需要重填' : '未填写'), subtitle: "#{q.questions.size} 道题 · #{q.required ? '必填模块' : '选填模块'}",
            links: [Ui.link(m[:completed] ? '查看并修改回答' : '开始填写', {view: 'module', id: q.id})])
        end
        out[:stats] = [{label: '必填进度', value: "#{progress[:completed_required]} / #{progress[:required]}"}, {label: '已完成模块', value: "#{progress[:completed]} / #{progress[:modules].size}"}]
        out[:note] = '每个模块单独保存。完成必填模块后，还需要在个人主页主动报名。模块更新后会提示重新填写。'
        out[:empty_title] = '问卷尚未开放'; out[:empty_text] = '管理员正在准备问卷，开放后即可填写并报名。'
      when 'module'
        q = Questionnaire.find(Shared.id(query['id'])); raise Discourse::NotFound unless q.active
        s = Submission.find_by(user_id: user.id, questionnaire_id: q.id)
        fields = q.questions.map do |question|
          Ui.field("answer_#{question['id']}", question['prompt'], fresh?(q, s) ? s.answers[question['id'].to_s] : '', type: 'select', options: [['', '请选择']] + question['options'].map { |o| [o['id'].to_s, o['label']] }, required: true, hint: question['description'])
        end
        out[:note] = q.description; out[:heading] = q.title; out[:back] = {view: 'questions'}
        out[:forms] = [Ui.form(q.title + (q.required ? ' · 必填' : ' · 选填'), 'answers', fields, {'id' => q.id, 'revision' => q.revision}, button: '保存本模块')]
      when 'results'
        scope = Match.where(user_id: user.id).order(published_at: :desc, id: :desc)
        out[:cards] = page_scope(scope, out, query).map do |match|
          partner = Profile.find_by(user_id: match.partner_id); account = User.find_by(id: match.partner_id)
          metrics = Array(match.details['modules']).map { |m| {label: m['title'], value: m['summary'].presence || "#{m['same']} 题一致 / #{m['near']} 题相近"} }
          Ui.card("match-#{match.id}", partner&.nickname || '历史匹配', partner ? profile_body(partner) : '对方资料已不可用，匹配记录仍保留。', type: 'match', tag: match.current ? '当前结果' : '历史记录', created_at: match.published_at.iso8601, metrics: metrics,
            account: partner && account ? Shared.forum_user(account).merge(name: account.username, href: "/u/#{UrlHelper.encode_component(account.username)}") : nil,
            empty_detail: metrics.empty? ? '这条历史结果没有模块接近度明细。' : nil)
        end
        out[:note] = '结果仅对匹配双方可见，请尊重对方的联系意愿。再次报名不会清除历史记录。'
        out[:empty_title] = '还没有发布你的匹配结果'; out[:empty_text] = p&.active ? '你仍在匹配池中，发布后会在这里显示对方资料。' : '完成资料与问卷后，在个人主页参加当前匹配。'
      when 'admin'
        admin_state(user, query, out)
      else
        ready = !!p && progress[:ready]; active = p&.active && ready
        current = Match.find_by(user_id: user.id, current: true)
        latest = Publication.order(created_at: :desc, id: :desc).first
        title, description = if !p
          ['从一份真实的资料开始', '先完善个人资料，再填写问卷，最后选择是否加入匹配。']
        elsif !progress[:ready]
          ['先完成当前必填模块', progress[:modules].empty? ? '问卷尚未开放，请稍后再来。' : "已完成 #{progress[:completed_required]}/#{progress[:required]} 个必填模块。更新后的问卷需要重填。"]
        elsif active && current
          ['你已报名下一轮匹配', '上一轮结果仍然可以查看，现在等待下一次发布即可。']
        elsif current
          ['你的匹配结果已发布', '可以查看对方资料，或主动报名参加下一轮。']
        elsif !active
          ['准备好了，就加入本轮匹配', '个人资料和必填模块已完成，由你决定何时参加。']
        elsif latest && p.last_published_cycle_key == latest.cycle_key
          ['这次还没有遇到合适的人', '你会继续留在匹配池中，等待下次发布，无需重新报名。']
        else
          ['你已经在当前匹配中', '资料和问卷已就绪，接下来等待统一发布。']
        end
        actions = []
        actions << Ui.action('参加当前匹配', 'join') if ready && !p.active
        actions << Ui.action('暂停匹配', 'pause') if p&.active
        out[:cards] = [Ui.card('status', title, description, tag: active ? '等待相遇' : '我的进度', actions: actions,
          links: [Ui.link('编辑资料', {view: 'me'}), Ui.link('填写问卷', {view: 'questions'}), Ui.link('查看结果', {view: 'results'})])]
        out[:cards] << Ui.card('my-profile', p.nickname, profile_body(p), subtitle: p.last_published_at ? nil : "尚未参与", created_at: p.last_published_at&.iso8601, time_label: "最近参与发布：") if p
        out[:stats] = [{label: '参与状态', value: active ? '匹配池中' : (p&.active ? '需补填问卷' : '未参与')},
          {label: '必填模块', value: "#{progress[:completed_required]} / #{progress[:required]}"},
          {label: '当前池内人数', value: Matching.eligible_pool.first.size},
          {label: '下次发布时间', at: SiteSetting.rsdate_scheduled_enabled ? next_publish_at&.iso8601 : nil, value: '由管理员发布'}]
        out[:note] = '成功配对后自动退出匹配池；再次参加需要主动报名。未配对成功则继续保留在池中。'
      end
      if out[:readonly]
        out[:forms] = []
        out[:cards].each { |card| card[:forms] = []; card[:actions] = [] }
        out[:readonly_note] = '当前为真实数据的只读预览，报名、发布和通知均已暂停。'
        # Read-only questionnaire answers remain inspectable without a submission button.
        if out[:view] == 'module'
          q = Questionnaire.find(query['id']); s = Submission.find_by(user_id: user.id, questionnaire_id: q.id)
          out[:cards] = q.questions.map { |question| Ui.card(question['id'], question['prompt'], question['options'].map { |o| "#{s&.answers&.[](question['id'].to_s) == o['id'].to_s ? '✓ ' : ''}#{o['label']}" }.join("\n"), subtitle: question['description']) }
        end
      end
      out
    end
    def self.admin_state(user, query, out)
      Access.check!(user, admin: true)
      part = query['part'].presence || 'runs'
      out[:subnav] = [['runs', '匹配运营'], ['profiles', '参与者'], ['modules', '问卷管理'], ['publications', '发布记录'], ['audits', '操作记录']].map { |key, label| {label: label, query: {view: 'admin', part: key}, active: part == key} }
      case part
      when 'modules'
        if query['edit'].present? || query['new'] == '1'
          out[:forms] = [module_form(query['edit'].present? ? Questionnaire.find(Shared.id(query['edit'])) : nil)]
          out[:back] = {view: 'admin', part: 'modules'}
        else
          out[:cards] = [Ui.card('new-module', '添加新的问卷模块', '按主题组织问题，设置是否为报名必填。', links: [Ui.link('新建模块', {view: 'admin', part: 'modules', new: '1'})])]
          out[:cards] += Questionnaire.order(:position, :created_at).map do |q|
            Ui.card("q-#{q.id}", q.title, q.description, tag: q.active ? (q.required ? '必填' : '选填') : '已停用', subtitle: "#{q.questions.size} 题 · #{Submission.where(questionnaire_id: q.id, revision: q.revision).count} 份当前提交 · 排序 #{q.position}",
              links: [Ui.link('编辑模块', {view: 'admin', part: 'modules', edit: q.id})],
              forms: [Ui.form('删除模块', 'delete_questionnaire', [Ui.field('reason', '处理理由', nil, required: true)], {'id' => q.id}, button: '删除模块', confirm: '删除会同时移除本模块的提交。确定继续？')])
          end
        end
      when 'profiles'
        out[:filters] = [Ui.field('q', '搜索昵称或论坛用户名', query['q'])]
        scope = Profile.order(active: :desc, updated_at: :desc)
        if query['q'].present?
          term = "%#{Record.sanitize_sql_like(query['q'].to_s.strip)}%"
          scope = scope.where('nickname ILIKE ? OR user_id IN (SELECT id FROM users WHERE username ILIKE ?)', term, term)
        end
        out[:cards] = page_scope(scope, out, query).map do |p|
          status = progress(p.user_id); current = Match.find_by(user_id: p.user_id, current: true)
          forms = [Ui.form(p.active ? '暂停参与' : '恢复参与', 'set_active', [Ui.field('reason', '处理理由', nil, required: true)], {'user_id' => p.user_id, 'active' => !p.active}, button: p.active ? '暂停' : '恢复', confirm: p.active ? nil : '请确认该用户愿意重新参加匹配。')]
          forms << Ui.form('撤回当前结果', 'clear_match', [Ui.field('reason', '处理理由', nil, required: true)], {'user_id' => p.user_id}, button: '撤回配对', confirm: '双方本次结果及对应历史将撤回，双方重新入池。确定继续？') if current
          Ui.card("profile-#{p.id}", p.nickname, profile_body(p), subtitle: "#{Shared.user_name(p.user_id)} · 必填 #{status[:completed_required]}/#{status[:required]}#{current ? " · 当前对象：#{Shared.user_name(current.partner_id)}" : ''}", account: Shared.forum_user(p.user_id), tag: p.active ? '已选择参加' : '未参加', forms: forms)
        end
      when 'publications'
        out[:cards] = page_scope(Publication.order(created_at: :desc, id: :desc), out, query).map { |pub| Ui.card("pub-#{pub.id}", pub.cycle_key, "参与 #{pub.pool_size} 人 / 成功 #{pub.pair_count} 对 / 未配对 #{pub.unmatched_count} 人", created_at: pub.created_at.iso8601, tag: {'scheduled_auto' => '定时发布', 'admin_manual_pool' => '整池发布', 'admin_manual_pair' => '指定配对'}[pub.mode] || '历史发布') }
      when 'audits'
        out[:cards] = page_scope(Audit.order(id: :desc), out, query).map { |a| Ui.card("audit-#{a.id}", a.action, a.reason, account: Shared.forum_user(a.user_id), created_at: a.created_at.iso8601) }
      else
        pool, = Matching.eligible_pool
        out[:stats] = [{label: '已填写资料', value: Profile.count}, {label: '已选择参加', value: Profile.where(active: true).count}, {label: '当前有效入池', value: pool.size}]
        out[:forms] = [Ui.form('预览当前匹配池', 'preview', [], button: '生成匹配预览'),
          Ui.form('发布当前匹配池', 'publish', [Ui.field('reason', '发布说明', nil, required: true)], button: '发布匹配', confirm: '将向当前有效池内成员发布结果，并发送站内通知。确定继续？'),
          Ui.form('手动指定配对', 'manual_pair', [Ui.field('left', '用户一（论坛用户名）', nil, required: true), Ui.field('right', '用户二（论坛用户名）', nil, required: true), Ui.field('reason', '配对说明（仅管理可见）', nil, required: true)], button: '发布指定配对', confirm: '手动配对沿用旧版规则：双方须已报名且完成必填问卷，但可覆盖性别偏好。请确认双方意愿。')]
        out[:cards] = page_scope(Run.order(id: :desc), out, query).map do |r|
          body = r.error.presence || if r.mode == 'preview' && r.status == 'complete'
            ["有效池 #{r.result['pool_size']} 人；未配对 #{Array(r.result['unmatched']).size} 人", *Array(r.result['pairs']).map { |pair| "#{pair['left']} ↔ #{pair['right']} · #{pair['score']} 分\n#{pair['note']}" }, "未配对：#{Array(r.result['unmatched']).join('、')}"] .join("\n\n")
          elsif r.status == 'complete'
            "已发布 #{r.result['pair_count']} 对；未配对 #{r.result['unmatched_count']} 人"
          else
            '后台处理中，稍后刷新查看。'
          end
          Ui.card("run-#{r.id}", {'preview' => '匹配预览', 'publish' => '整池发布', 'manual_pair' => '手动配对'}[r.mode], body, tag: {'pending' => '排队中', 'complete' => '已完成', 'failed' => '失败'}[r.status], created_at: r.created_at.iso8601)
        end
        out[:note_at] = next_publish_at&.iso8601 if SiteSetting.rsdate_scheduled_enabled
        out[:note] = SiteSetting.rsdate_scheduled_enabled ? "自动发布时间：" : '自动定时发布已关闭。预览不会修改报名状态，也不会发送通知。'
        out[:refresh] = {view: 'admin', page: query['page']}
      end
    end
  end
end
