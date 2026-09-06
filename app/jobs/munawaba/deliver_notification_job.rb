# frozen_string_literal: true

module Munawaba
  class DeliverNotificationJob < ApplicationJob
    def perform(delivery_id, claim_token)
      if ActiveRecord::Base.connection.transaction_open?
        raise Munawaba::Error, "Delivery jobs must run outside host database transactions"
      end

      Notifications::Deliver.call(delivery_id, claim_token)
    end
  end
end
