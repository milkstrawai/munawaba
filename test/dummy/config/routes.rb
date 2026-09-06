Rails.application.routes.draw do
  mount Munawaba::Engine => "/on-call"
  root to: redirect("/on-call")
end
