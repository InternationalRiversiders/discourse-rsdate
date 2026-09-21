# frozen_string_literal: true
module DiscourseRsdateSolver
  class Matching
    def self.from_endpoints(endpoint,mate)
      new.tap { |m| mate.each_with_index { |p,v| m.edges<<[v,endpoint[p]] if p && v<endpoint[p] } }
    end
    attr_reader :edges
    def initialize = @edges=[]
  end
end
