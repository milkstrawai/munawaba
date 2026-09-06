# frozen_string_literal: true

module Munawaba
  # Packaged assets are public and do not run the host's access callbacks.
  class FrontendsController < ActionController::Base
    # Assets do not read sessions or mutate state. Allow Rails to serve the script
    # to a normal script element without requiring an XHR request.
    protect_from_forgery with: :exception
    skip_after_action :verify_same_origin_request, only: :show
    MANIFEST = [
      ["dashboard.css", "text/css; charset=utf-8"],
      ["dashboard.js", "text/javascript; charset=utf-8"],
      ["logo.png", "image/png"],
      ["inter.woff2", "font/woff2"],
      ["jetbrains-mono.woff2", "font/woff2"]
    ].freeze

    def show
      entry = MANIFEST.find { |filename, _type| filename == params[:id] } if params[:version] == Munawaba::VERSION
      return head :not_found unless entry

      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Cache-Control"] = Rails.env.development? ? "no-cache" : "public, max-age=31536000, immutable"
      path = Munawaba::Engine.root.join("app/assets/munawaba", entry[0])
      send_file path, type: entry[1], disposition: "inline"
    end
  end
end
