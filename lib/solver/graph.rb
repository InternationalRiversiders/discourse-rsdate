# frozen_string_literal: true
module DiscourseRsdateSolver
  module Graph
    class WeightedGraph
      Edge = Struct.new(:source,:target)
      attr_reader :edges,:weight,:max_v,:max_w
      def initialize(count, triples)
        @max_v=count
        @edges=[]
        @weight=Array.new(count) { Array.new(count) }
        @max_w=0
        triples.each do |a,b,w|
          raise ArgumentError unless a.between?(1,count) && b.between?(1,count) && a!=b && w.is_a?(Integer)
          @edges<<Edge.new(a,b)
          @weight[a-1][b-1]=@weight[b-1][a-1]=w
          @max_w=[@max_w,w].max
        end
      end
      def num_edges = edges.size
    end
  end
end
