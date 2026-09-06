# frozen_string_literal: true

Munawaba::Engine.routes.draw do
  root "overviews#show"
  resource :overview, only: :show
  resource :calendar, only: :show
  resources :people, except: :destroy do
    member do
      get :deactivation
      patch :deactivate
      patch :reactivate
    end
  end
  resources :schedules, except: :destroy do
    member do
      post :preview_activation
      post :activate
      post :pause
      post :preview_resume
      post :resume
      post :cancel_scheduled
    end
    resource :rotation, only: %i[edit update] do
      post :preview
    end
    resource :slack_integration, only: %i[edit update] do
      post :test
      delete :remove
    end
  end
  resources :shifts, only: :show do
    resource :override, only: %i[new create edit update] do
      post :preview
      patch :revoke
      patch :restore
    end
  end
  get "activity", to: "audit_events#index", as: :activity
  resources :notification_deliveries, only: :index do
    member { post :retry }
  end
  patch "theme", to: "themes#update", as: :theme
  get "assets/:version/:id", to: "frontends#show", as: :frontend_asset, format: false,
                             constraints: { version: /[A-Za-z0-9._-]+/, id: /[A-Za-z0-9._-]+/ }
end
