# frozen_string_literal: true
# name: discourse-rsdate
# about: RSDate — Riverside native community application
# version: 0.2.0
# authors: Riverside
# required_version: 2026.9.0-latest

enabled_site_setting :rsdate_enabled
register_asset "stylesheets/rsdate.scss"
register_svg_icon "heart"
require_relative "lib/engine"
after_initialize do
  require_relative "lib/core"
  require_relative "lib/business"
  require_relative "lib/importer"
  require_relative "lib/user_lifecycle"
  add_to_serializer(:current_user, :rsdate_member) { SiteSetting.rsdate_enabled && DiscourseRsdate::Access.member?(object) }

  Discourse::Application.routes.append { mount DiscourseRsdate::Engine, at: "/rsdate" }
end
