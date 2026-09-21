# frozen_string_literal: true
require_relative 'solver/algorithm/mwm_general'
module DiscourseRsdate
  module Matching
    GRADES=%w[大一 大二 大三 大四 硕士 博士 已毕业].freeze
    def self.solve(count,edges)
      DiscourseRsdateSolver::Algorithm::MWMGeneral.new(DiscourseRsdateSolver::Graph::WeightedGraph.new(count,edges)).match(true).edges
    end
    def self.compatible?(a,b)
      (a.target_gender=='不限' || a.target_gender==b.gender) && (b.target_gender=='不限' || b.target_gender==a.gender)
    end
    def self.interests(text)
      text.to_s.split(/[\n,，]+/).map(&:strip).reject(&:blank?)
    end
    def self.cosine(a,b)
      return nil unless a.embedding_model.present? && a.embedding_model==b.embedding_model
      x=a.embedding;y=b.embedding
      return nil unless x.is_a?(Array) && y.is_a?(Array) && x.size==y.size && x.size>0 && (x+y).all? { |v| v.is_a?(Numeric) && v.finite? }
      nx=Math.sqrt(x.sum { |v| v*v });ny=Math.sqrt(y.sum { |v| v*v });return nil if nx==0 || ny==0
      x.zip(y).sum { |u,v| u*v }/(nx*ny)
    end
    def self.modules(a,b,submissions,questionnaires)
      questionnaires.filter_map do |q|
        left=submissions[[a.user_id,q.id]];right=submissions[[b.user_id,q.id]]
        next unless Service.fresh?(q,left) && Service.fresh?(q,right)
        same=0;near=0;count=0
        q.questions.each do |question|
          x=left.answers[question['id'].to_s];y=right.answers[question['id'].to_s];next unless x && y
          positions=question['options'].to_h { |o| [o['id'].to_s,o['order'].to_i] }
          u=positions[x.to_s];v=positions[y.to_s];next unless u && v && u>0 && v>0
          count+=1;gap=(u-v).abs;same+=1 if gap==0;near+=1 if gap==1
        end
        next if count==0
        {'module_id'=>q.id,'title'=>q.title,'count'=>count,'same'=>same,'near'=>near,'score'=>same*2+near,'summary'=>[same>0 ? "#{same} 题一致" : nil,near>0 ? "#{near} 题相近" : nil].compact.join('，').presence || "共比较 #{count} 题"}
      end.sort_by { |m| [-m['score'],m['title']] }
    end
    def self.score(a,b,submissions,questionnaires)
      mods=modules(a,b,submissions,questionnaires)
      count=mods.sum { |m| m['count'] };points=mods.sum { |m| m['score'] }
      questionnaire=count>0 ? (30.0*points/(count*2)).round : 0
      common=interests(b.interests).select { |v| interests(a.interests).include?(v) }
      same_school=a.school==b.school;same_campus=same_school && a.campus==b.campus
      x=GRADES.index(a.grade);y=GRADES.index(b.grade);gap=x && y ? (x-y).abs : 99
      cos=cosine(a,b);embedding=cos ? ([[((cos-0.68)/0.22),0].max,1].min*12).round : 0
      total=questionnaire+embedding+[common.size*2,8].min+(same_school ? 6 : 0)+(same_campus ? 3 : 0)+(gap==0 ? 4 : (gap==1 ? 2 : 0))
      notes=[]
      notes << "问卷接近度 #{(100.0*points/(count*2)).round}%" if count>0
      notes << (cos>=0.90 ? '自由文本非常接近' : (cos>=0.84 ? '自由文本较接近' : '自由文本有一定接近度')) if cos && cos>=0.76
      notes << '同校' if same_school
      notes << "共同兴趣：#{common.join('、')}" if common.any?
      notes << '同校区' if same_campus
      notes << (gap==0 ? '同年级' : '年级相近') if gap<=1
      {'score'=>total,'modules'=>mods,'common_interests'=>common,'same_school'=>same_school,'same_campus'=>same_campus,'note'=>notes.join('；').presence || '满足双方性别偏好'}
    end
    def self.eligible_pool
      questionnaires=Service.questions
      pool=Profile.where(active:true).order(:updated_at,Arel.sql('user_id::text')).to_a
      submissions=Submission.where(user_id:pool.map(&:user_id),questionnaire_id:questionnaires.map(&:id)).to_a.index_by { |item| [item.user_id,item.questionnaire_id] }
      required=questionnaires.select(&:required)
      users=User.where(id:pool.map(&:user_id)).index_by(&:id)
      pool.select! do |p|
        Access.participant?(users[p.user_id]) && questionnaires.any? && required.all? { |q| Service.fresh?(q,submissions[[p.user_id,q.id]]) }
      end
      [pool,submissions,questionnaires]
    end
    def self.preview
      pool,submissions,questionnaires=eligible_pool
      raise Error,'参与人数超过本次匹配上限，请先进行负载验收并调整设置' if pool.size>SiteSetting.rsdate_max_pool
      details={};edges=[]
      pool.each_with_index do |a,i|
        ((i+1)...pool.size).each do |j|
          b=pool[j];next unless compatible?(a,b)
          detail=score(a,b,submissions,questionnaires);details[[i+1,j+1]]=detail
          edges<<[i+1,j+1,(detail['score']+1)*1000]
        end
      end
      pairs=(edges.empty? ? [] : solve(pool.size,edges)).map do |i,j|
        i,j=[i,j].sort
        {left:pool[i-1],right:pool[j-1],details:details[[i,j]]}
      end.sort_by { |p| [-p[:details]['score'],"#{p[:left].user_id}:#{p[:right].user_id}"] }
      used=pairs.flat_map { |p| [p[:left].id,p[:right].id] }
      {pool:pool,pairs:pairs,unmatched:pool.reject { |p| used.include?(p.id) }}
    end
    def self.publish(cycle,user:nil,manual:nil,note:nil,published_at:Time.current)
      Access.writable!
      raise Discourse::InvalidAccess unless SiteSetting.rsdate_enabled
      Access.check!(user,admin:true) if user
      Record.transaction do
        Shared.lock('matching-pool')
        next Publication.find_by(cycle_key:cycle) if Publication.exists?(cycle_key:cycle)
        if manual
          raise Discourse::InvalidAccess unless user
          a,b=manual.map(&:reload)
          raise Error,'不能与自己匹配' if a.user_id==b.user_id
          pool,submissions,questionnaires=eligible_pool
          raise Error,'双方需要加入匹配池、完成必填问卷且保持参与权限' unless [a.user_id,b.user_id].all? { |id| pool.any? { |p| p.user_id==id } }
          detail=score(a,b,submissions,questionnaires).merge('manual'=>true,'note'=>note)
          preview={pool:[a,b],pairs:[{left:a,right:b,details:detail}],unmatched:[]}
        else
          preview=preview()
        end
        pub=Publication.create!(cycle_key:cycle,user_id:user&.id,mode:manual ? 'admin_manual_pair' : (user ? 'admin_manual_pool' : 'scheduled_auto'),pool_size:preview[:pool].size,pair_count:preview[:pairs].size,unmatched_count:preview[:unmatched].size,created_at:published_at)
        Profile.where(id:preview[:pool].map(&:id)).update_all(last_published_cycle_key:cycle,last_published_at:published_at,updated_at:Time.current)
        paired_ids=preview[:pairs].flat_map { |pair| [pair[:left].user_id,pair[:right].user_id] }
        # Keep history, but don't leave an old partner with an asymmetric current match.
        Match.where(current:true).where('user_id IN (?) OR partner_id IN (?)',paired_ids,paired_ids).update_all(current:false) if paired_ids.any?
        preview[:pairs].each do |pair|
          a=pair[:left];b=pair[:right]
          [[a,b],[b,a]].each do |profile,partner|
            Match.create!(publication_id:pub.id,user_id:profile.user_id,partner_id:partner.user_id,details:pair[:details],published_at:published_at,published_by_id:user&.id)
            profile.update!(active:false,last_published_cycle_key:cycle,last_published_at:published_at)
            Shared.notify(profile.user_id,'你的 RSDate 匹配结果已发布，登录后查看','/rsdate?view=results',key:"match:#{pub.id}:#{profile.user_id}")
          end
        end
        preview[:unmatched].each { |p| Shared.notify(p.user_id,'本期暂未匹配成功，你仍保留在匹配池中','/rsdate?view=home',key:"unmatched:#{pub.id}:#{p.user_id}") }
        pub
      end
    end
  end
end
