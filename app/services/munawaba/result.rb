# frozen_string_literal: true

module Munawaba
  Result = Struct.new(:status, :record, :errors, :preview, keyword_init: true) do
    def success? = status < 400
  end
end
