# frozen_string_literal: true
require 'digest'
module DiscourseRsdate
  class Error < StandardError; end
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end
  %w[Command Event Audit Legacy].each do |name|
    klass = Class.new(Record)
    klass.table_name = "river_rsdate_#{name.underscore.pluralize}"
    const_set(name, klass)
  end
  module Access
    def self.admin?(user)
      user && user.active? && !user.suspended? && (user.admin? || user.in_any_groups?(SiteSetting.rsdate_admin_groups.split('|').map(&:to_i)))
    end
    def self.participant?(user)
      user && user.active? && !user.suspended? && (admin?(user) || user.in_any_groups?(SiteSetting.rsdate_allowed_groups.split('|').map(&:to_i)) || Service.school_rule(user).present?)
    end
    def self.member?(user)
      SiteSetting.rsdate_admin_only ? admin?(user) : participant?(user)
    end
    def self.check!(user, admin: false)
      raise Discourse::InvalidAccess unless SiteSetting.rsdate_enabled && (admin ? admin?(user) : member?(user))
    end
    def self.writable!
      raise Error, '当前为只读预览，暂不接受修改' if SiteSetting.rsdate_read_only
    end
  end
  module Shared
    def self.text(value, max = 4000, required: true)
      text = value.to_s.strip
      raise Error, '请填写必填内容' if required && text.empty?
      raise Error, "内容超过 #{max} 字限制" if text.length > max
      text
    end
    def self.id(value)
      number = Integer(value.to_s, 10) rescue nil
      raise Error, '无效的编号' unless number && number > 0
      number
    end
    def self.bool(value) = value == true || value.to_s == 'true' || value.to_s == '1'
    def self.lock(key)
      number = Digest::SHA256.digest("river_rsdate:#{key}").unpack1('q>')
      Record.connection.execute("SELECT pg_advisory_xact_lock(#{number})")
    end
    def self.canonical(value)
      case value
      when Hash then value.stringify_keys.sort.to_h.transform_values { |v| canonical(v) }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end
    def self.command(user, operation, data, key)
      Access.check!(user); Access.writable!
      raise Error, '请求编号缺失' unless key.to_s.match?(/\A[\w-]{8,100}\z/)
      fingerprint = Digest::SHA256.hexdigest([operation, canonical(data)].to_json)
      Record.transaction do
        lock("user:#{user.id}"); lock("command:#{user.id}:#{key}")
        existing = Command.find_by(user_id: user.id, key: key)
        if existing
          raise Error, '请求编号已用于其他操作' unless existing.fingerprint == fingerprint
          next existing.result
        end
        result = yield || {}
        Command.create!(user_id: user.id, key: key, fingerprint: fingerprint, result: result)
        result
      end
    end
    def self.audit(actor, action, item, reason, details = {})
      Audit.create!(user_id: actor.id, action: action, target_kind: item.class.name.demodulize, target_id: item.id, reason: text(reason, 500), details: details)
    end
    def self.notify(user_id, text, path = '/rsdate', key:)
      return unless user_id && User.exists?(user_id)
      Event.create_or_find_by!(key: key) { |e| e.user_id = user_id; e.text = text; e.path = path }
    end
    def self.deliver
      return unless SiteSetting.rsdate_enabled && !SiteSetting.rsdate_read_only
      Event.where(notification_id: nil).order(:id).limit(100).each do |event|
        event.with_lock do
          next if event.notification_id || !Access.member?(User.find_by(id: event.user_id))
          n = Notification.create!(user_id: event.user_id, notification_type: Notification.types[:custom], skip_send_email: true,
            data: {river_app: 'rsdate', river_text: event.text, river_path: event.path, river_icon: 'heart', message: 'rsdate', display_username: '', topic_title: event.text}.to_json)
          event.update!(notification_id: n.id)
        end
      end
    end
    def self.user_name(id) = User.find_by(id: id)&.username || '已注销用户'
  end
  class MainController < ::ApplicationController
    requires_plugin 'discourse-rsdate'
    skip_before_action :check_xhr, only: [:index, :export]
    before_action :enabled!
    rescue_from Error, ArgumentError do |error|
      render_json_dump({errors: [error.message]}, status: 422)
    end
    def index
      Access.check!(current_user)
      render 'default/empty'
    end
    def state
      Access.check!(current_user)
      response.headers['Cache-Control'] = 'private, no-store'
      render_json_dump(Service.state(current_user, params.to_unsafe_h))
    end
    def mutate
      Access.check!(current_user); Access.writable!
      RateLimiter.new(current_user, 'rsdate-write', 40, 1.minute).performed!
      data = params.fetch(:data, ActionController::Parameters.new).permit!.to_h
      result = Shared.command(current_user, params.require(:operation).to_s, data, params.require(:request_id)) do
        Service.call(current_user, params[:operation].to_s, data)
      end
      Shared.deliver
      render_json_dump(result)
    end
    def export
      Access.check!(current_user)
      response.headers['Cache-Control'] = 'private, no-store'
      send_data(JSON.pretty_generate(UserLifecycle.export(current_user.id)), type: 'application/json', disposition: 'attachment', filename: 'my-rsdate-data.json')
    end
    private
    def enabled!
      raise Discourse::NotFound unless SiteSetting.rsdate_enabled
    end
  end
  module Ui
    def self.field(name, label, value = nil, type: 'text', options: nil, required: false, **rest)
      {name: name, label: label, value: value, type: type, options: options&.map { |v| v.is_a?(Array) ? {value: v[0], label: v[1]} : {value: v, label: v} }, required: required, **rest}
    end
    def self.form(title, operation, fields, data = {}, button: '保存', **rest)
      {title: title, operation: operation, fields: fields, data: data, button: button, **rest}
    end
    def self.card(id, title, body = nil, **rest) = {id: id.to_s, title: title, body: body, **rest}
    def self.action(label, operation, data = {}, **rest) = {label: label, operation: operation, data: data, **rest}
    def self.link(label, query) = {label: label, query: query}
    def self.shell(user, query, tabs, **rest)
      {title: 'RSDate', intro: '从共同的兴趣开始，认真认识一个人。', view: query['view'].presence || tabs.first[0], member: Access.member?(user), admin: Access.admin?(user),
       tabs: tabs.map { |id, label| {id: id, label: label} }, cards: [], forms: [], stats: [], filters: [], readonly: SiteSetting.rsdate_read_only, **rest}
    end
  end
end
module ::Jobs
  class DiscourseRsdateTick < ::Jobs::Scheduled
    every 1.minute
    def execute(args)
      return unless SiteSetting.rsdate_enabled && !SiteSetting.rsdate_read_only
      DistributedMutex.synchronize('rsdate-tick') do
        DiscourseRsdate::Service.tick
        DiscourseRsdate::Shared.deliver
      end
    end
  end
end
