# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users

  root "dashboard#index"

  resources :portfolios do
    member do
      get :xirr
    end
    collection do
      get :funding_plan
      get :custom_funding_plan
      get :statistics
      get :monthly_flows
      get :zakaa_statistics
      get :sector_analysis
      get :sector_speciality_analysis
      get "sector_detail/:sector_id", action: :sector_detail, as: :sector_detail
      get "sector_detail/:sector_id/:speciality_id", action: :sector_speciality_detail, as: :sector_speciality_detail
    end
    resources :portfolio_targets, only: %i[create update destroy]
    resources :portfolio_management_style_targets, only: %i[create update destroy]
  end

  resources :sectors, only: [] do
    resource :sector_target, only: %i[create update destroy]
  end

  resources :assets do
    member do
      post :fetch_price
    end
    collection do
      get :compare
      get :summary
      get :performance
    end
  end
  resources :zaka_payments, except: :show
  resources :transactions, only: %i[index show new create edit update]
  resources :wallets, only: [:index]

  resources :prices, only: %i[index create] do
    collection do
      post :fetch
    end
  end

  namespace :settings do
    resource :free_cash_target, only: %i[edit update]
    resource :zaka_setting, only: %i[edit update]
    resources :categories, except: :show
    resources :currencies do
      member do
        post :set_base
      end
    end
    resources :exchange_rates, only: %i[index create] do
      collection do
        post :fetch
      end
    end
    resources :market_indices, except: :show
    get "lookups", to: "lookups#index", as: :lookups
    get "lookups/:table/distribution", to: "lookups#distribution", as: :lookup_distribution
    get "lookups/:table", to: "lookups#show", as: :lookup_table
    get "lookups/:table/new", to: "lookups#new", as: :new_lookup_row
    post "lookups/:table", to: "lookups#create", as: :lookup_rows
    get "lookups/:table/:id/edit", to: "lookups#edit", as: :edit_lookup_row
    patch "lookups/:table/:id", to: "lookups#update", as: :update_lookup_row
    delete "lookups/:table/:id", to: "lookups#destroy", as: :destroy_lookup_row
  end

  namespace :api, defaults: { format: :json } do
    get "portfolios/:id/performance", to: "portfolios#performance", as: :portfolio_performance
    get "portfolios/:id/allocation", to: "portfolios#allocation", as: :portfolio_allocation
    get "portfolios/:id/sector_breakdown", to: "portfolios#sector_breakdown", as: :portfolio_sector_breakdown
    get "assets/compare", to: "assets#compare", as: :assets_compare
    get "assets/:id/prices", to: "assets#prices", as: :asset_prices
    get "assets/:id/index_prices", to: "assets#index_prices", as: :asset_index_prices
  end

  get  "backup/export",  to: "backups#export",  as: :export_backup
  get  "backup/import",  to: "backups#import",  as: :import_backup
  post "backup/restore", to: "backups#restore", as: :restore_backup

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
