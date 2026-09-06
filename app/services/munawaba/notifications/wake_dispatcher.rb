# frozen_string_literal: true

module Munawaba
  module Notifications
    class WakeDispatcher
      def self.call
        ActiveRecord.after_all_transactions_commit do
          begin
            DispatchDueNotificationsJob.perform_later
          rescue StandardError
            Munawaba.signal("dispatcher_wake_failed")
          end
        end
      end
    end
  end
end
