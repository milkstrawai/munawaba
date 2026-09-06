# frozen_string_literal: true

module Munawaba
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
