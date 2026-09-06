# frozen_string_literal: true

module Munawaba
  Preview = Struct.new(:token, :projection, :conflicts, :details, keyword_init: true)
end
