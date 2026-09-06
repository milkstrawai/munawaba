# frozen_string_literal: true

module Munawaba
  class DispatchDueNotificationsJob < ApplicationJob
    def perform = Notifications::Dispatcher.call
  end
end
