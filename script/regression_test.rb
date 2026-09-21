# frozen_string_literal: true
abort 'Disposable test database only' unless ENV['RIVER_DISPOSABLE']=='1' && GlobalSetting.db_name=='river_community_test'
require 'minitest/autorun'
require 'active_support/testing/time_helpers'
class RsdateTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers
  A=DiscourseRsdate
  def setup
    tables=ActiveRecord::Base.connection.tables.grep(/\Ariver_rsdate_/)
    ActiveRecord::Base.connection.execute('TRUNCATE '+tables.map { |t| ActiveRecord::Base.connection.quote_table_name(t) }.join(',')+' RESTART IDENTITY CASCADE')
    @group=Group.find_or_create_by!(name:'date_fixture_members')
    @admin=user('date_admin',true);@alice=user('date_alice');@bob=user('date_bob');@carol=user('date_carol');@outsider=user('date_outsider')
    [@alice,@bob,@carol,@admin].each { |u| @group.add(u);u.reload }
    SiteSetting.rsdate_enabled=true;SiteSetting.rsdate_read_only=false;SiteSetting.rsdate_admin_only=false
    SiteSetting.rsdate_allowed_groups=@group.id.to_s;SiteSetting.rsdate_admin_groups=''
    SiteSetting.rsdate_school_groups='测试大学:date_fixture_members:测试校区|其他'
    SiteSetting.rsdate_embedding_key='';SiteSetting.rsdate_scheduled_enabled=false;SiteSetting.rsdate_scheduled_start_at=''
    SiteSetting.rsdate_publish_weekday=0;SiteSetting.rsdate_publish_hour=20;SiteSetting.rsdate_publish_minute=0;SiteSetting.rsdate_publish_timezone='Asia/Shanghai'
  end
  def user(name,admin=false)
    User.find_by(username:name) || User.create!(username:name,email:"#{name}@example.com",password:SecureRandom.hex(32),active:true,approved:true,admin:admin)
  end
  def call(user,op,data={},key:SecureRandom.uuid)
    data=data.deep_stringify_keys
    A::Shared.command(user,op,data,key) { A::Service.call(user,op,data) }
  end
  def profile(user=@alice,**extra)
    call(user,'profile',{nickname:'测试同学',gender:'女生',target_gender:'不限',grade:'大二',campus:'测试校区',mbti:'INTJ',zodiac:'暂不填写',interests:'读书，音乐',schedule:'周末和工作日晚上',bio:'这是一个独立测试环境的虚构个人介绍。'}.merge(extra))
    A::Profile.find_by!(user_id:user.id)
  end
  def questionnaire(required:true)
    call(@admin,'questionnaire',{title:'生活方式',description:'模块说明',position:0,questions:"喜欢安静##没有标准答案\n喜欢早起||不同意|一般|同意",required:required,active:true})
    A::Questionnaire.last
  end
  def answer(user,q)
    call(user,'answers',{'id'=>q.id,'revision'=>q.revision}.merge(q.questions.to_h { |v| ["answer_#{v['id']}",v['options'].first['id']] }))
  end
  def ready(*users)
    q=questionnaire
    users.each { |u| profile(u);answer(u,q);call(u,'join') }
    q
  end
  def state(user=@alice,**query) = A::Service.state(user,query.deep_stringify_keys)
  def test_consent_and_legacy_options_validation
    p=profile(active:true)
    refute p.active
    assert_equal '读书, 音乐',p.interests
    assert_raises(A::Error) { call(@alice,'join') }
    q=questionnaire;answer(@alice,q);call(@alice,'join');assert p.reload.active
    profile(bio:'更新资料并不应取消我的报名状态。');assert p.reload.active
    call(@alice,'pause');refute p.reload.active
    assert_raises(A::Error) { profile(nickname:'一') }
    assert_raises(A::Error) { profile(gender:'男') }
    assert_raises(A::Error) { profile(schedule:'短') }
    assert_raises(A::Error) { profile(bio:'太短') }
    assert_raises(A::Error) { profile(interests:(1..13).map { |i| "标签#{i}" }.join(',')) }
  end
  def test_module_draft_freshness_and_stale_save
    q=ready(@alice)
    assert_equal 5,q.questions.first['options'].size
    assert_equal '没有标准答案',q.questions.first['description']
    assert A::Service.progress(@alice.id)[:ready]
    old_revision=q.revision
    call(@admin,'questionnaire',{id:q.id,revision:q.revision,title:q.title,questions:'新问题',required:true,active:true})
    refute A::Service.progress(@alice.id)[:ready]
    assert_empty A::Matching.preview[:pool]
    assert_raises(A::Error) { call(@alice,'answers',{id:q.id,revision:old_revision}) }
    assert_raises(A::Error) { call(@admin,'questionnaire',{id:q.id,revision:old_revision,title:'冲突',questions:'问题',required:true,active:true}) }
    answer(@alice,q.reload);assert A::Service.progress(@alice.id)[:ready]
    assert_equal '已完成',state(view:'questions')[:cards].first[:tag]
  end
  def test_matching_score_publication_idempotence_and_privacy
    ready(@alice,@bob,@carol)
    preview=A::Matching.preview
    assert_equal 3,preview[:pool].size;assert_equal 1,preview[:pairs].size;assert_equal 1,preview[:unmatched].size
    assert_equal 47,preview[:pairs].first[:details]['score']
    pub=A::Matching.publish('fixture-cycle',user:@admin)
    assert_equal pub.id,A::Matching.publish('fixture-cycle',user:@admin).id
    assert_equal 2,A::Match.count;assert_equal 3,A::Event.count
    assert_equal 1,A::Profile.where(active:true).count
    assert A::Profile.all.all? { |p| p.last_published_cycle_key=='fixture-cycle' }
    assert_equal 1,A::Match.where(user_id:preview[:unmatched].first.user_id).count+1
    paired=preview[:pairs].first[:left];u=User.find(paired.user_id)
    result=state(u,view:'results')[:cards].first
    assert result[:account][:href].start_with?('/u/');assert result[:metrics].any?
    refute A::UserLifecycle.export(u.id).key?(:partner)
    assert_raises(Discourse::InvalidAccess) { state(@outsider) }
    assert_raises(Discourse::InvalidAccess) { state(@alice,view:'admin') }
    A::Shared.deliver
    assert_equal 3,A::Event.where.not(notification_id:nil).count
    before=Notification.where(id:A::Event.pluck(:notification_id)).count;A::Shared.deliver
    assert_equal before,Notification.where(id:A::Event.pluck(:notification_id)).count
  end
  def test_manual_override_requires_readiness_and_preserves_note
    q=ready(@alice,@bob)
    a=A::Profile.find_by!(user_id:@alice.id);b=A::Profile.find_by!(user_id:@bob.id)
    a.update!(target_gender:'男生');b.update!(target_gender:'男生')
    refute A::Matching.compatible?(a,b)
    pub=A::Matching.publish('manual-fixture',user:@admin,manual:[a,b],note:'双方已同意的指定配对')
    assert_equal 1,pub.pair_count
    refute_includes state(@alice,view:'results').to_json,'双方已同意的指定配对'
    refute_includes A::UserLifecycle.export(@alice.id).to_json,'双方已同意的指定配对'
    assert A::Match.all.all? { |m| m.details['note']=='双方已同意的指定配对' && m.details['modules'].size==1 }
    call(@admin,'clear_match',{user_id:@alice.id,reason:'撤回测试'})
    assert_empty A::Match.all
    assert a.reload.active;assert b.reload.active;assert_nil a.last_published_at
    A::Submission.where(user_id:@bob.id).delete_all
    assert_raises(A::Error) { A::Matching.publish('manual-incomplete',user:@admin,manual:[a,b]) }
  end
  def test_unmatched_and_previous_history_are_preserved
    ready(@alice,@bob)
    A::Matching.publish('first',user:@admin)
    [@alice,@bob].each { |u| call(u,'join') }
    A::Matching.publish('second',user:@admin)
    assert_equal 4,A::Match.count
    assert_equal 2,A::Match.where(current:true).count
    call(@admin,'clear_match',{user_id:@alice.id,reason:'撤回第二次'})
    assert_equal 2,A::Match.count;assert_equal 0,A::Match.where(current:true).count
    assert_equal 1,state(view:'results')[:cards].size
  end
  def test_readonly_blocks_all_side_effects_and_jobs
    ready(@alice,@bob)
    call(@admin,'publish',{reason:'等待读取测试'})
    SiteSetting.rsdate_read_only=true
    counts=[A::Profile.count,A::Run.count,A::Match.count,A::Event.count,A::Command.count]
    assert_raises(A::Error) { call(@alice,'pause') }
    assert_raises(A::Error) { A::Matching.publish('forbidden',user:@admin) }
    A::Service.tick;A::Shared.deliver
    assert_equal counts,[A::Profile.count,A::Run.count,A::Match.count,A::Event.count,A::Command.count]
    assert_empty state(view:'me')[:forms]
    assert_empty state[:cards].first[:actions]
    assert state[:readonly_note]
    SiteSetting.rsdate_admin_only=true
    assert_equal 2,A::Matching.eligible_pool.first.size
    assert_raises(Discourse::InvalidAccess) { state }
    assert state(@admin,view:'admin')[:readonly]
  end
  def test_schedule_before_exact_and_after_boundary
    assert_equal '2026-09-13 20:00',A::Service.scheduled_at(Time.iso8601('2026-09-20T11:59:59Z')).strftime('%Y-%m-%d %H:%M')
    assert_equal '2026-09-20 20:00',A::Service.scheduled_at(Time.iso8601('2026-09-20T12:00:00Z')).strftime('%Y-%m-%d %H:%M')
    assert_equal '2026-09-20 20:00',A::Service.scheduled_at(Time.iso8601('2026-09-23T12:00:00Z')).strftime('%Y-%m-%d %H:%M')
    assert_equal '2026-09-27 20:00',A::Service.next_publish_at(Time.iso8601('2026-09-20T12:00:00Z')).strftime('%Y-%m-%d %H:%M')
  end
  def test_async_preview_publish_and_revoked_admin
    ready(@alice,@bob)
    call(@admin,'preview');A::Service.tick
    assert_equal 'complete',A::Run.last.status;assert_equal 1,A::Run.last.result['pairs'].size
    assert_empty A::Match.all;assert_empty A::Event.all
    call(@admin,'publish',{reason:'正常发布'});A::Service.tick
    assert_equal 2,A::Match.count;assert_equal 'complete',A::Run.last.status
    call(@admin,'preview');@admin.update!(admin:false);A::Service.tick
    assert_equal 'failed',A::Run.last.status
  ensure
    @admin&.update!(admin:true)
  end
  def test_erasure_removes_archived_answers_and_partner_data
    ready(@alice,@bob);A::Matching.publish('erase',user:@admin)
    A::Legacy.create!(source:'QuestionnaireModuleSubmission',legacy_id:'submission',data:{externalUserId:@alice.id.to_s})
    A::Legacy.create!(source:'QuestionnaireModuleAnswer',legacy_id:'answer',data:{submissionId:'submission',optionId:'private'})
    A::Legacy.create!(source:'MatchResult',legacy_id:'match',data:{userExternalId:@bob.id.to_s,matchedUserExternalId:@alice.id.to_s})
    A::UserLifecycle.purge(@alice.id)
    assert_nil A::Profile.find_by(user_id:@alice.id);assert_empty A::Submission.where(user_id:@alice.id)
    assert_empty A::Match.all;assert_empty A::Legacy.all
    assert A::Profile.exists?(user_id:@bob.id)
  end
  def test_request_idempotency_and_identity_checks
    data={nickname:'幂等同学',gender:'女生',target_gender:'不限',grade:'大二',campus:'测试校区',schedule:'周末都有空',bio:'用于幂等测试的一份个人介绍。'}
    key=SecureRandom.uuid;call(@alice,'profile',data,key:key);call(@alice,'profile',data,key:key)
    assert_equal 1,A::Profile.count;assert_equal 1,A::Command.count
    assert_raises(A::Error) { call(@alice,'profile',data.merge(nickname:'其他名字'),key:key) }
    assert_raises(Discourse::InvalidAccess) { call(@outsider,'profile',data) }
    assert_raises(Discourse::InvalidAccess) { call(@alice,'clear_match',{user_id:@bob.id,reason:'越权'}) }
  end
  def test_delayed_scheduled_publish_uses_original_cycle_and_does_not_repeat
    ready(@alice,@bob)
    SiteSetting.rsdate_scheduled_enabled=true
    travel_to Time.iso8601('2026-09-23T12:00:00Z') do
      A::Service.tick;A::Service.tick
      assert_equal 1,A::Publication.count
      assert_equal '202609202000',A::Publication.first.cycle_key
      assert_equal Time.iso8601('2026-09-20T12:00:00Z'),A::Publication.first.created_at
      assert_equal 2,A::Match.count
      assert_equal 2,A::Event.count
      assert A::Match.all.all? { |m| m.published_at==Time.iso8601('2026-09-20T12:00:00Z') }
    end
  end
  def test_deleting_module_removes_its_archived_answers
    q=ready(@alice);submission=A::Submission.first
    A::Legacy.create!(source:'QuestionnaireModule',legacy_id:'module-old',target_kind:'Questionnaire',target_id:q.id,data:{})
    A::Legacy.create!(source:'QuestionnaireModuleQuestion',legacy_id:'q-old',data:{moduleId:'module-old'})
    A::Legacy.create!(source:'QuestionnaireModuleOption',legacy_id:'o-old',data:{questionId:'q-old'})
    A::Legacy.create!(source:'QuestionnaireModuleSubmission',legacy_id:'s-old',target_kind:'Submission',target_id:submission.id,data:{externalUserId:@alice.id.to_s,moduleId:'module-old'})
    A::Legacy.create!(source:'QuestionnaireModuleAnswer',legacy_id:'a-old',data:{submissionId:'s-old'})
    call(@admin,'delete_questionnaire',{id:q.id,reason:'删除模块验收'})
    assert_empty A::Questionnaire.all
    assert_empty A::Submission.all
    assert_empty A::Legacy.all
    refute A::Service.progress(@alice.id)[:ready]
  end

  def test_cutover_does_not_publish_backlogged_cycles
    ready(@alice,@bob)
    SiteSetting.rsdate_scheduled_enabled=true
    SiteSetting.rsdate_scheduled_start_at='2026-09-27T12:00:00Z'
    travel_to Time.iso8601('2026-09-21T12:00:00Z') do
      A::Service.tick
      assert_empty A::Publication.all
      assert_empty A::Event.all
      assert_equal 2,A::Profile.where(active:true).count
    end
    travel_to Time.iso8601('2026-09-27T12:00:00Z') do
      A::Service.tick;A::Service.tick
      assert_equal 1,A::Publication.count
      assert_equal '202609272000',A::Publication.first.cycle_key
      assert_equal 2,A::Event.count
    end
  end
  def test_legacy_links_preserve_modules_and_discard_external_redirects
    q=questionnaire
    A::Legacy.create!(source:'QuestionnaireModule',legacy_id:'legacy-module',target_kind:'Questionnaire',target_id:q.id,data:{})
    assert_equal({view:'module',id:q.id},A::Service.legacy_query('questionnaire/legacy-module'))
    assert_equal({view:'admin',part:'modules',edit:q.id},A::Service.legacy_query('admin',{'edit'=>'legacy-module'}))
    assert_equal({view:'questions'},A::Service.legacy_query('questionnaire/missing'))
    assert_equal({view:'me'},A::Service.legacy_query('/profile/'))
    assert_equal({view:'home'},A::Service.legacy_query('auth/callback',{'sso'=>'secret','sig'=>'signature','redirect'=>'https://external.example'}))
    assert_equal({view:'results'},A::Service.legacy_query('results'))
  end

end
